import 'dart:math';

/// 自适应速率限制（每个 Key 的动态 RPM/TPM 上限估计）
///
/// 支持：
/// - 手动配置 + 响应头解析 + 自适应学习（AIMD）
/// - 多时段估计（将一天划分为 6 个 4 小时段）
/// - 时间衰减恢复
/// - 持久化序列化
class AdaptiveRateLimit {
  final String keyId;

  /// 当前时段估计的 RPM 上限
  int currentRpmLimit;

  /// 当前时段估计的 TPM 上限
  int currentTpmLimit;

  /// 置信度 0-1（响应头信息可信度高）
  double confidence;

  /// 最后更新时间
  DateTime lastUpdate;

  /// 连续成功次数
  int consecutiveSuccess;

  /// 连续失败次数
  int consecutiveFailure;

  /// 历史观察到的最高 RPM（用于恢复上限）
  int maxObservedRpm;

  /// 历史观察到的最高 TPM
  int maxObservedTpm;

  /// 当前所在的时段索引（0-5）
  int currentPeriod;

  AdaptiveRateLimit({
    required this.keyId,
    this.currentRpmLimit = 100,
    this.currentTpmLimit = 50000,
    this.confidence = 0.3,
    DateTime? lastUpdate,
    this.consecutiveSuccess = 0,
    this.consecutiveFailure = 0,
    this.maxObservedRpm = 100,
    this.maxObservedTpm = 50000,
    this.currentPeriod = 0,
  }) : lastUpdate = lastUpdate ?? DateTime.now();

  /// 从 JSON 反序列化
  factory AdaptiveRateLimit.fromJson(Map<String, dynamic> json) {
    return AdaptiveRateLimit(
      keyId: json['key_id'] as String,
      currentRpmLimit: json['current_rpm'] as int? ?? 100,
      currentTpmLimit: json['current_tpm'] as int? ?? 50000,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.3,
      lastUpdate: json['last_update'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['last_update'] as int)
          : DateTime.now(),
      consecutiveSuccess: json['consecutive_success'] as int? ?? 0,
      consecutiveFailure: json['consecutive_failure'] as int? ?? 0,
      maxObservedRpm: json['max_observed_rpm'] as int? ?? 100,
      maxObservedTpm: json['max_observed_tpm'] as int? ?? 50000,
      currentPeriod: json['current_period'] as int? ?? 0,
    );
  }

  /// 序列化为 JSON
  Map<String, dynamic> toJson() => {
        'key_id': keyId,
        'current_rpm': currentRpmLimit,
        'current_tpm': currentTpmLimit,
        'confidence': confidence,
        'last_update': lastUpdate.millisecondsSinceEpoch,
        'consecutive_success': consecutiveSuccess,
        'consecutive_failure': consecutiveFailure,
        'max_observed_rpm': maxObservedRpm,
        'max_observed_tpm': maxObservedTpm,
        'current_period': currentPeriod,
      };

  /// 获取当前时段索引（0-5），基于当前小时
  static int currentPeriodIndex([DateTime? now]) {
    final hour = (now ?? DateTime.now()).hour;
    return hour ~/ 4; // 0-3→0, 4-7→1, 8-11→2, 12-15→3, 16-19→4, 20-23→5
  }

  /// 更新当前时段
  void updatePeriod() {
    currentPeriod = currentPeriodIndex();
  }

  // ————————————————————————————————————————————
  // AIMD 调整
  // ————————————————————————————————————————————

  /// 成功请求后调用：加性增（Additive Increase）
  ///
  /// [estimateTokens] 本次请求的预估或实际 token 消耗
  void onSuccess(int estimateTokens) {
    consecutiveSuccess++;
    consecutiveFailure = 0;
    lastUpdate = DateTime.now();

    // 连续成功 >= 10 次且置信度不足，缓慢增加限制
    if (consecutiveSuccess >= 10 && confidence < 0.8) {
      currentRpmLimit = min(currentRpmLimit + 1, (maxObservedRpm * 1.2).round());
      currentTpmLimit = min(
        currentTpmLimit + (estimateTokens * 0.1).round(),
        (maxObservedTpm * 1.2).round(),
      );
      consecutiveSuccess = 0; // 重置，避免频繁调整
    }

    // 更新观察到的最大值
    if (currentRpmLimit > maxObservedRpm) maxObservedRpm = currentRpmLimit;
    if (currentTpmLimit > maxObservedTpm) maxObservedTpm = currentTpmLimit;

    // 小幅提升置信度
    confidence = (confidence + 0.01).clamp(0, 1.0);
  }

  /// 收到 429 后调用：乘性减（Multiplicative Decrease）
  ///
  /// [responseHeaders] 上游响应头，可能包含 X-RateLimit-Limit-*
  void onRateLimited(Map<String, String>? responseHeaders) {
    consecutiveFailure++;
    consecutiveSuccess = 0;
    lastUpdate = DateTime.now();

    // 优先从响应头获取精确限制
    final headerRpm = _parseHeaderInt(responseHeaders, 'X-RateLimit-Limit-Requests');
    final headerTpm = _parseHeaderInt(responseHeaders, 'X-RateLimit-Limit-Tokens');

    if (headerRpm != null && headerTpm != null) {
      // 响应头可信，直接采用
      currentRpmLimit = headerRpm;
      currentTpmLimit = headerTpm;
      confidence = 0.9;
    } else {
      // 乘性减：快速收缩到 70%
      const minRpm = 1;
      const minTpm = 100;
      currentRpmLimit = max((currentRpmLimit * 0.7).floor(), minRpm);
      currentTpmLimit = max((currentTpmLimit * 0.7).floor(), minTpm);
      confidence = max(confidence * 0.8, 0.1);
    }
  }

  /// 时间衰减：每小时恢复放宽
  ///
  /// 每小时执行一次，缓慢增加限制向 maxObserved 恢复
  void timeDecay() {
    if (confidence > 0.8) {
      // 高置信度时衰减幅度小
      currentRpmLimit = min(
        (currentRpmLimit * 1.02).round(),
        maxObservedRpm,
      );
      currentTpmLimit = min(
        (currentTpmLimit * 1.02).round(),
        maxObservedTpm,
      );
    } else {
      currentRpmLimit = min(
        (currentRpmLimit * 1.05).round(),
        maxObservedRpm,
      );
      currentTpmLimit = min(
        (currentTpmLimit * 1.05).round(),
        maxObservedTpm,
      );
    }
    lastUpdate = DateTime.now();
  }

  /// 是否需要进行时间衰减（距离上次更新超过 1 小时）
  bool get needsTimeDecay =>
      DateTime.now().difference(lastUpdate).inHours >= 1;

  /// 根据置信度返回余量系数（低置信度时预留更多余量）
  double get marginFactor {
    if (confidence < 0.5) return 0.8;
    if (confidence < 0.7) return 0.9;
    return 1.0;
  }

  /// 从响应头解析整数值，不存在或解析失败返回 null
  int? _parseHeaderInt(Map<String, String>? headers, String name) {
    if (headers == null) return null;
    final val = headers[name];
    if (val == null) return null;
    return int.tryParse(val);
  }
}

/// 多时段自适应速率限制管理器
///
/// 为每个 Key 维护 6 个时段的 AdaptiveRateLimit
class AdaptiveRateLimitManager {
  /// keyId -> 时段索引(0-5) -> AdaptiveRateLimit
  final Map<String, Map<int, AdaptiveRateLimit>> _limits = {};

  AdaptiveRateLimitManager();

  /// 获取指定 Key 当前时段的限制
  AdaptiveRateLimit get(String keyId) {
    final period = AdaptiveRateLimit.currentPeriodIndex();
    final byKey = _limits.putIfAbsent(keyId, () => {});
    return byKey.putIfAbsent(period, () => AdaptiveRateLimit(keyId: keyId));
  }

  /// 获取指定 Key 和时段的限制
  AdaptiveRateLimit getForPeriod(String keyId, int period) {
    final byKey = _limits.putIfAbsent(keyId, () => {});
    return byKey.putIfAbsent(period, () => AdaptiveRateLimit(keyId: keyId));
  }

  /// 成功请求后更新
  void onSuccess(String keyId, int estimateTokens) {
    final limit = get(keyId);
    limit.updatePeriod();
    limit.onSuccess(estimateTokens);

    // 相邻时段平滑：将当前时段的更新部分混合到相邻时段
    final period = limit.currentPeriod;
    final prev = (period - 1 + 6) % 6;
    final next = (period + 1) % 6;
    for (final adj in [prev, next]) {
      final adjLimit = getForPeriod(keyId, adj);
      // 混合：取当前时段和相邻时段的平均值
      adjLimit.currentRpmLimit =
          ((adjLimit.currentRpmLimit + limit.currentRpmLimit) / 2).round();
      adjLimit.currentTpmLimit =
          ((adjLimit.currentTpmLimit + limit.currentTpmLimit) / 2).round();
    }
  }

  /// 429 后更新
  void onRateLimited(String keyId, Map<String, String>? responseHeaders) {
    final limit = get(keyId);
    limit.updatePeriod();
    limit.onRateLimited(responseHeaders);
  }

  /// 执行时间衰减（对所有 Key 的所有时段）
  void applyTimeDecay() {
    for (final byKey in _limits.values) {
      for (final limit in byKey.values) {
        if (limit.needsTimeDecay) {
          limit.timeDecay();
        }
      }
    }
  }

  /// 序列化所有数据
  Map<String, dynamic> toJson() {
    final data = <String, dynamic>{};
    for (final entry in _limits.entries) {
      final periods = <String, dynamic>{};
      for (final p in entry.value.entries) {
        periods[p.key.toString()] = p.value.toJson();
      }
      data[entry.key] = periods;
    }
    return data;
  }

  /// 反序列化
  factory AdaptiveRateLimitManager.fromJson(Map<String, dynamic> json) {
    final manager = AdaptiveRateLimitManager();
    for (final keyEntry in json.entries) {
      final byKey = <int, AdaptiveRateLimit>{};
      for (final pEntry in (keyEntry.value as Map<String, dynamic>).entries) {
        final period = int.tryParse(pEntry.key) ?? 0;
        byKey[period] = AdaptiveRateLimit.fromJson(
          pEntry.value as Map<String, dynamic>,
        );
      }
      manager._limits[keyEntry.key] = byKey;
    }
    return manager;
  }

  /// 清空所有数据
  void clear() => _limits.clear();
}