import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:relaygo/config/constants.dart';
import 'package:relaygo/config/theme.dart';
import 'package:relaygo/database/database_helper.dart';
import 'package:relaygo/database/provider_repository.dart';
import 'package:relaygo/models/alert.dart';
import 'package:relaygo/models/api_key.dart';
import 'package:relaygo/models/key_test.dart';
import 'package:relaygo/models/provider_definition.dart';
import 'package:relaygo/models/routing_rule.dart';
import 'package:relaygo/models/user_settings.dart';
import 'package:relaygo/models/rate_limit_event.dart';
import 'package:relaygo/services/key_manager.dart';
import 'package:relaygo/services/load_balancer.dart';
import 'package:relaygo/services/log_service.dart';
import 'package:relaygo/services/oauth_token_refresher.dart';
import 'package:relaygo/services/rate_limit_event_log.dart';
import 'package:relaygo/services/quota_monitor.dart';
import 'package:relaygo/services/rule_engine.dart';
import 'package:relaygo/services/proxy_server.dart';
import 'package:relaygo/services/keep_alive.dart';
import 'package:relaygo/services/update_service.dart';
import 'package:relaygo/services/free_api_service.dart';
import 'package:relaygo/database/model_repository.dart';
import 'package:relaygo/services/model_sync_service.dart';
import 'package:relaygo/models/model_info.dart';
import 'package:relaygo/models/app_release.dart';
import 'package:relaygo/l10n/app_strings.dart';
import 'package:relaygo/screens/home_screen.dart';

/// 全局应用状态（状态管理入口）
class AppState extends ChangeNotifier {
  late final KeyManager keyManager;
  late final LoadBalancer loadBalancer;
  late final LogService logService;
  late final RateLimitEventLog rateLimitEventLog;
  late final RuleEngine ruleEngine;
  late final QuotaMonitor quotaMonitor;
  late final ProxyServer proxy;
  late final UpdateService updateService;
  late final FreeApiService freeApiService;
  late final ModelRepository modelRepository;
  late final ModelSyncService modelSync;
  late final ProviderRepository providerRepository;
  late UserSettings settings;
  Timer? _autoSyncTimer;
  Timer? _keyRecoveryTimer;
  Timer? _updateCheckTimer; // 定期后台检查更新（24h）
  Timer? _watchdogTimer; // 保活看门狗：代理服务异常退出时自动重启
  bool _userWantsRunning = false; // 用户是否期望代理持续运行（看门狗依据）
  DateTime? _serverStartedAt; // 服务最近一次启动时间（用于首页运行时长）
  List<ApiKey> keys = [];

  final StreamController<Alert> _alertController =
      StreamController<Alert>.broadcast();
  final Box<dynamic> _alertsBox;
  final Box<dynamic> _rulesBox;

  AppState({Box<dynamic>? alertsBox, Box<dynamic>? rulesBox})
      : _alertsBox = alertsBox ?? DatabaseHelper.alerts,
        _rulesBox = rulesBox ?? DatabaseHelper.rules {
    keyManager = KeyManager(DatabaseHelper.keys);
    loadBalancer = LoadBalancer();
    providerRepository = ProviderRepository(DatabaseHelper.providers);
    settings = _loadSettings();
    logService = LogService(
      DatabaseHelper.logs,
      maxEntries: settings.maxLogEntries,
      retentionDays: settings.logRetentionDays,
    );
    // 初始化文件日志目录（一天一个 .log 文件，JSONL 格式）
    _initLogDirectory();
    rateLimitEventLog = RateLimitEventLog(DatabaseHelper.rateLimitEvents);
    ruleEngine = RuleEngine(rules: _loadRules());
    quotaMonitor = QuotaMonitor(
      settings: settings,
      onAlert: _handleAlert,
    );
    updateService = _buildUpdateService(settings);
    freeApiService = FreeApiService();
    modelRepository = ModelRepository(DatabaseHelper.models);
    modelSync = ModelSyncService(keyManager, modelRepository,
        historyBox: DatabaseHelper.syncHistory);
    proxy = ProxyServer(
      keyManager: keyManager,
      loadBalancer: loadBalancer,
      logService: logService,
      ruleEngine: ruleEngine,
      quotaMonitor: quotaMonitor,
      settings: settings,
      updateService: updateService,
      modelRepository: modelRepository,
      rateLimitEventLog: rateLimitEventLog,
      port: settings.port,
      host: settings.host,
      loadBalanceStrategy: settings.loadBalanceStrategy,
    );
    proxy.onAlert = _handleAlert;
    // 装配 OAuth Token 自动刷新服务（P3）
    // 统一创建一个 OAuthTokenRefresher 实例，注入到 proxy / keyManager / modelSync，
    // 确保「转发请求」「测试 key」「拉取模型」三条路径都能自动刷新过期的 OAuth token。
    final oauthRefresher = OAuthTokenRefresher(keyManager);
    proxy.oauthRefresher = oauthRefresher;
    keyManager.ensureFreshTokenFn = oauthRefresher.ensureFreshToken;
    modelSync.ensureFreshTokenFn = oauthRefresher.ensureFreshToken;
    _startupAlerts();
    L10n.instance.language = settings.language;
    refreshKeys();
    if (settings.autoCheckUpdate) {
      unawaited(_autoCheckUpdate());
      _startPeriodicUpdateCheck();
    }
    if (settings.autoSyncModelsOnStartup) unawaited(_autoSyncModels());
    // 免费 API 推荐：启动时后台检查缓存是否过期（>24h），过期则静默刷新
    unawaited(_autoRefreshFreeApi());
    _scheduleAutoSync();
    _startKeyRecoveryTimer();
    _startWatchdog();
    // 开机自启：异步执行，不阻塞 UI（release 模式下 proxy.start() 会阻塞主线程导致卡启动页）
    unawaited(_maybeAutoStartOnBoot());
  }

  /// 周期性 Key 状态恢复（每 60 秒）：
  ///  - 日/月滚动（恢复 exhausted 的 key）
  ///  - error 且冷却已过期的 key 自动恢复为 active
  ///
  /// 避免「后台无请求时 key 长期停留在 error/exhausted，导致候选池为空」。
  void _startKeyRecoveryTimer() {
    _keyRecoveryTimer?.cancel();
    _keyRecoveryTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      unawaited(_recoverKeysPeriodically());
    });
  }

  Future<void> _recoverKeysPeriodically() async {
    var changed = false;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final k in keyManager.getAll()) {
      var dirty = false;
      // 1) 日/月滚动（exhausted 跨日自动恢复）
      final alerts = quotaMonitor.rollIfNeeded(k);
      if (alerts.isNotEmpty) {
        dirty = true;
        for (final a in alerts) {
          _handleAlert(a);
        }
      }
      // 2) error 且冷却已结束 → 恢复为 active
      if (k.status == KeyStatus.error &&
          k.cooldownUntil != null &&
          k.cooldownUntil! <= now) {
        k.status = KeyStatus.active;
        k.cooldownUntil = null;
        k.failureCount = 0;
        dirty = true;
        _handleAlert(Alert(
          id: 'keystatus-$k.id-$now',
          timestamp: now,
          event: AlertEvent.keyStatusChanged,
          level: AlertLevel.info,
          title: 'Key ${k.name} 自动恢复',
          message: '冷却结束，已自动恢复为可用',
          keyId: k.id,
          data: {'provider': k.provider, 'to': 'active'},
        ));
      }
      if (dirty) {
        await keyManager.updateKey(k);
        changed = true;
      }
    }
    if (changed) {
      refreshKeys();
    }
  }

  @override
  void dispose() {
    _autoSyncTimer?.cancel();
    _keyRecoveryTimer?.cancel();
    _updateCheckTimer?.cancel();
    _watchdogTimer?.cancel();
    rateLimitEventLog.dispose();
    super.dispose();
  }

  /// 保活看门狗（每 15 秒）：
  /// 当「用户期望代理运行」但服务意外退出时自动重启，实现崩溃自愈。
  /// 仅在保活开关开启时生效。
  void _startWatchdog() {
    _watchdogTimer?.cancel();
    if (!settings.keepAliveEnabled) return;
    _watchdogTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_watchdogCheck());
    });
  }

  Future<void> _watchdogCheck() async {
    if (!settings.keepAliveEnabled) return;
    if (!_userWantsRunning) return; // 用户已手动停止，不干预
    if (proxy.isRunning) return;
    // 服务意外退出：自动重启并告警
    try {
      await proxy.start();
      _handleAlert(Alert(
        id: 'watchdog.restart-${DateTime.now().millisecondsSinceEpoch}',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        event: AlertEvent.serverStarted,
        level: AlertLevel.warning,
        title: L10n.tr('代理服务已自动恢复'),
        message: L10n.tr('检测到服务异常退出，看门狗已自动重启'),
      ));
      notifyListeners();
    } catch (e) {
      // 重启失败（如端口被占用）：静默，下个周期再试
    }
  }

  /// 开机自启：仅在用户开启「开机自启」且代理服务未运行时自动启动。
  Future<void> _maybeAutoStartOnBoot() async {
    if (!settings.keepAliveEnabled) return;
    if (!settings.autoStartOnBoot) return;
    if (proxy.isRunning) return;
    await startServer();
  }

  /// 启动代理服务；若开启保活，同时拉起 Android 前台服务。
  Future<void> startServer() async {
    try {
      await proxy.start();
      _userWantsRunning = true;
      _serverStartedAt = DateTime.now();
      if (settings.keepAliveEnabled) {
        unawaited(KeepAliveHelper.start());
      }
      _handleAlert(Alert(
        id: 'server.started.run-${DateTime.now().millisecondsSinceEpoch}',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        event: AlertEvent.serverStarted,
        level: AlertLevel.info,
        title: L10n.tr('代理服务已启动'),
        message: L10n.fmt('监听 {host}:{port}',
            {'host': proxy.host, 'port': '${proxy.port}'}),
      ));
      notifyListeners();
    } catch (e) {
      _handleAlert(Alert(
        id: 'server.start.failed-${DateTime.now().millisecondsSinceEpoch}',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        event: AlertEvent.serverError,
        level: AlertLevel.critical,
        title: L10n.tr('服务启动失败'),
        message: e.toString(),
      ));
      rethrow;
    }
  }

  /// 停止代理服务；若开启保活，同时停止 Android 前台服务。
  Future<void> stopServer() async {
    await proxy.stop();
    _userWantsRunning = false;
    _serverStartedAt = null;
    if (settings.keepAliveEnabled) {
      unawaited(KeepAliveHelper.stop());
    }
    _handleAlert(Alert(
      id: 'server.stopped-${DateTime.now().millisecondsSinceEpoch}',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      event: AlertEvent.serverStopped,
      level: AlertLevel.info,
      title: L10n.tr('代理服务已停止'),
      message: '',
    ));
    notifyListeners();
  }

  /// 启动后异步刷新免费 API 推荐缓存（失败静默，保留旧缓存）
  Future<void> _autoRefreshFreeApi() async {
    try {
      await freeApiService.ensureFresh();
    } catch (_) {
      // 网络不通 / 数据异常：静默忽略，页面仍展示本地缓存
    }
  }

  /// 周期性自动同步模型列表（REQ-003）
  ///
  /// 按 [UserSettings.modelSyncIntervalHours] 调度 Timer。仅当「启动时自动同步」
  /// 开启时才生效，使该开关成为「自动同步」的总开关；间隔或开关变更时重建。
  void _scheduleAutoSync() {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;
    if (!settings.autoSyncModelsOnStartup) return;
    final hours = settings.modelSyncIntervalHours;
    if (hours <= 0) return;
    _autoSyncTimer = Timer.periodic(Duration(hours: hours), (_) {
      unawaited(_autoSyncModels());
    });
  }

  /// 在线更新服务：更新源/渠道跟随设置（方案一 GitHub Releases + 回退清单）
  UpdateService _buildUpdateService(UserSettings s) => UpdateService(
        feedUrl: s.updateFeedUrl,
        githubRepo: s.updateGithubRepo,
        channel: s.updateChannel,
        currentVersion: Constants.appVersion,
        currentBuildNumber: Constants.appBuildNumber,
      );

  Stream<Alert> get alertStream => _alertController.stream;

  UserSettings _loadSettings() {
    final raw = DatabaseHelper.settings.get('user');
    if (raw != null) {
      final s = UserSettings.fromJson(Map<String, dynamic>.from(raw as Map));
      // 旧版本默认监听 127.0.0.1（仅本机），升级为 0.0.0.0
      // 以便局域网内第三方应用访问中转站；用户仍可在设置中改回本机模式。
      if (s.host == '127.0.0.1') {
        return s.copyWith(host: Constants.defaultHost);
      }
      return s;
    }
    return UserSettings();
  }

  List<RoutingRule> _loadRules() {
    final list = _rulesBox.values
        .whereType<Map>()
        .map((m) => RoutingRule.fromJson(Map<String, dynamic>.from(m)))
        .toList();
    list.sort((a, b) => a.order.compareTo(b.order));
    return list;
  }

  void _startupAlerts() {
    if (!settings.alertsEnabled) return;
    _handleAlert(Alert(
      id: 'server.started-${DateTime.now().millisecondsSinceEpoch}',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      event: AlertEvent.serverStarted,
      level: AlertLevel.info,
      title: L10n.tr('代理服务已就绪'),
      message: L10n.fmt('监听 {host}:{port}',
          {'host': settings.host, 'port': '${settings.port}'}),
    ));
  }

  /// 初始化按天日志文件目录（异步不阻塞 UI）
  void _initLogDirectory() {
    if (logService.logDirectory != null) return;
    getApplicationDocumentsDirectory().then((docs) {
      logService.logDirectory = Directory('${docs.path}/relay-logs');
    }, onError: (_) {
      // path_provider 不可用时静默降级，仅内存/Hive 日志
    });
  }

  /// 启动后异步检查更新（不阻塞 UI），发现新版本时产生告警
  Future<void> _autoCheckUpdate() async {
    try {
      final result = await updateService.checkForUpdate();
      if (result.hasUpdate) _alertUpdateAvailable(result);
    } catch (_) {
      // 网络不通 / 更新源不可达：静默忽略
    }
  }

  /// 定期后台检查更新（方案一：GitHub Releases + 应用内检查）。
  /// 与启动检查共用 [updateService] 的节流逻辑，静默执行、失败不打扰用户。
  void _startPeriodicUpdateCheck() {
    _updateCheckTimer?.cancel();
    _updateCheckTimer = Timer.periodic(
      const Duration(hours: Constants.updatePeriodicCheckHours),
      (_) => unawaited(_autoCheckUpdate()),
    );
  }

  /// 启动后异步同步模型列表（不阻塞 UI），失败静默忽略
  Future<void> _autoSyncModels() async {
    try {
      await modelSync.syncAll(
        autoDisableRemoved: settings.autoDisableRemovedModels,
      );
    } catch (_) {
      // 网络不通 / key 无效：静默忽略，用户可随时手动同步
    }
  }

  /// 供 UI 主动触发「同步所有模型」
  Future<SyncResult> syncModels({
    void Function(SyncProgress)? onProgress,
    bool Function()? isCancelled,
  }) =>
      modelSync.syncAll(
        onProgress: onProgress,
        isCancelled: isCancelled,
        autoDisableRemoved: settings.autoDisableRemovedModels,
      );

  /// 同步单个服务商
  Future<ProviderSyncResult> syncProviderModels(String provider,
          {bool Function()? isCancelled}) =>
      modelSync.syncProvider(provider,
          isCancelled: isCancelled,
          autoDisableRemoved: settings.autoDisableRemovedModels);

  /// 本地模型库（供 UI 直接展示）
  List<ModelInfo> get models => modelRepository.getAll();
  List<ModelInfo> get enabledModels => modelRepository.getEnabled();
  List<Map<String, dynamic>> get syncHistory => modelSync.getHistory();

  /// 供 UI 主动触发检查更新
  Future<UpdateCheckResult> checkForUpdate() async {
    final result = await updateService.checkForUpdate();
    if (result.hasUpdate) _alertUpdateAvailable(result);
    return result;
  }

  void _alertUpdateAvailable(UpdateCheckResult result) {
    final release = result.release;
    _handleAlert(Alert(
      id: 'update-${DateTime.now().microsecondsSinceEpoch}',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      event: AlertEvent.updateAvailable,
      level: result.mustUpdate ? AlertLevel.critical : AlertLevel.info,
      title: L10n.fmt('发现新版本 {version}',
          {'version': release?.displayVersion ?? ''}),
      message: release?.releaseNotes.isNotEmpty == true
          ? release!.releaseNotes
          : L10n.tr('有可用更新'),
      data: {
        'version': release?.version ?? '',
        'build_number': release?.buildNumber ?? 0,
        'channel': release?.channel ?? '',
        'mandatory': result.mustUpdate,
      },
    ));
  }

  /// 统一告警处理：持久化 + 广播
  void _handleAlert(Alert alert) {
    if (!settings.alertsEnabled) return;
    _alertController.add(alert);
    // 持久化（超出上限时丢弃最旧）
    final count = _alertsBox.length;
    if (count >= Constants.alertsCap) {
      final first = _alertsBox.keys.first;
      _alertsBox.delete(first);
    }
    _alertsBox.put(alert.id, alert.toJson());
  }

  bool get serverRunning => proxy.isRunning;

  /// 服务最近一次启动时间（未运行时为 null）
  DateTime? get serverStartedAt => _serverStartedAt;

  List<RoutingRule> get rules => ruleEngine.rules;

  int get activeKeyCount =>
      keys.where((k) => k.status == KeyStatus.active).length;

  int get totalKeyCount => keys.length;

  /// 未读告警数
  int get unreadAlerts {
    var n = 0;
    for (final v in _alertsBox.values) {
      if (v is Map && (v['read'] != true)) n++;
    }
    return n;
  }

  List<Alert> getAlerts({bool unreadOnly = false}) {
    final list = _alertsBox.values
        .whereType<Map>()
        .map((m) => Alert.fromJson(Map<String, dynamic>.from(m)))
        .where((a) => !unreadOnly || !a.read)
        .toList();
    list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return list;
  }

  Future<void> markAlertRead(String id) async {
    final v = _alertsBox.get(id);
    if (v is Map) {
      final alert = Alert.fromJson(Map<String, dynamic>.from(v));
      await _alertsBox.put(id, alert.markRead().toJson());
      notifyListeners();
    }
  }

  /// 全部标记为已读（进入告警中心时调用，退出后首页红点即消失）
  Future<void> markAllAlertsRead() async {
    var changed = false;
    for (final v in _alertsBox.values) {
      if (v is Map && (v['read'] != true)) {
        final alert = Alert.fromJson(Map<String, dynamic>.from(v));
        await _alertsBox.put(alert.id, alert.markRead().toJson());
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  Future<void> clearAlerts() async {
    await _alertsBox.clear();
    notifyListeners();
  }

  /// 删除单条告警（用于告警中心左滑删除；必须真正移除，才能让 Dismissible
  /// 安全地离开 widget 树，避免 "A dismissed Dismissible is still part of the tree"）。
  Future<void> deleteAlert(String id) async {
    if (_alertsBox.containsKey(id)) {
      await _alertsBox.delete(id);
      notifyListeners();
    }
  }

  void refreshKeys() {
    keys = keyManager.getAll();
    // 日/月滚动重置（防止后台无请求时计数长期失真）
    for (final k in keys) {
      final alerts = quotaMonitor.rollIfNeeded(k);
      for (final a in alerts) {
        _handleAlert(a);
      }
      if (alerts.isNotEmpty) keyManager.updateKey(k);
    }
    notifyListeners();
  }

  // —— 提供商管理 ——
  List<ProviderDefinition> get providers => providerRepository.getAll();

  List<ProviderDefinition> get customProviders => providerRepository.getCustom();

  ProviderDefinition? getProvider(String id) => providerRepository.byId(id);

  Future<void> saveProvider(ProviderDefinition p) async {
    await providerRepository.save(p);
    notifyListeners();
  }

  Future<void> deleteProvider(String id) async {
    if (providerRepository.isCustom(id)) {
      await providerRepository.delete(id);
      notifyListeners();
    }
  }

  Future<void> toggleServer() async {
    if (proxy.isRunning) {
      await stopServer();
    } else {
      await startServer();
    }
  }

  Future<ApiKey> addKey({
    required String provider,
    required String plainKey,
    required String name,
    String? providerId,
    String? baseUrl,
    String note = '',
    int priority = 100,
    int weight = 1,
    int maxRpm = 60,
    int dailyQuota = 1000000,
    String group = '',
    Map<String, dynamic> metadata = const {},
    Map<String, String> customHeaders = const {},
  }) async {
    final k = await keyManager.createKey(
      provider: provider,
      providerId: providerId,
      plainKey: plainKey,
      name: name,
      baseUrl: baseUrl,
      note: note,
      priority: priority,
      weight: weight,
      maxRpm: maxRpm,
      dailyQuota: dailyQuota,
      metadata: metadata,
      customHeaders: customHeaders,
    );
    if (group.isNotEmpty) {
      await keyManager.updateKey(k.copyWith(group: group));
    }
    refreshKeys();
    return k;
  }

  Future<void> deleteKey(String id) async {
    // 保留被删 key 的服务商信息，供删除后重同步受影响提供商
    final k = keyManager.getById(id);
    await keyManager.deleteKey(id);
    // 清除该 key 拉取的模型，避免「删 key 后其模型仍残留」
    await modelRepository.removeBySourceKey(id);
    refreshKeys();
    if (k != null) {
      // 重同步：用剩余 key 重新拉取，恢复应保留的模型
      try {
        await modelSync.syncProvider(k.provider, providerId: k.providerId);
      } catch (_) {
        // 网络失败等场景静默处理：模型已清除，等待下次手动同步
      }
    }
  }

  Future<void> updateKey(ApiKey key) async {
    await keyManager.updateKey(key);
    refreshKeys();
  }

  Future<KeyTestOutcome> testKey(ApiKey key) => keyManager.testKey(key);

  /// 批量测试一组 key（需求 2.2），完成后刷新列表
  Future<BatchTestSummary> batchTestKeys(
    List<ApiKey> keys, {
    Future<void> Function(KeyTestRecord record, int done, int total)? onProgress,
    bool Function()? isCancelled,
    int concurrency = 5,
    Duration perKeyTimeout = const Duration(seconds: 10),
    int retries = 1,
  }) async {
    final summary = await keyManager.batchTestKeys(
      keys,
      onProgress: onProgress,
      isCancelled: isCancelled,
      concurrency: concurrency,
      perKeyTimeout: perKeyTimeout,
      retries: retries,
    );
    refreshKeys();
    return summary;
  }

  /// 批量导入 key（明文行，支持 note / base_url）
  Future<int> importKeys(List<Map<String, String>> rows) async {
    final n = await keyManager.importKeys(rows);
    refreshKeys();
    return n;
  }

  /// 一键导出所有 key 为明文 JSON（用于备份 / 重装后导入）
  ///
  /// 返回的 JSON 数组可直接通过「批量导入」恢复（字段与 [importKeys] 兼容）。
  String exportKeysJson() => jsonEncode(keyManager.exportKeys());

  /// 一键禁用所有失败 key（invalid/timeout/error）
  Future<int> bulkDisableInvalid(List<KeyTestRecord> records) async {
    var n = 0;
    for (final r in records) {
      final k = keyManager.getById(r.id);
      if (k == null) continue;
      await keyManager.updateKey(k.copyWith(status: KeyStatus.inactive));
      n++;
    }
    refreshKeys();
    return n;
  }

  /// 一键删除所有失败 key
  Future<int> bulkDeleteInvalid(List<KeyTestRecord> records) async {
    for (final r in records) {
      await keyManager.deleteKey(r.id);
    }
    refreshKeys();
    return records.length;
  }

  // —— 规则管理 ——
  Future<void> addRule(RoutingRule rule) async {
    await _rulesBox.put(rule.id, rule.toJson());
    _syncRules();
  }

  Future<void> updateRule(RoutingRule rule) async {
    await _rulesBox.put(rule.id, rule.toJson());
    _syncRules();
  }

  Future<void> deleteRule(String id) async {
    await _rulesBox.delete(id);
    _syncRules();
  }

  void _syncRules() {
    ruleEngine.setRules(_loadRules());
    notifyListeners();
  }

  // —— 设置 ——
  Future<void> saveSettings(UserSettings s) async {
    final hostChanged = s.host != settings.host || s.port != settings.port;
    final keepAliveChanged = s.keepAliveEnabled != settings.keepAliveEnabled;
    settings = s;
    await DatabaseHelper.settings.put('user', s.toJson());
    proxy.port = s.port;
    proxy.host = s.host;
    proxy.loadBalanceStrategy = s.loadBalanceStrategy;
    logService.maxEntries = s.maxLogEntries;
    logService.retentionDays = s.logRetentionDays;
    quotaMonitor = QuotaMonitor(settings: s, onAlert: _handleAlert);
    updateService.feedUrl = s.updateFeedUrl;
    updateService.channel = s.updateChannel;
    L10n.instance.language = s.language;
    notifyListeners();
    _scheduleAutoSync();
    // 保活开关变更：开启时若代理在运行则拉起前台服务；关闭时停止前台服务
    if (keepAliveChanged) {
      if (s.keepAliveEnabled) {
        _startWatchdog();
        if (proxy.isRunning) unawaited(KeepAliveHelper.start());
      } else {
        _watchdogTimer?.cancel();
        _watchdogTimer = null;
        unawaited(KeepAliveHelper.stop());
      }
    }
    // 监听地址 / 端口变更时，若代理正在运行则自动重启以立即生效
    if (hostChanged && proxy.isRunning) {
      await proxy.restart();
      notifyListeners();
    }
  }

  /// 日志清理（需求 2.2.1）
  Future<int> cleanupLogs() => logService.cleanup();

  // —— 限流切换 Key 事件 ——

  /// 新增限流切换事件（由代理服务器在切换点调用）
  void addRateLimitEvent({
    required String keyId,
    required String keyName,
    required String providerId,
    required String providerType,
    required String reason,
    String model = '',
    int oldRpmLimit = 0,
    int oldTpmLimit = 0,
    int newRpmLimit = 0,
    int newTpmLimit = 0,
    String detail = '',
  }) {
    rateLimitEventLog.add(RateLimitEvent(
      id: 'rle-${DateTime.now().microsecondsSinceEpoch}-${keyId.hashCode.abs()}',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      keyId: keyId,
      keyName: keyName,
      providerId: providerId,
      providerType: providerType,
      reason: reason,
      model: model,
      oldRpmLimit: oldRpmLimit,
      oldTpmLimit: oldTpmLimit,
      newRpmLimit: newRpmLimit,
      newTpmLimit: newTpmLimit,
      detail: detail,
    ));
  }

  /// 全部限流切换事件（最新在前）
  List<RateLimitEvent> get rateLimitEvents => rateLimitEventLog.recent;

  /// 限流事件实时流（供监控页订阅刷新）
  Stream<RateLimitEvent> get rateLimitEventStream => rateLimitEventLog.stream;

  // —— Key 实时监控数据 ——

  /// 单个 Key 的实时监控快照：
  /// 请求速率（令牌桶剩余）、Token 速率（窗口已用/剩余）、冷却状态、自适应学习置信度与结果。
  Map<String, dynamic> keyMonitorSnapshot(ApiKey key) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final inCooldown =
        key.cooldownUntil != null && key.cooldownUntil! > now;
    final adaptive = proxy.adaptiveRateLimitManager.get(key.id);
    final learned = proxy.rateLimiter.learnedTpmAll(key);
    return {
      'key': key,
      'rpm_used_min': proxy.rateLimiter.rpmRemaining(key) < 0
          ? null
          : (proxy.rateLimiter.rpmRemaining(key)), // 剩余突发令牌
      'rpm_remaining': proxy.rateLimiter.rpmRemaining(key),
      'tpm_used': proxy.rateLimiter.tpmUsed(key),
      'tpm_limit': proxy.rateLimiter.effectiveTpmLimit(key),
      'tpm_remaining': proxy.rateLimiter.tpmRemaining(key),
      'in_cooldown': inCooldown,
      'cooldown_until': key.cooldownUntil,
      'learned': learned,
      'adaptive': adaptive,
    };
  }

  /// 全部 Key 的实时监控数据（供首页展示）
  List<Map<String, dynamic>> get keyMonitors =>
      keys.map(keyMonitorSnapshot).toList();
}

/// 应用根组件（异步初始化 AppState，避免构造函数阻塞 UI 导致卡启动页）
class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppState>(
      future: _initAppState(),
      builder: (ctx, snapshot) {
        if (snapshot.connectionState == ConnectionState.done &&
            snapshot.hasData) {
          return ChangeNotifierProvider<AppState>.value(
            value: snapshot.data!,
            child: Consumer<AppState>(
              builder: (ctx, app, _) {
                app.settings.language;
                return MaterialApp(
                  title: Constants.appName,
                  theme: AppTheme.light,
                  debugShowCheckedModeBanner: false,
                  home: const HomeScreen(),
                );
              },
            ),
          );
        }
        return MaterialApp(
          title: Constants.appName,
          theme: AppTheme.light,
          debugShowCheckedModeBanner: false,
          home: const _StartupLoadingPage(),
        );
      },
    );
  }

  /// 异步初始化 AppState（在主线程外完成 IO 操作，不阻塞 UI）
  static Future<AppState> _initAppState() async {
    return AppState();
  }
}

/// 启动加载页（AppState 初始化完成前显示）
class _StartupLoadingPage extends StatelessWidget {
  const _StartupLoadingPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                gradient: AppTheme.brandGradient,
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(Icons.bolt, color: Colors.white, size: 36),
            ),
            const SizedBox(height: 20),
            const Text(Constants.appName,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 24),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
