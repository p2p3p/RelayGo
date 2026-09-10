import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:relaygo/config/constants.dart';
import 'package:relaygo/config/environment.dart';
import 'package:relaygo/models/alert.dart';
import 'package:relaygo/models/api_key.dart';
import 'package:relaygo/models/model_info.dart';
import 'package:relaygo/models/rate_limit_event.dart';
import 'package:relaygo/models/request_log.dart';
import 'package:relaygo/models/user_settings.dart';
import 'package:relaygo/models/app_release.dart';
import 'package:relaygo/services/adaptive_rate_limit.dart';
import 'package:relaygo/services/cache_manager.dart';
import 'package:relaygo/services/key_manager.dart';
import 'package:relaygo/services/load_balancer.dart';
import 'package:relaygo/services/log_service.dart';
import 'package:relaygo/services/oauth_token_refresher.dart';
import 'package:relaygo/database/database_helper.dart';
import 'package:relaygo/database/model_repository.dart';
import 'package:relaygo/services/providers/base_provider.dart';
import 'package:relaygo/services/providers/provider_factory.dart';
import 'package:relaygo/services/quota_monitor.dart';
import 'package:relaygo/services/rate_limit_event_log.dart';
import 'package:relaygo/services/rate_limiter.dart';
import 'package:relaygo/services/report_service.dart';
import 'package:relaygo/services/rule_engine.dart';
import 'package:relaygo/services/token_estimator.dart';
import 'package:relaygo/services/update_service.dart';
import 'package:relaygo/services/upstream_error.dart';
import 'package:relaygo/utils/usage_parser.dart';
import 'package:relaygo/l10n/app_strings.dart';

/// 单条「提供商 + key」候选
class _Pair {
  final BaseProvider provider;
  final ApiKey key;
  _Pair(this.provider, this.key);
}

/// 本地 HTTP 代理服务器（Phase 3）
///
/// 整合：规则引擎路由、多提供商自动切换与失败重试、并发信号量、SSE 透传、
/// token 计费、批量日志、额度监控，以及 Phase 3 的响应缓存、
/// 多维度高级限流与管理接口（版本 / 在线更新检查 / 报表 / 缓存）。
class ProxyServer {
  final KeyManager keyManager;
  final LoadBalancer loadBalancer;
  final AdaptiveRateLimitManager adaptiveRateLimitManager = AdaptiveRateLimitManager();
  Timer? _timeDecayTimer;
  final LogService logService;
  final RateLimitEventLog? rateLimitEventLog;
  final RuleEngine ruleEngine;
  final QuotaMonitor quotaMonitor;
  /// 运行配置。可在运行时被 AppState 替换（设置变更后即时生效）。
  UserSettings settings;

  /// 响应缓存（需求 2.2.4）
  late final CacheManager cache;

  /// 高级限流（需求 2.2.6）
  late final RateLimiter rateLimiter;

  /// 统计报表（供 /relay/report 接口）
  late final ReportService reportService;

  /// 在线更新（供 /relay/update/check 接口）
  final UpdateService? updateService;

  /// OAuth Token 自动刷新服务（P3）
  ///
  /// 在转发前检查 OAuth 类型 key 的 token 是否过期，
  /// 过期则自动使用 refresh_token 刷新，避免请求因 token 失效而失败。
  OAuthTokenRefresher? oauthRefresher;

  /// 模型库（供 /v1/models 聚合接口，REQ-003）
  ///
  /// 惰性解析：未显式注入时，直到首次访问才回落到全局 Box，
  /// 避免构造期就强依赖数据库初始化顺序（便于单测与延迟启动）。
  final ModelRepository? _modelRepositoryOverride;
  ModelRepository? _modelRepositoryFallback;

  ModelRepository get modelRepository =>
      _modelRepositoryOverride ??
      (_modelRepositoryFallback ??= ModelRepository(DatabaseHelper.models));

  int port;
  String host;
  String loadBalanceStrategy;

  HttpServer? _server;
  bool _running = false;

  /// 告警出口（由 AppState 装配，负责持久化 + Webhook）
  void Function(Alert alert)? onAlert;

  // —— 并发控制 ——
  final int _maxConcurrent = Constants.maxConcurrentConnections;
  final int _maxQueued = Constants.maxQueuedConnections;
  int _active = 0;
  final List<Completer<void>> _queue = [];

  ProxyServer({
    required this.keyManager,
    required this.loadBalancer,
    required this.logService,
    required this.ruleEngine,
    required this.quotaMonitor,
    required this.settings,
    CacheManager? cache,
    RateLimiter? rateLimiter,
    ReportService? reportService,
    this.rateLimitEventLog,
    this.updateService,
    ModelRepository? modelRepository,
    this.port = Constants.defaultPort,
    this.host = Constants.defaultHost,
    this.loadBalanceStrategy = 'round_robin',
  }) : _modelRepositoryOverride = modelRepository {
    this.cache = cache ??
        CacheManager(
          enabled: settings.cacheEnabled,
          ttl: Duration(seconds: settings.cacheTtlSeconds),
          maxEntries: settings.cacheMaxEntries,
        );
    this.rateLimiter = rateLimiter ??
        RateLimiter(
          enabled: settings.rateLimitEnabled,
          burstMultiplier: settings.burstMultiplier,
          tokensPerMinutePerKey: settings.tokenRateLimitPerMinute,
          requestsPerMinutePerIp: settings.ipRateLimitPerMinute,
          globalRequestsPerMinute: settings.globalRpmLimit,
          adaptiveTpmEnabled: settings.adaptiveTpmEnabled,
          windowSeconds: settings.rateLimitWindowSeconds,
        );
    this.reportService =
        reportService ?? ReportService(logService, cacheManager: this.cache);
  }

  bool get isRunning => _running;

  int get activeKeyCount =>
      keyManager.getAll().where((k) => k.status == KeyStatus.active).length;

  int get queuedRequests => _queue.length;

  /// 实时日志流（供 UI 订阅）
  Stream<RequestLog> get logStream => logService.stream;

  List<RequestLog> get recentLogs => logService.recent;

  // ————————————————————————————————————————————
  // 启动 / 停止
  // ————————————————————————————————————————————

  Future<void> start() async {
    if (_running) return;
    _server = await HttpServer.bind(host, port);
    port = _server!.port; // 记录实际绑定的端口（port:0 时为系统分配的临时端口）
    _running = true;
    _server!.listen(_handleRequest, onError: (_) {});

    // 启动自适应限流时间衰减定时器（每小时恢复放宽）
    _timeDecayTimer?.cancel();
    _timeDecayTimer = Timer.periodic(const Duration(hours: 1), (_) {
      adaptiveRateLimitManager.applyTimeDecay();
    });
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _running = false;
    _queue.clear();
    _active = 0;
    _timeDecayTimer?.cancel();
    _timeDecayTimer = null;
  }

  /// 重启服务（监听地址 / 端口变更后调用，使新配置立即生效）
  Future<void> restart() async {
    await stop();
    await start();
  }

  // ————————————————————————————————————————————
  // 并发信号量
  // ————————————————————————————————————————————

  Future<void> _acquire() async {
    if (_active < _maxConcurrent) {
      _active++;
      return;
    }
    if (_queue.length >= _maxQueued) {
      throw const _ProxyOverload();
    }
    final c = Completer<void>();
    _queue.add(c);
    await c.future; // 被唤醒后直接占用一个槽位（所有权转移，不另增 _active）
  }

  void _release() {
    if (_queue.isNotEmpty) {
      _queue.removeAt(0).complete();
    } else {
      _active--;
    }
  }

  // ————————————————————————————————————————————
  // 请求处理
  // ————————————————————————————————————————————

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      await _acquire();
    } on _ProxyOverload {
      await _respondError(request, 429, '请求过于繁忙，请稍后再试');
      _recordLog(request, null, 'proxy', 429, 0, error: 'concurrency limit');
      return;
    }

    final stopwatch = Stopwatch()..start();
    try {
      await _serve(request, stopwatch);
    } finally {
      stopwatch.stop();
      _release();
    }
  }

  Future<void> _serve(HttpRequest request, Stopwatch stopwatch) async {
    final path = request.uri.path;

    // 健康检查
    if (Constants.healthPaths.contains(path)) {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'status': 'ok',
          'version': Constants.appVersion,
          'active_keys': activeKeyCount,
          'load_balance': loadBalanceStrategy,
          'queued': queuedRequests,
          'ts': DateTime.now().millisecondsSinceEpoch,
        }));
      await request.response.close();
      return;
    }

    // 管理接口（统计 / 版本 / 在线更新 / 报表 / 缓存），不转发到上游
    if (Constants.adminPaths.contains(path)) {
      await _serveAdmin(request, path);
      return;
    }

    // 聚合模型列表（REQ-003）：AI 应用从中转站获取可用模型，不转发上游
    if (path == Constants.modelsPath) {
      await _serveModels(request);
      return;
    }

    // 入口限流：IP / 全局（需求 2.2.6）
    final clientIp = request.connectionInfo?.remoteAddress.address ?? '';
    final inbound = rateLimiter.checkInbound(clientIp);
    if (!inbound.allowed) {
      request.response.headers
          .set(Constants.retryAfterHeader, '${inbound.retryAfterSeconds}');
      await _respondError(
          request, 429, inbound.message.isEmpty ? '请求过于频繁' : inbound.message);
      _recordLog(request, null, Environment.detectProvider(path), 429,
          stopwatch.elapsedMilliseconds,
          error: 'rate limited: ${inbound.dimension}',
          rateLimited: inbound.dimension);
      _emitRateLimitAlert(inbound, clientIp);
      return;
    }
    rateLimiter.recordInbound(clientIp);

    // 1) 读取请求体（一次性，受上限约束）
    List<int> body;
    try {
      body = await _readBody(request);
    } catch (e) {
      await _respondError(request, 413, '请求体过大或读取失败');
      _recordLog(request, null, Environment.detectProvider(path), 413,
          stopwatch.elapsedMilliseconds,
          error: e.toString());
      return;
    }

    final headers = <String, String>{};
    request.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.join(', ');
    });

    final payload = RequestPayload.parse(body);
    final proxyRequest = ProxyRequest(
      method: request.method,
      path: path,
      query: request.uri.query,
      headers: headers,
      body: body,
      model: payload.model,
      stream: payload.stream,
      clientIp: request.connectionInfo?.remoteAddress.address ?? '',
    );

    // 2) 规则引擎：构建上下文并求值
    final ctx = RuleEngine.buildContext(proxyRequest);
    final detected = Environment.detectProvider(path,
        model: payload.model,
        headerProvider: headers[Constants.providerHeader]);
    ctx['request']['provider'] = detected;
    RoutingDecision? decision;
    if (settings.rulesEnabled) {
      decision = ruleEngine.evaluate(ctx);
    }

    // 命中拦截规则
    if (decision?.block == true) {
      await _respondError(
        request,
        403,
        decision?.blockReason ?? '请求被路由规则拦截',
      );
      _recordLog(request, null, detected, 403, stopwatch.elapsedMilliseconds,
          model: payload.model, ruleName: decision?.ruleName, error: 'blocked');
      return;
    }

    // 3) 模型禁用前置检查（在缓存查询之前，确保已禁用模型即使命中缓存也不返回）
    final reqModel = payload.model.trim();
    if (reqModel.isNotEmpty) {
      final allModels = modelRepository.getAll();
      final modelExists = allModels
          .any((m) => m.name.trim().toLowerCase() == reqModel.toLowerCase());
      if (modelExists) {
        final modelEnabled = modelRepository
            .getEnabled()
            .any((m) => m.name.trim().toLowerCase() == reqModel.toLowerCase());
        if (!modelEnabled) {
          await _respondError(
              request, 403, '模型「$reqModel」已被禁用或已下线，请在模型管理中启用后重试');
          _recordLog(request, null, detected, 403,
              stopwatch.elapsedMilliseconds,
              model: payload.model, error: 'model disabled');
          return;
        }
      }
    }

    // 4) 响应缓存查询（需求 2.2.4）——流式请求不参与缓存
    final cacheKey = CacheManager.buildKey(
      method: request.method,
      path: path,
      query: request.uri.query,
      provider: decision?.provider ?? detected,
      body: body,
    );
    if (cache.enabled && !payload.stream) {
      final hit = cache.get(cacheKey);
      if (hit != null) {
        await _respondFromCache(request, hit);
        _recordLog(
          request,
          null,
          hit.provider.isEmpty ? detected : hit.provider,
          hit.statusCode,
          stopwatch.elapsedMilliseconds,
          model: payload.model,
          requestBytes: body.length,
          responseBytes: hit.body.length,
          ruleName: decision?.ruleName,
          cached: true,
        );
        return;
      }
    }

    // 5) 候选 key 选择 + 多提供商失败重试
    final forwardResult =
        await _forwardWithFallback(proxyRequest, detected, decision);
    if (forwardResult is _ForwardFailure) {
      // 用户可见信息始终使用友好、可读的 reason；原始上游错误体只进日志，
      // 避免把 "inference tpm exhausted" / "FREE_QUOTA_EXHAUSTED" 等原始报文
      // 直接抛给用户，造成不必要的打扰。
      final msg = forwardResult.reason;
      // 可恢复 TPM 限流且已等待预算耗尽：返回 429 + Retry-After，
      // 让 AI 客户端排队后自动重发，而不是硬断成 503（避免“发送继续后仍可用”的中断）。
      if (forwardResult.retryAfterSeconds > 0) {
        // 提示客户端等待后重试（OpenAI/Anthropic 认可的标准做法）
        request.response.headers.set(
            Constants.retryAfterHeader, '${forwardResult.retryAfterSeconds}');
        await _respondError(request, 429, msg);
        _recordLog(request, null, detected, 429, stopwatch.elapsedMilliseconds,
            model: payload.model,
            actualModel: forwardResult.actualModel,
            ruleName: decision?.ruleName,
            error: forwardResult.lastError ?? 'upstream tpm rate limited',
            rateLimited: 'upstream_tpm');
        return;
      }
      await _respondError(request, 503, msg);
      _recordLog(request, null, detected, 503, stopwatch.elapsedMilliseconds,
          model: payload.model,
          actualModel: forwardResult.actualModel,
          ruleName: decision?.ruleName,
          error: forwardResult.lastError ?? forwardResult.reason);
      return;
    }
    final outcome = forwardResult as _ForwardOutcome;

    // 6) 透传响应（SSE 流式 / 普通 JSON）
    final key = outcome.key;
    final result = outcome.result;
    final isError = result.statusCode < 200 || result.statusCode >= 400;
    try {
      request.response.statusCode = result.statusCode;
      result.headers.forEach((name, value) {
        final lower = name.toLowerCase();
        if (BaseHttpProvider.skipResponseHeader(lower)) return;
        request.response.headers.set(name, value);
      });

      if (cache.enabled) {
        request.response.headers.set(Constants.cacheHitHeader, 'MISS');
      }

      final cap = result.streaming
          ? Constants.usageCaptureBytes
          : Constants.maxRequestBodyBytes;
      final written = await _pipeAndCapture(result.body, request.response, cap);

      final usage = UsageParser.parseBytes(written.captured);
      final prevStatus = key.status;
      if (!isError) {
        loadBalancer.recordSuccess(key,
            latencyMs: stopwatch.elapsedMilliseconds);
        // 自适应限流：记录成功
        final estimatedTokens = TokenEstimator.extractActualTokens(
            written.captured.isEmpty ? '' : String.fromCharCodes(written.captured));
        adaptiveRateLimitManager.onSuccess(key.id, estimatedTokens > 0 ? estimatedTokens : usage.total);
        // QPS/RPM 自适应：本次成功 → 累计稳定时长，够阈值则缓慢上调学习上限
        rateLimiter.noteQpsHealthy(key);
      } else {
        loadBalancer.recordFailure(key);
      }

      // 6) 写入缓存（仅完整捕获的非流式 2xx 响应）
      if (cache.isCacheable(
        method: request.method,
        statusCode: result.statusCode,
        streaming: result.streaming,
        bodyBytes: written.total,
      )) {
        if (written.captured.length == written.total) {
          cache.put(
            cacheKey,
            statusCode: result.statusCode,
            headers: result.headers,
            body: written.captured,
            provider: key.providerId.isNotEmpty ? key.providerId : key.provider,
            model: payload.model,
          );
        }
      }

      // 7) 额度记账（仅成功计入 token；失败仅计请求数）
      final alerts = quotaMonitor.recordUsage(
        key,
        tokens: isError ? 0 : usage.total,
        error: isError,
      );
      if (!isError) {
        rateLimiter.recordTokens(key, usage.total, model: payload.model);
      }
      await keyManager.updateKey(key);
      _maybeEmitKeyStatusChanged(key, prevStatus);
      for (final a in alerts) {
        onAlert?.call(a);
      }

      _recordLog(
        request,
        key,
        key.providerId.isNotEmpty ? key.providerId : key.provider,
        result.statusCode,
        stopwatch.elapsedMilliseconds,
        model: payload.model,
        actualModel: payload.model,
        promptTokens: usage.promptTokens,
        completionTokens: usage.completionTokens,
        requestBytes: body.length,
        responseBytes: written.total,
        streaming: result.streaming,
        retries: outcome.attempts,
        ruleName: decision?.ruleName,
        error: isError ? 'upstream ${result.statusCode}' : null,
      );
      await request.response.close();
    } catch (e) {
      // 异常时兜底：关闭下游响应、排空上游流，避免连接泄漏
      try {
        await result.body.drain<void>();
      } catch (_) {}
      try {
        await request.response.close();
      } catch (_) {}
      _recordLog(
        request,
        key,
        key.provider,
        isError ? result.statusCode : 0,
        stopwatch.elapsedMilliseconds,
        model: payload.model,
        actualModel: payload.model,
        retries: outcome.attempts,
        ruleName: decision?.ruleName,
        error: e.toString(),
      );
    }
  }

  /// 候选 key 选择 + 多提供商失败重试
  ///
  /// 成功返回 [_ForwardOutcome]；失败返回 [_ForwardFailure]（含具体原因，
  /// 便于 503 响应与日志向用户说明「为什么没有可用 key」）。
  Future<Object> _forwardWithFallback(
    ProxyRequest proxyRequest,
    String detected,
    RoutingDecision? decision,
  ) async {
    // 前置检查：请求的模型是否已禁用
    // （全局检查已在 _serve 缓存查询之前完成，这里只做 per-provider 禁用过滤）
    final reqModel = proxyRequest.model.trim();

    final primaryName = decision?.provider ?? detected;
    var candidates =
        Environment.candidateProviders(primaryName, proxyRequest.path);
    final strategy = decision?.strategy ?? loadBalanceStrategy;

    // 模型归属优先：真实模型名时，优先路由到拥有该模型的提供商
    // （解决多提供商下轮询命中无此模型的 key 导致 upstream 404 model not found）
    final modelOwner = _findModelOwner(proxyRequest.model);
    if (modelOwner != null && modelOwner != candidates.first) {
      candidates = [modelOwner, ...candidates.where((c) => c != modelOwner)];
    }

    // 构建候选池：每个候选提供商纳入其全部可用 key（一个 _Pair 对应一个 key），
    // 从而支持「同一提供商多个 key 之间的失败重试切换」（需求 2.2 多提供商/多 key 自动切换）。
    final pool = <_Pair>[];
    var hadActiveKeys = false;
    var rateLimited = false;
    var groupFiltered = false;
    var modelDisabledFiltered = false; // 因模型在该 provider 下被禁用而跳过
    for (final pname in candidates) {
      final provider = providerForName(pname);
      provider.globalHeaders = settings.globalHeaders;

      // —— Per-provider 模型禁用检查 ——
      // 全局禁用检查（上方 modelEnabled）只判断「有没有任何 provider 启用该模型」，
      // 无法阻止轮询落到「该模型已被禁用的 provider」上。这里对每个候选 provider
      // 逐一检查：如果模型在该 provider 下存在且被禁用，跳过该 provider 的所有 key，
      // 从根源上杜绝「已禁用模型被第三方请求后仍被转发」。
      if (reqModel.isNotEmpty) {
        final mi = _findModelByProviderAndName(pname, reqModel);
        if (mi != null && !mi.isEnabled) {
          modelDisabledFiltered = true;
          continue; // 该 provider 下此模型已禁用，不纳入候选池
        }
      }

      // 使用「可用」查询：error 且冷却已过期的 key 会自动恢复为 active，
      // 避免 key 因连续失败被标记 error 后永远无法回到候选池（死锁）。
      var keys = keyManager.getUsableByProvider(pname);
      if (keys.isNotEmpty) hadActiveKeys = true;
      if (decision?.group != null && decision!.group!.isNotEmpty) {
        final before = keys.length;
        keys = keys.where((k) => k.group == decision.group).toList();
        if (before > 0 && keys.isEmpty) groupFiltered = true;
      }
      if (settings.rateLimitEnabled) {
        final before = keys.length;
        // 传模型名，让「自适应 TPM 挡板」按 key+model 学到的上限在候选池阶段生效
        keys = keys
            .where((k) => rateLimiter.allows(k, model: proxyRequest.model))
            .toList();
        // 只在该 provider 确实有 key 但全部被限流时才标记 rateLimited，
        // 避免把「没有 key」的 provider 误标为限流（如 openai 无 key 时不应该报限流）
        if (before > 0 && keys.isEmpty) rateLimited = true;
      }

      // 智能选择：根据自适应限流剩余配额对 key 排序
      if (keys.length > 1) {
        final estimatedTokens = _estimateRequestTokens(proxyRequest);
        keys.sort((a, b) => _compareKeyQuota(a, b, estimatedTokens));
      }
      final ranked = loadBalancer.rank(keys, strategy);
      for (final k in ranked) {
        pool.add(_Pair(provider, k));
      }
    }

    if (pool.isEmpty) {
      String reason;
      if (modelDisabledFiltered && !hadActiveKeys) {
        reason = '模型「$reqModel」在所有候选提供商下均已被禁用';
      } else if (!hadActiveKeys) {
        // 诊断性提示：说明 key 当前具体处于什么状态、最早何时自动恢复，
        // 避免笼统的「没有 active 状态」让用户无从下手。
        reason = _describeNoUsableKeys(candidates);
      } else if (groupFiltered) {
        reason = '候选 key 均不属于路由规则指定的分组「${decision?.group}」';
      } else if (rateLimited) {
        // 精确诊断：哪些 key 被限流、是 RPM 还是 TPM
        reason = _describeRateLimitedKeys(candidates, proxyRequest.model);
      } else {
        reason = '候选池为空';
      }
      return _ForwardFailure(reason, null);
    }

    // 顺序尝试候选 key，遇到 429/5xx/异常则切换下一个（可循环复用，
    // 直到遍历完候选池中所有 key 或某次成功/遇到不可重试的 4xx）。
    // 自动切换次数 = 候选池大小 × 2（额外一倍余量用于 TPM 同 key 等待重试）。
    //
    // 针对「可恢复 TPM 限流」（429 且命中 tpm/tokens_per_minute 关键词）：
    // 不再立刻换 key 或放弃，而是【在同一 key 上等待 TPM 窗口刷新后重试】，
    // 使“发送继续后仍可使用”的请求在第三方客户端侧不中断。等待受总预算
    // [UserSettings.tpmWaitBudgetSeconds] 约束，超过预算则返回 429 + Retry-After。
    int attempts = 0;
    int idx = 0;
    String? lastUpstreamError;
    String? lastActualModel; // 最后一次尝试实际发送的模型名
    // 单次请求允许等待 TPM 窗口刷新的总预算截止时间
    final tpmDeadline =
        DateTime.now().millisecondsSinceEpoch + settings.tpmWaitBudgetSeconds * 1000;
    int? tpmRetryAfter; // 最终建议客户端等待的秒数（遭遇可恢复 TPM 限流时）
    bool sawRecoverable429 = false;
    ApiKey? lastTpmKey; // 最近一次触发可恢复 TPM 429 的 key
    // 针对「可恢复 QPS/RPM 限流」（429 + requests/rpm/qps 关键词）的等待预算与状态
    final qpsDeadline =
        DateTime.now().millisecondsSinceEpoch + settings.qpsWaitBudgetSeconds * 1000;
    int? qpsRetryAfter;
    bool sawRecoverableQps = false;
    ApiKey? lastQpsKey; // 最近一次触发可恢复 QPS/RPM 429 的 key
    int quotaExhaustedCount = 0; // 本轮请求命中「额度耗尽」的 key 数
    // 自动切换次数根据候选池大小动态决定：每个 key 至少尝试一次，
    // 不再使用固定的 maxRetryKeys 上限。额外预留一倍余量用于 TPM 同 key 重试。
    // 例如：候选池 3 个 key → maxAttempts = 6，候选池 10 个 key → maxAttempts = 20。
    final int maxAttempts = pool.length * 2;
    while (attempts < maxAttempts) {
      if (pool.isEmpty) break;
      final pair = pool[idx % pool.length];
      idx++;
      final key = pair.key;
      attempts++; // 本次视为一次上游尝试

      // 转发前滚动重置（防止跨日计数失真）
      final rollAlerts = quotaMonitor.rollIfNeeded(key);
      for (final a in rollAlerts) {
        onAlert?.call(a);
      }
      // 已耗尽 / 停用 / 冷却中的 key 跳过本次尝试（仍计入 attempts，避免死循环）
      if (key.status != KeyStatus.active) continue;

      loadBalancer.incConnection(key.id);
      rateLimiter.consumeKey(key);
      lastActualModel = proxyRequest.model;
      ProviderResult? result;
      try {
        // ── OAuth token 自动刷新（P3）──
        // 在转发前检查 OAuth 类型 key 的 token 是否即将过期，
        // 若是则使用 refresh_token 自动刷新，避免请求因 token 失效而 401。
        if (key.isOAuth && oauthRefresher != null) {
          final refreshed = await oauthRefresher!.ensureFreshToken(key);
          if (!refreshed) {
            // Token 刷新失败：跳过此 key，切换到下一个候选
            lastUpstreamError = 'OAuth token refresh failed for key ${key.name}';
            continue;
          }
        }
        // 纯转发：仅做 tools 名称清洗（网关中间件），修复客户端/MCP 注入的
        // 非法 function.name，避免上游 400 Invalid 'tools[0].function.name'。
        final out = _sanitizeToolsInBody(proxyRequest);
        final r = await pair.provider.forward(
          out,
          key,
          timeout: Duration(seconds: settings.upstreamTimeoutSeconds),
        );
        result = r;
        if (r.statusCode >= 200 && r.statusCode < 300) {
          return _ForwardOutcome(key, r, attempts);
        }
        // 用错误识别器判断本响应是否需要「无感切换 key」重试。
        // 捕获上游错误响应体（前 500 字节），供分类器与诊断使用，例如 OpenAI
        // "The model 'gpt-4o' does not exist..."、free quota exhausted 等。
        if (r.statusCode >= 400 ||
            (r.statusCode >= 300 && r.statusCode != 304)) {
          final errBody = await _captureUpstreamError(r.body);
          final kind =
              UpstreamErrorClassifier.classify(r.statusCode, errBody ?? '');
          lastUpstreamError = (errBody != null && errBody.isNotEmpty)
              ? '上游 HTTP ${r.statusCode}: $errBody'
              : '上游 HTTP ${r.statusCode}';

          // —— 可恢复 TPM 限流：等待窗口刷新后重试同一个 key ——
          // 仅对「429 + TPM 关键词」生效；额度耗尽等其他 429 不在此列，
          // 应交由下方「无感切换 key」处理。
          if (kind == UpstreamErrorKind.rateLimited &&
              UpstreamErrorClassifier.isRecoverableTpm(
                  r.statusCode, errBody ?? '') &&
              settings.tpmWaitBudgetSeconds > 0) {
            // 自适应限流：记录本次 429
            adaptiveRateLimitManager.onRateLimited(key.id, r.headers);
            // 限流切换事件：先记录旧值，再喂挡板下调
            final oldTpmBefore =
                rateLimiter.learnedTpm(key, model: proxyRequest.model) ?? 0;
            final oldTpmLimitEffective =
                rateLimiter.effectiveTpmLimit(key, model: proxyRequest.model) ?? 0;
            // 喂给自适应挡板：把本次 429 当“撞线点”下调学到的 TPM 上限
            rateLimiter.recordUpstreamTpmLimit(
                key, proxyRequest.model, rateLimiter.tpmUsed(key));
            sawRecoverable429 = true;
            lastTpmKey = key;
            _recordRateLimitEvent(
              key: key,
              reason: 'tpm',
              model: proxyRequest.model,
              oldTpmLimit: oldTpmBefore > 0
                  ? oldTpmBefore
                  : oldTpmLimitEffective,
              newTpmLimit:
                  rateLimiter.learnedTpm(key, model: proxyRequest.model) ??
                      oldTpmBefore,
              detail: '上游 TPM 429：窗口用量 ${rateLimiter.tpmUsed(key)}，学习上限 ${oldTpmBefore > 0 ? oldTpmBefore : '无'} → ${rateLimiter.learnedTpm(key, model: proxyRequest.model)}',
            );
            // 优先采用上游给出的 Retry-After，否则用本地 TPM 窗口剩余时间
            var waitMs = (_retryAfterSecondsFromHeaders(r) * 1000);
            if (waitMs <= 0) waitMs = rateLimiter.tpmWaitMillis(key);
            if (waitMs <= 0) waitMs = 1000; // 最小退避 1s
            // 受总预算约束
            final now = DateTime.now().millisecondsSinceEpoch;
            final budgetLeft = tpmDeadline - now;
            if (waitMs > budgetLeft) {
              waitMs = budgetLeft > 0 ? budgetLeft : 0;
            }
            if (waitMs > 0) {
              // 预算内：等待后重试同一候选（回退 idx，不切换 key、也不冷却该 key）
              idx--;
              // TPM 重试不是「切换 key」，不消耗 key 切换次数配额
              attempts--;
              await Future<void>.delayed(Duration(milliseconds: waitMs));
              // 绕过 recordFailure：TPM 临时限流不是 key 故障，不该触发冷却
              continue;
            }
            // 预算耗尽：记录重试建议，跳出循环改走 429 + Retry-After
            tpmRetryAfter = (budgetLeft ~/ 1000).clamp(1, 120);
            break;
          }

          // —— 可恢复 QPS/RPM（请求数）限流：学习下调该 key 的每分钟请求上限，
          // 并在同一 key 上等待令牌恢复后重试（与 TPM 分支对称）。
          // 仅对「429 + requests/rpm/qps 关键词」且非 TPM 时生效。
          if (kind == UpstreamErrorKind.rateLimited &&
              !UpstreamErrorClassifier.isRecoverableTpm(
                  r.statusCode, errBody ?? '') &&
              UpstreamErrorClassifier.isRecoverableQps(
                  r.statusCode, errBody ?? '') &&
              settings.qpsWaitBudgetSeconds > 0) {
            adaptiveRateLimitManager.onRateLimited(key.id, r.headers);
            final oldQpsBefore = rateLimiter.learnedQpm(key) ??
                (key.maxRequestsPerMinute > 0
                    ? key.maxRequestsPerMinute
                    : rateLimiter.effectiveRpm(key));
            rateLimiter.recordUpstreamQpsLimit(key);
            sawRecoverableQps = true;
            lastQpsKey = key;
            _recordRateLimitEvent(
              key: key,
              reason: 'qps',
              model: proxyRequest.model,
              oldRpmLimit: oldQpsBefore,
              newRpmLimit: rateLimiter.learnedQpm(key) ?? oldQpsBefore,
              detail: '上游 QPS/RPM 429：学习上限 $oldQpsBefore → ${rateLimiter.learnedQpm(key)}（每分钟请求数）',
            );
            // 优先采用上游 Retry-After，否则用本地令牌桶恢复时间
            var waitMs = _retryAfterSecondsFromHeaders(r) * 1000;
            if (waitMs <= 0) waitMs = rateLimiter.qpsWaitMillis(key);
            if (waitMs <= 0) waitMs = 1000; // 最小退避 1s
            final nowQps = DateTime.now().millisecondsSinceEpoch;
            final budgetLeftQps = qpsDeadline - nowQps;
            if (waitMs > budgetLeftQps) {
              waitMs = budgetLeftQps > 0 ? budgetLeftQps : 0;
            }
            if (waitMs > 0) {
              idx--;
              attempts--; // QPS 重试不是「切换 key」，不消耗切换次数配额
              await Future<void>.delayed(Duration(milliseconds: waitMs));
              continue; // 绕过 recordFailure：临时限流不是 key 故障
            }
            // 预算耗尽：记录重试建议，跳出循环改走 429 + Retry-After
            qpsRetryAfter = (budgetLeftQps ~/ 1000).clamp(1, 120);
            break;
          }

          // —— 无感切换 key：仅当错误源于「key / 上游 / 额度」（换一个 key 就可能
          // 成功）时才静默重试；请求本身的内容问题（badRequest/unknown）直接透传。
          if (!UpstreamErrorClassifier.isSilentlyRetryable(kind)) {
            // 请求内容/无法归类的 4xx：切 key 无济于事，透传给客户端
            return _ForwardOutcome(key, r, attempts);
          }

          // —— 普通 429 限流（非可恢复 TPM，已在上方处理）：
          // 记录一次「限流切换 key」事件，然后继续下方原有逻辑（计入失败
          // 并静默切换到下一个候选 key）。
          if (kind == UpstreamErrorKind.rateLimited) {
            _recordRateLimitEvent(
              key: key,
              reason: '429',
              model: proxyRequest.model,
              newRpmLimit: key.maxRequestsPerMinute,
              newTpmLimit:
                  rateLimiter.effectiveTpmLimit(key, model: proxyRequest.model) ?? 0,
              detail: '上游返回 429（限流），切换至下一个候选 Key',
            );
          }

          // —— 额度耗尽：把当前 key 标记为 exhausted + 冷却 ——
          // 这样本次请求后续轮询与之后的独立请求都会快速跳过它（不会再次命中
          // 一个已耗尽的 key），冷却到期后由 KeyManager 自动恢复为 active。
          if (kind == UpstreamErrorKind.quotaExhausted) {
            quotaExhaustedCount++;
            final prev = key.status;
            if (key.status != KeyStatus.exhausted) {
              key.status = KeyStatus.exhausted;
              key.cooldownUntil = DateTime.now().millisecondsSinceEpoch +
                  settings.quotaCooldownMinutes * 60 * 1000;
              // 额度耗尽是一种「key 问题」，计入失败以便 UI 展示错误倾向；
              // 但直接进入冷却，不必等满 maxFailureThreshold。
              key.failureCount++;
              loadBalancer.recordFailure(key); // 喂健康分窗口（失败）
              await keyManager.updateKey(key);
              _maybeEmitKeyStatusChanged(key, prev);
              _recordRateLimitEvent(
                key: key,
                reason: 'quota',
                model: proxyRequest.model,
                newRpmLimit: key.maxRequestsPerMinute,
                newTpmLimit:
                    rateLimiter.effectiveTpmLimit(key, model: proxyRequest.model) ?? 0,
                detail: '上游返回额度耗尽（429/403），Key 已标记 exhausted 并冷却 ${settings.quotaCooldownMinutes} 分钟',
              );
            }
            continue;
          }

          // 模型不存在（modelNotFound）：key 本身正常，只是不含该模型，
          // 不标记失败（避免误冷却），继续切下一个 key。
          if (kind != UpstreamErrorKind.modelNotFound) {
            final prev = key.status;
            loadBalancer.recordFailure(key);
            await keyManager.updateKey(key);
            _maybeEmitKeyStatusChanged(key, prev);
          }
          continue;
        }
        // 3xx（非 304）等其余情况：交给下面的统一处理（正常透传）
        return _ForwardOutcome(key, r, attempts);
      } catch (e) {
        lastUpstreamError = e.toString();
        // 异常时若已拿到结果流，先排空以释放连接，避免连接池泄漏
        try {
          await result?.body.drain<void>();
        } catch (_) {}
        final prev = key.status;
        loadBalancer.recordFailure(key);
        await keyManager.updateKey(key);
        _maybeEmitKeyStatusChanged(key, prev);
        continue;
      } finally {
        loadBalancer.decConnection(key.id);
      }
    }
    // 遭遇可恢复 TPM 限流：返回 429 + Retry-After 而非 503。
    // 无论是因为等待预算耗尽，还是候选池遍历完毕但预算尚余，
    // 只要遇过可恢复 TPM 429，就应让客户端等待后重发，而不是硬断 503。
    if (tpmRetryAfter != null || sawRecoverable429) {
      final secs = tpmRetryAfter ??
          (lastTpmKey == null
              ? 5
              : (rateLimiter.tpmWaitMillis(lastTpmKey) ~/ 1000).clamp(1, 120));
      return _ForwardFailure(
        '上游 TPM 限流，等待 $secs 秒后重试',
        lastUpstreamError,
        lastActualModel,
        secs,
      );
    }
    // 遭遇可恢复 QPS/RPM 限流：同样返回 429 + Retry-After 让客户端排队重发。
    if (qpsRetryAfter != null || sawRecoverableQps) {
      final secs = qpsRetryAfter ??
          (lastQpsKey == null
              ? 5
              : (rateLimiter.qpsWaitMillis(lastQpsKey) ~/ 1000).clamp(1, 120));
      return _ForwardFailure(
        '上游请求速率（QPS/RPM）限流，等待 $secs 秒后重试',
        lastUpstreamError,
        lastActualModel,
        secs,
      );
    }
    // 试遍所有候选仍失败：把「额度耗尽」这类可归因的原因汇总为简洁友好的提示，
    // 而不是把原始上游错误体直接抛给用户。原始细节保留在 [lastUpstreamError]（仅日志）。
    if (quotaExhaustedCount > 0) {
      // 该模型/提供商下所有候选 key 的免费/可用额度均已耗尽
      return _ForwardFailure(
        '所有候选 key 的免费/可用额度均已用完，请补充或更换 key 后再试',
        lastUpstreamError,
        lastActualModel,
      );
    }
    return _ForwardFailure(
      '上游暂时不可用（已尝试 $attempts 次自动切换，候选 key ${pool.length} 个），${lastUpstreamError ?? "请稍后再试"}',
      lastUpstreamError,
      lastActualModel,
    );
  }

  /// 从上游响应头读取 `retry-after`（秒），无则返回 0。
  int _retryAfterSecondsFromHeaders(ProviderResult r) {
    for (final e in r.headers.entries) {
      if (e.key.toLowerCase() == 'retry-after') {
        final v = int.tryParse(e.value.trim());
        if (v != null && v > 0) return v;
        // retry-after 也常用 HTTP 日期格式，此处仅认秒数
      }
    }
    return 0;
  }

  // ————————————————————————————————————————————
  // 工具方法
  // ————————————————————————————————————————————

  /// 在本地模型库中查找拥有该模型的提供商（未同步 / 未知模型返回 null）
  ///
  /// 用于请求路由时把「模型归属提供商」排在候选首位，从根源避免
  /// 轮询命中无此模型的 key 导致 upstream 404 model not found。
  String? _findModelOwner(String model) {
    if (model.isEmpty) return null;
    for (final m in modelRepository.getEnabled()) {
      if (m.name == model) return m.provider;
    }
    return null;
  }

  /// 按「提供商 + 模型名」精确查找本地模型（含已禁用/已下线，专供虚拟回退判断）。
  ///
  /// 与 [_findModelOwner] 不同：前者只看已启用模型；这里用于判断某模型
  /// 是否已被用户停用（作为虚拟模型回退候选时需跳过），因此不区分启用状态。
  ModelInfo? _findModelByProviderAndName(String provider, String name) {
    if (name.isEmpty) return null;
    for (final m in modelRepository.getAll()) {
      if (m.provider == provider && m.name == name) return m;
    }
    return null;
  }

  /// 当候选提供商下没有任何可用 key 时，生成诊断性原因。
  ///
  /// 逐个检查候选提供商下 key 的实际状态（冷却中 / 额度耗尽 / 已停用 / 未添加），
  /// 并给出最早自动恢复的大致时间，帮助用户快速定位问题。
  /// 预估请求的 token 消耗
  int _estimateRequestTokens(ProxyRequest req) {
    final body = utf8.decode(req.body, allowMalformed: true);
    if (req.model.contains('embedding')) {
      return TokenEstimator.estimateEmbeddingTokens(body);
    }
    return TokenEstimator.estimateChatTokens(body, model: req.model);
  }

  /// 比较两个 key 的剩余配额（智能选择用）
  int _compareKeyQuota(ApiKey a, ApiKey b, int estimatedTokens) {
    final limitA = adaptiveRateLimitManager.get(a.id);
    final limitB = adaptiveRateLimitManager.get(b.id);

    // 计算剩余配额
    final rpmRemainingA = limitA.currentRpmLimit * limitA.marginFactor;
    final rpmRemainingB = limitB.currentRpmLimit * limitB.marginFactor;
    // 检查 TPM 剩余
    final tpmUsedA = rateLimiter.tpmUsed(a);
    final tpmUsedB = rateLimiter.tpmUsed(b);
    final tpmRemainingA = limitA.currentTpmLimit * limitA.marginFactor - tpmUsedA - estimatedTokens;
    final tpmRemainingB = limitB.currentTpmLimit * limitB.marginFactor - tpmUsedB - estimatedTokens;

    // 若任一 key 的 TPM 配额不足，优先选另一个
    if (tpmRemainingA <= 0 && tpmRemainingB > 0) return 1;
    if (tpmRemainingB <= 0 && tpmRemainingA > 0) return -1;

    // 比较综合剩余配额（取 RPM 和 TPM 中较小的那个）
    final quotaA = rpmRemainingA < tpmRemainingA ? rpmRemainingA : tpmRemainingA;
    final quotaB = rpmRemainingB < tpmRemainingB ? rpmRemainingB : tpmRemainingB;
    if (quotaA > quotaB) return -1;
    if (quotaA < quotaB) return 1;

    // 配额相近时，优先选置信度高的
    if (limitA.confidence != limitB.confidence) {
      return limitA.confidence > limitB.confidence ? -1 : 1;
    }
    return 0;
  }

  String _describeNoUsableKeys(List<String> candidates) {
    final now = DateTime.now().millisecondsSinceEpoch;
    var total = 0;
    var inCooldown = 0;
    var exhausted = 0;
    var inactive = 0;
    int? earliestRecoverMs;
    for (final pname in candidates) {
      for (final k in keyManager.getByProvider(pname)) {
        total++;
        switch (k.status) {
          case KeyStatus.error:
            if (k.cooldownUntil != null && k.cooldownUntil! > now) {
              inCooldown++;
              if (earliestRecoverMs == null ||
                  k.cooldownUntil! < earliestRecoverMs) {
                earliestRecoverMs = k.cooldownUntil;
              }
            }
            break;
          case KeyStatus.exhausted:
            exhausted++;
            break;
          case KeyStatus.inactive:
            inactive++;
            break;
          case KeyStatus.active:
            break;
        }
      }
    }
    if (total == 0) {
      return '候选提供商（${candidates.join('、')}）下尚未添加任何 key';
    }
    final parts = <String>[];
    if (inCooldown > 0) parts.add('$inCooldown 个 key 冷却中');
    if (exhausted > 0) parts.add('$exhausted 个 key 今日额度已用尽');
    if (inactive > 0) parts.add('$inactive 个 key 已停用');
    if (parts.isEmpty) parts.add('状态异常');
    var msg = '候选提供商（${candidates.join('、')}）无可用 key：${parts.join('、')}';
    if (earliestRecoverMs != null) {
      final minutes = ((earliestRecoverMs - now) / 60000).ceil();
      msg += '；最早约 $minutes 分钟后自动恢复';
    }
    return msg;
  }

  /// 诊断：哪些 key 被限流以及具体维度（RPM / TPM）
  String _describeRateLimitedKeys(List<String> candidates, String model) {
    var rpmBlocked = 0;
    var tpmBlocked = 0;
    var totalKeys = 0;
    for (final pname in candidates) {
      for (final k in keyManager.getUsableByProvider(pname)) {
        totalKeys++;
        final result = rateLimiter.checkKey(k, model: model);
        if (!result.allowed) {
          if (result.dimension == 'key_tpm') {
            tpmBlocked++;
          } else if (result.dimension == 'key_rpm') {
            rpmBlocked++;
          }
        }
      }
    }
    final parts = <String>[];
    if (rpmBlocked > 0) parts.add('$rpmBlocked 个 key RPM 请求速率达上限');
    if (tpmBlocked > 0) parts.add('$tpmBlocked 个 key TPM token 速率达上限');
    if (parts.isEmpty) parts.add('全部 $totalKeys 个 key 均被限流');
    return '候选 key 均被限流拦截：${parts.join('、')}（稍后自动恢复）';
  }

  /// 读取请求体（受 [Constants.maxRequestBodyBytes] 约束）
  Future<List<int>> _readBody(HttpRequest request) async {
    final out = <int>[];
    await for (final chunk in request) {
      out.addAll(chunk);
      if (out.length > Constants.maxRequestBodyBytes) {
        throw StateError('request body exceeds limit');
      }
    }
    return out;
  }

  /// 将上游流写入客户端，同时采样前 [cap] 字节用于 token 解析
  ///
  /// idle 超时保护：上游长时间无数据（挂起 / 连接半开 / 上游慢）时主动中断，
  /// 避免客户端无限等待（表现为「回答一个简单问题耗时几十秒」）。
  Future<_Captured> _pipeAndCapture(
      Stream<List<int>> source, IOSink sink, int cap) async {
    var total = 0;
    final captured = <int>[];
    var capturedN = 0;
    const idle = Duration(seconds: Constants.upstreamIdleTimeoutSeconds);
    await for (final chunk in source.timeout(idle)) {
      sink.add(chunk);
      total += chunk.length;
      if (capturedN < cap) {
        final take =
            chunk.length < (cap - capturedN) ? chunk.length : (cap - capturedN);
        captured.addAll(chunk.sublist(0, take));
        capturedN += take;
      }
    }
    return _Captured(total, captured);
  }

  /// 捕获上游错误响应体（前 500 字节）用于日志诊断，同时消费完整流以释放连接。
  ///
  /// 返回 null 表示无响应体 / 读取失败。5 秒超时兜底，避免上游挂起拖慢重试。
  Future<String?> _captureUpstreamError(Stream<List<int>> body) async {
    final buf = <int>[];
    try {
      await for (final chunk in body.timeout(const Duration(seconds: 5))) {
        for (final b in chunk) {
          if (buf.length >= 500) break;
          buf.add(b);
        }
      }
    } catch (_) {
      // 超时或流异常：已尽力捕获，忽略
    }
    if (buf.isEmpty) return null;
    return utf8.decode(buf, allowMalformed: true).trim();
  }

  Future<void> _respondError(
      HttpRequest request, int code, String message) async {
    if (request.response.statusCode != code) {
      request.response.statusCode = code;
    }
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'error': message}));
    await request.response.close();
  }

  /// 从响应缓存命中后回写客户端（需求 2.2.4）
  Future<void> _respondFromCache(
      HttpRequest request, CachedResponse hit) async {
    request.response.statusCode = hit.statusCode;
    hit.headers.forEach((name, value) {
      final lower = name.toLowerCase();
      if (BaseHttpProvider.skipResponseHeader(lower)) return;
      request.response.headers.set(name, value);
    });
    // 缓存命中标记（与未命中时的 MISS 对称）
    request.response.headers.set(Constants.cacheHitHeader, 'HIT');
    // 转写响应体；content-length 由框架按实际字节重算（已跳过原头）
    request.response.add(hit.body);
    await request.response.close();
  }

  /// 管理接口：版本信息 / 在线更新检查 / 统计报表 / 缓存统计 / 实时状态
  ///
  /// 这些路径不转发到上游，仅在本地由中转站处理。
  Future<void> _serveAdmin(HttpRequest request, String path) async {
    request.response.headers.contentType = ContentType.json;

    switch (path) {
      // — 当前版本信息 —
      case Constants.versionPath:
        await _jsonResponse(request, 200, {
          'version': Constants.appVersion,
          'build_number': Constants.appBuildNumber,
          'platform': UpdateService.detectPlatform(),
        });
        return;

      // — 触发在线更新检查 —
      case Constants.updateCheckPath:
        if (updateService == null) {
          await _respondError(request, 501, '未配置在线更新服务');
          return;
        }
        final result = await updateService!.checkForUpdate();
        if (result.hasUpdate) _emitUpdateAvailable(result);
        await _jsonResponse(request, 200, result.toJson());
        return;

      // — 统计报表（JSON）—
      case Constants.reportPath:
        if (request.method != 'GET') {
          await _respondError(request, 405, '该接口仅支持 GET');
          return;
        }
        final report = reportService.generate();
        await _jsonResponse(request, 200, report.toJson());
        return;

      // — 缓存统计（DELETE 清空）—
      case Constants.cacheStatsPath:
        if (request.method == 'DELETE') {
          cache.clear();
          await _jsonResponse(
              request, 200, {'cleared': true, 'stats': cache.stats.toJson()});
          return;
        }
        await _jsonResponse(request, 200, cache.stats.toJson());
        return;

      // — 实时状态（默认）—
      case Constants.statsPath:
      default:
        await _jsonResponse(request, 200, {
          'version': Constants.appVersion,
          'active_keys': activeKeyCount,
          'queued': queuedRequests,
          'rate_limit': rateLimiter.snapshot(),
          'cache': cache.stats.toJson(),
        });
        return;
    }
  }

  /// 聚合模型列表接口（/v1/models）
  ///
  /// 始终纯转发：返回全部真实模型明细（含 provider/capability 等扩展字段），
  /// 客户端可直接用这些模型名请求，不做任何虚拟档位收敛。
  ///
  /// 支持 ?provider= / ?capability= / ?status= / ?enabled= 过滤。
  Future<void> _serveModels(HttpRequest request) async {
    final q = request.uri.queryParameters;
    final provider = q['provider'];
    final capability = q['capability'];
    final status = q['status'];
    final enabledOnly = (q['enabled'] ?? 'true') != 'false';
    final models = modelRepository.getFiltered(
      provider: provider,
      capability: capability,
      status: status != null && status != 'all' ? status : null,
      enabledOnly: enabledOnly,
    );

    final data = models.map((m) => m.toOpenAIFormat()).toList();

    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'object': 'list', 'data': data}));
    await request.response.close();
  }

  /// 工具名称合法正则：OpenAI / DeepSeek / 商汤日日新等上游要求
  /// `tools[].function.name` 必须匹配 `^[a-zA-Z0-9_-]+$`。
  static final RegExp _toolNameAllowed = RegExp(r'^[a-zA-Z0-9_-]+$');

  /// 判断工具名称是否合法
  static bool _isValidToolName(String name) => _toolNameAllowed.hasMatch(name);

  /// 把工具名称清洗为合法形式：非法字符逐个替换为 `_`；
  /// 结果为空时兜底为 `tool`（正则要求至少 1 个字符）。
  static String _sanitizeToolName(String name) {
    final out = name.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return out.isEmpty ? 'tool' : out;
  }

  /// 对请求体中的 tools 定义做名称清洗（网关中间件）。
  ///
  /// 背景：Cline / Cursor 等 AI 编程助手或 MCP Server 动态注入的
  /// `tools[].function.name` 常含 `.` / 空格 / 中文 / `@` 等非法字符，
  /// DeepSeek、商汤日日新等上游会直接拒绝（HTTP 400：
  /// `Invalid 'tools[0].function.name': string does not match pattern ...`）。
  /// 本方法在转发前把 `function.name` 与 `parameters.properties` 属性键名
  /// 统一清洗为 `^[a-zA-Z0-9_-]+$`，保证上游接受。
  ///
  /// 仅对可解析 JSON 且含 `tools` 数组的请求体生效；无法解析、不含 tools、
  /// 或名称本就合法时原样返回，不改变任何请求语义。
  ProxyRequest _sanitizeToolsInBody(ProxyRequest req) {
    if (req.body.isEmpty) return req;
    // 快速预检：大多数请求（纯聊天补全）不含 tools 字段，
    // 通过字节扫描避免对每次请求都做完整 JSON 解码，减少热路径开销。
    if (!_hasToolsInBody(req.body)) return req;
    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(req.body, allowMalformed: false));
    } catch (_) {
      return req; // 无法解析时原样透传，交由上游处理
    }
    if (decoded is! Map<String, dynamic>) return req;
    final tools = decoded['tools'];
    if (tools is! List || tools.isEmpty) return req;

    var changed = false;
    for (final t in tools) {
      if (t is! Map<String, dynamic>) continue;
      final fn = t['function'];
      if (fn is! Map<String, dynamic>) continue;

      // 1) function.name 清洗
      final name = fn['name'];
      if (name is String && !_isValidToolName(name)) {
        final sanitized = _sanitizeToolName(name);
        if (sanitized != name) {
          fn['name'] = sanitized;
          changed = true;
        }
      }

      // 2) parameters.properties 属性键名清洗（同样须符合正则），
      //    冲突键追加数字后缀，避免覆盖已有合法键。
      final params = fn['parameters'];
      if (params is Map<String, dynamic>) {
        final props = params['properties'];
        if (props is Map<String, dynamic>) {
          final cleanedProps = <String, dynamic>{};
          for (final e in props.entries) {
            final k = e.key;
            var base = k;
            if (!_isValidToolName(k)) {
              base = _sanitizeToolName(k);
              changed = true;
            }
            var nk = base;
            var suffix = 2;
            while (cleanedProps.containsKey(nk)) {
              nk = '$base$suffix';
              suffix++;
            }
            if (nk != k) changed = true;
            cleanedProps[nk] = e.value;
          }
          if (cleanedProps.length != props.length) changed = true;
          params['properties'] = cleanedProps;
        }
      }
    }
    if (!changed) return req;

    final newBody = utf8.encode(jsonEncode(decoded));
    return ProxyRequest(
      method: req.method,
      path: req.path,
      query: req.query,
      headers: req.headers,
      body: newBody,
      model: req.model,
      stream: req.stream,
      clientIp: req.clientIp,
    );
  }

  /// 字节级快速预检：判断请求体是否含 tools 字段。
  /// 仅根据 ASCII 字面量 `"tools"` 和可能的分隔符做轻量模式匹配，
  /// 避免对纯聊天请求做完整 JSON 解码（热路径优化）。
  static bool _hasToolsInBody(List<int> body) {
    // 在最多前 4096 字节内扫描 '"tools"'（前面可含空白，紧跟在 { 或 , 后）
    final limit = body.length < 4096 ? body.length : 4096;
    for (var i = 0; i < limit - 7; i++) {
      // 匹配 `"tools"`
      if (body[i] == 34 && // "
          body[i + 1] == 116 && // t
          body[i + 2] == 111 && // o
          body[i + 3] == 111 && // o
          body[i + 4] == 108 && // l
          body[i + 5] == 115 && // s
          body[i + 6] == 34) {
        // "
        // 确认前面是 { 或 , （跳过空白）
        var j = i - 1;
        while (j >= 0 && (body[j] == 32 || body[j] == 10 || body[j] == 13 || body[j] == 9)) {
          j--;
        }
        if (j >= 0 && (body[j] == 123 || body[j] == 44)) return true; // { 또는 ,
      }
    }
    return false;
  }

  /// 以 JSON 写入响应并关闭
  Future<void> _jsonResponse(
      HttpRequest request, int code, Map<String, dynamic> body) async {
    request.response.statusCode = code;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  /// 触发限流时产生一条告警（需求 2.2.6）
  void _emitRateLimitAlert(RateLimitResult inbound, String clientIp) {
    onAlert?.call(Alert(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      event: AlertEvent.rateLimited,
      level: AlertLevel.warning,
      title: L10n.fmt('触发限流（{dimension}）', {'dimension': inbound.dimension}),
      message: L10n.fmt('来源 {ip} 因「{dim}」被限流：{msg}',
          {'ip': clientIp, 'dim': inbound.dimension, 'msg': inbound.message}),
      data: {
        'dimension': inbound.dimension,
        'client_ip': clientIp,
        'retry_after': inbound.retryAfterSeconds,
      },
    ));
  }

  /// 发现新版本时产生一条告警（供 Webhook / 通知）
  void _emitUpdateAvailable(UpdateCheckResult result) {
    final release = result.release;
    onAlert?.call(Alert(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      event: AlertEvent.updateAvailable,
      level: result.mustUpdate ? AlertLevel.critical : AlertLevel.info,
      title: L10n.fmt(
          '发现新版本 {version}', {'version': release?.displayVersion ?? ''}),
      message: release?.releaseNotes.isNotEmpty == true
          ? release!.releaseNotes
          : L10n.tr('有可用更新'),
      data: {
        'version': release?.version ?? '',
        'build_number': release?.buildNumber ?? 0,
        'channel': release?.channel ?? '',
        'mandatory': result.mustUpdate,
        'below_min_supported': result.belowMinSupported,
      },
    ));
  }

  /// 记录一条「限流切换 Key」事件（时间 / Key / 原因 / 更新前后限制值）
  void _recordRateLimitEvent({
    required ApiKey key,
    required String reason, // rpm / tpm / 429 / quota
    String model = '',
    int oldRpmLimit = 0,
    int oldTpmLimit = 0,
    int newRpmLimit = 0,
    int newTpmLimit = 0,
    String detail = '',
  }) {
    rateLimitEventLog?.add(RateLimitEvent(
      id: 'rle-${DateTime.now().microsecondsSinceEpoch}-${key.id.hashCode.abs()}',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      keyId: key.id,
      keyName: key.name,
      providerId: key.providerId.isNotEmpty ? key.providerId : key.provider,
      providerType: key.provider,
      reason: reason,
      model: model,
      oldRpmLimit: oldRpmLimit,
      oldTpmLimit: oldTpmLimit,
      newRpmLimit: newRpmLimit,
      newTpmLimit: newTpmLimit,
      detail: detail,
    ));
  }

  /// Key 状态变更时产生告警（需求 2.2.5：key.status_changed 事件）
  void _maybeEmitKeyStatusChanged(ApiKey key, KeyStatus prev) {
    if (key.status == prev) return;
    onAlert?.call(Alert(
      id: 'keystatus-${key.id}-${DateTime.now().microsecondsSinceEpoch}',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      event: AlertEvent.keyStatusChanged,
      level:
          key.status == KeyStatus.active ? AlertLevel.info : AlertLevel.warning,
      title: 'Key ${key.name} 状态变更',
      message: '${_statusLabel(prev)} → ${_statusLabel(key.status)}',
      keyId: key.id,
      data: {
        'provider': key.providerId.isNotEmpty ? key.providerId : key.provider,
        'from': prev.name,
        'to': key.status.name,
      },
    ));
  }

  static String _statusLabel(KeyStatus s) {
    switch (s) {
      case KeyStatus.active:
        return '正常';
      case KeyStatus.error:
        return '异常';
      case KeyStatus.exhausted:
        return '额度耗尽';
      case KeyStatus.inactive:
        return '已停用';
    }
  }

  void _recordLog(
    HttpRequest request,
    ApiKey? key,
    String provider,
    int statusCode,
    int durationMs, {
    String? model,
    String? actualModel,
    int promptTokens = 0,
    int completionTokens = 0,
    int requestBytes = 0,
    int responseBytes = 0,
    bool streaming = false,
    int retries = 0,
    String? ruleName,
    String? error,
    bool cached = false,
    String rateLimited = '',
  }) {
    final log = RequestLog(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      method: request.method,
      path: request.uri.path,
      provider: provider,
      keyId: key?.id ?? '',
      keyName: key?.name ?? '',
      keyMasked: key?.maskedKey ?? '****',
      model: model ?? '',
      actualModel: actualModel ?? '',
      statusCode: statusCode,
      durationMs: durationMs,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      requestBytes: requestBytes,
      responseBytes: responseBytes,
      streaming: streaming,
      retries: retries,
      ruleName: ruleName,
      error: error,
      cached: cached,
      rateLimited: rateLimited,
    );
    logService.add(log);
  }
}

class _ForwardOutcome {
  final ApiKey key;
  final ProviderResult result;
  final int attempts;
  _ForwardOutcome(this.key, this.result, this.attempts);
}

/// 转发失败（含具体原因，供 503 响应与日志展示）
class _ForwardFailure {
  final String reason;
  final String? lastError;
  final String? actualModel; // 最后一次尝试实际发送的模型名
  /// 非空且 >0 时表示应返回「上游 TPM 限流，建议客户端等待后重试」，
  /// 由调用方用 429 + Retry-After 响应（而非硬断 503）。
  final int retryAfterSeconds;
  const _ForwardFailure(
    this.reason,
    this.lastError, [
    this.actualModel,
    this.retryAfterSeconds = 0,
  ]);
}

class _Captured {
  final int total;
  final List<int> captured;
  _Captured(this.total, this.captured);
}

class _ProxyOverload {
  const _ProxyOverload();
}
