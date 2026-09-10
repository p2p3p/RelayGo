import 'package:relaygo/config/constants.dart';

/// 用户设置
class UserSettings {
  int port; // 代理监听端口
  String host; // 监听地址
  String loadBalanceStrategy; // 负载均衡策略
  String language; // 'zh' / 'en'
  bool appLockEnabled; // 应用锁（生物识别 / PIN）
  String? appLockPin;

  // —— Phase 2：日志管理（需求 2.2.1）——
  int logRetentionDays; // 自动清理超过 N 天的日志
  int maxLogEntries; // 日志条数上限

  // —— Phase 2：额度监控与告警（需求 2.2.2）——
  double quotaWarnThreshold; // 0-1，额度使用率达到该值告警
  double errorRateThreshold; // 0-1，今日错误率超过该值告警
  bool alertsEnabled;

  // —— Phase 2：规则引擎与限流 ——
  bool rulesEnabled;
  bool rateLimitEnabled; // 按 key 的 max_requests_per_minute 限流
  int upstreamTimeoutSeconds;
  int maxRetryKeys; // [已废弃] 单请求最多切换的 key 数——现按候选池大小动态决定（pool.length * 2），此字段仅保留用于向后兼容

  // —— Phase 3：响应缓存（需求 2.2.4）——
  bool cacheEnabled;
  int cacheTtlSeconds;
  int cacheMaxEntries;

  // —— Phase 3：高级限流（需求 2.2.6）——
  int ipRateLimitPerMinute; // 单 IP 每分钟请求上限，0 = 不限
  int globalRpmLimit; // 全局每分钟请求上限，0 = 不限
  int tokenRateLimitPerMinute; // 单 key 每分钟 token 上限，0 = 不限
  double burstMultiplier; // 令牌桶突发倍数
  bool adaptiveTpmEnabled; // 自适应 TPM 挡板 + 429 等待重试（默认开启）
  bool adaptiveQpsEnabled; // 自适应 QPS/RPM 挡板（学习上游请求数限流，默认开启）

  // —— 可自定义的冷却 / 限流时间 ——
  int keyCooldownSeconds; // Key 连续失败达阈值后的冷却时长（秒）
  int quotaCooldownSeconds; // Key 被标记「额度耗尽」后的冷却时长（秒）
  int rateLimitWindowSeconds; // 高级限流的滑动统计窗口（秒）
  int tpmWaitBudgetSeconds; // 撞可恢复 TPM 限流时同 key 等待预算（秒）
  int qpsWaitBudgetSeconds; // 撞可恢复 QPS/RPM 限流时同 key 等待预算（秒）

  // —— 在线更新（启动时自动检查，配置项不暴露在设置页）——
  String updateFeedUrl;
  String updateChannel; // stable / beta
  bool autoCheckUpdate; // 启动时自动检查
  String updateGithubRepo; // GitHub 发布仓库 owner/repo（方案一）；空串则回退 updateFeedUrl 清单

  // —— 模型列表同步（需求 REQ-003）——
  bool autoSyncModelsOnStartup; // 启动时自动同步模型列表
  int modelSyncIntervalHours; // 定时同步间隔（小时），0 = 不定时
  bool autoDisableRemovedModels; // 同步后自动禁用已下线的模型

  // —— 虚拟模型层（能力分层）——
  // 默认关闭，回归纯转发：/v1/models 返回真实模型、请求模型名原样透传。
  // 开启后才会把模型按能力档位收敛成 10 个虚拟模型并把请求改写为真实模型。

  // —— 保活（后台持续运行）——
  bool keepAliveEnabled; // 前台服务保活开关（默认开启）
  bool autoStartOnBoot; // 开机自启（默认关闭，需用户开启）
  bool ignoreBatteryOptimization; // 请求加入电池优化白名单（默认关闭）

  // —— 自定义请求头（需求 2.2.8）——
  /// 全局默认请求头，应用到所有提供商（key 级 customHeaders 优先覆盖）
  Map<String, String> globalHeaders;

  UserSettings({
    this.port = Constants.defaultPort,
    this.host = Constants.defaultHost,
    this.loadBalanceStrategy = 'round_robin',
    this.language = 'zh',
    this.appLockEnabled = false,
    this.appLockPin,
    this.logRetentionDays = Constants.defaultLogRetentionDays,
    this.maxLogEntries = Constants.defaultMaxLogEntries,
    this.quotaWarnThreshold = Constants.defaultQuotaWarnThreshold,
    this.errorRateThreshold = 0.5,
    this.alertsEnabled = true,
    this.rulesEnabled = true,
    this.rateLimitEnabled = true,
    this.upstreamTimeoutSeconds = Constants.upstreamTimeoutSeconds,
    this.maxRetryKeys = Constants.maxRetryKeys,
    this.cacheEnabled = true,
    this.cacheTtlSeconds = Constants.defaultCacheTtlSeconds,
    this.cacheMaxEntries = Constants.defaultCacheMaxEntries,
    this.ipRateLimitPerMinute = Constants.defaultIpRateLimitPerMinute,
    this.globalRpmLimit = Constants.defaultGlobalRpmLimit,
    this.tokenRateLimitPerMinute = Constants.defaultTokenRateLimitPerMinute,
    this.burstMultiplier = Constants.defaultBurstMultiplier,
    this.adaptiveTpmEnabled = Constants.defaultAdaptiveTpmEnabled,
    this.adaptiveQpsEnabled = Constants.defaultAdaptiveQpsEnabled,
    this.keyCooldownSeconds = Constants.defaultKeyCooldownSeconds,
    this.quotaCooldownSeconds = Constants.defaultQuotaCooldownSeconds,
    this.rateLimitWindowSeconds = Constants.defaultRateLimitWindowSeconds,
    this.tpmWaitBudgetSeconds = Constants.defaultTpmWaitBudgetSeconds,
    this.qpsWaitBudgetSeconds = Constants.defaultQpsWaitBudgetSeconds,
    this.updateFeedUrl = Constants.defaultUpdateFeedUrl,
    this.updateChannel = Constants.defaultUpdateChannel,
    this.autoCheckUpdate = true,
    this.updateGithubRepo = Constants.defaultUpdateGithubRepo,
    this.autoSyncModelsOnStartup = true,
    this.modelSyncIntervalHours = 24,
    this.autoDisableRemovedModels = true,
    this.keepAliveEnabled = true,
    this.autoStartOnBoot = false,
    this.ignoreBatteryOptimization = false,
    this.globalHeaders = const {},
  });

  factory UserSettings.fromJson(Map<String, dynamic> json) {
    return UserSettings(
      port: json['port'] as int? ?? Constants.defaultPort,
      host: json['host'] as String? ?? Constants.defaultHost,
      loadBalanceStrategy:
          json['load_balance_strategy'] as String? ?? 'round_robin',
      language: json['language'] as String? ?? 'zh',
      appLockEnabled: json['app_lock_enabled'] as bool? ?? false,
      appLockPin: json['app_lock_pin'] as String?,
      logRetentionDays:
          json['log_retention_days'] as int? ?? Constants.defaultLogRetentionDays,
      maxLogEntries:
          json['max_log_entries'] as int? ?? Constants.defaultMaxLogEntries,
      quotaWarnThreshold: (json['quota_warn_threshold'] as num?)?.toDouble() ??
          Constants.defaultQuotaWarnThreshold,
      errorRateThreshold:
          (json['error_rate_threshold'] as num?)?.toDouble() ?? 0.5,
      alertsEnabled: json['alerts_enabled'] as bool? ?? true,
      rulesEnabled: json['rules_enabled'] as bool? ?? true,
      rateLimitEnabled: json['rate_limit_enabled'] as bool? ?? true,
      upstreamTimeoutSeconds: json['upstream_timeout_seconds'] as int? ??
          Constants.upstreamTimeoutSeconds,
      maxRetryKeys: json['max_retry_keys'] as int? ?? Constants.maxRetryKeys,
      cacheEnabled: json['cache_enabled'] as bool? ?? false,
      cacheTtlSeconds: json['cache_ttl_seconds'] as int? ??
          Constants.defaultCacheTtlSeconds,
      cacheMaxEntries: json['cache_max_entries'] as int? ??
          Constants.defaultCacheMaxEntries,
      ipRateLimitPerMinute: json['ip_rate_limit_per_minute'] as int? ??
          Constants.defaultIpRateLimitPerMinute,
      globalRpmLimit:
          json['global_rpm_limit'] as int? ?? Constants.defaultGlobalRpmLimit,
      tokenRateLimitPerMinute: json['token_rate_limit_per_minute'] as int? ??
          Constants.defaultTokenRateLimitPerMinute,
      burstMultiplier: (json['burst_multiplier'] as num?)?.toDouble() ??
          Constants.defaultBurstMultiplier,
      adaptiveTpmEnabled: json['adaptive_tpm_enabled'] as bool? ??
          Constants.defaultAdaptiveTpmEnabled,
      adaptiveQpsEnabled: json['adaptive_qps_enabled'] as bool? ??
          Constants.defaultAdaptiveQpsEnabled,
      keyCooldownSeconds: json['key_cooldown_seconds'] as int? ??
          Constants.defaultKeyCooldownSeconds,
      quotaCooldownSeconds: json['quota_cooldown_seconds'] as int? ??
          Constants.defaultQuotaCooldownSeconds,
      rateLimitWindowSeconds: json['rate_limit_window_seconds'] as int? ??
          Constants.defaultRateLimitWindowSeconds,
      tpmWaitBudgetSeconds: json['tpm_wait_budget_seconds'] as int? ??
          Constants.defaultTpmWaitBudgetSeconds,
      qpsWaitBudgetSeconds: json['qps_wait_budget_seconds'] as int? ??
          Constants.defaultQpsWaitBudgetSeconds,
      updateFeedUrl:
          json['update_feed_url'] as String? ?? Constants.defaultUpdateFeedUrl,
      updateChannel: json['update_channel'] as String? ??
          Constants.defaultUpdateChannel,
      autoCheckUpdate: json['auto_check_update'] as bool? ?? true,
      updateGithubRepo:
          json['update_github_repo'] as String? ?? Constants.defaultUpdateGithubRepo,
      autoSyncModelsOnStartup:
          json['auto_sync_models_on_startup'] as bool? ?? true,
      modelSyncIntervalHours:
          json['model_sync_interval_hours'] as int? ?? 24,
      autoDisableRemovedModels:
          json['auto_disable_removed_models'] as bool? ?? true,
      keepAliveEnabled: json['keep_alive_enabled'] as bool? ?? true,
      autoStartOnBoot: json['auto_start_on_boot'] as bool? ?? false,
      ignoreBatteryOptimization:
          json['ignore_battery_optimization'] as bool? ?? false,
      globalHeaders: json['global_headers'] == null
          ? {}
          : Map<String, String>.from(json['global_headers'] as Map),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'port': port,
      'host': host,
      'load_balance_strategy': loadBalanceStrategy,
      'language': language,
      'app_lock_enabled': appLockEnabled,
      'app_lock_pin': appLockPin,
      'log_retention_days': logRetentionDays,
      'max_log_entries': maxLogEntries,
      'quota_warn_threshold': quotaWarnThreshold,
      'error_rate_threshold': errorRateThreshold,
      'alerts_enabled': alertsEnabled,
      'rules_enabled': rulesEnabled,
      'rate_limit_enabled': rateLimitEnabled,
      'upstream_timeout_seconds': upstreamTimeoutSeconds,
      'max_retry_keys': maxRetryKeys,
      'cache_enabled': cacheEnabled,
      'cache_ttl_seconds': cacheTtlSeconds,
      'cache_max_entries': cacheMaxEntries,
      'ip_rate_limit_per_minute': ipRateLimitPerMinute,
      'global_rpm_limit': globalRpmLimit,
      'token_rate_limit_per_minute': tokenRateLimitPerMinute,
      'burst_multiplier': burstMultiplier,
      'adaptive_tpm_enabled': adaptiveTpmEnabled,
      'adaptive_qps_enabled': adaptiveQpsEnabled,
      'key_cooldown_seconds': keyCooldownSeconds,
      'quota_cooldown_seconds': quotaCooldownSeconds,
      'rate_limit_window_seconds': rateLimitWindowSeconds,
      'tpm_wait_budget_seconds': tpmWaitBudgetSeconds,
      'qps_wait_budget_seconds': qpsWaitBudgetSeconds,
      'update_feed_url': updateFeedUrl,
      'update_channel': updateChannel,
      'auto_check_update': autoCheckUpdate,
      'update_github_repo': updateGithubRepo,
      'auto_sync_models_on_startup': autoSyncModelsOnStartup,
      'model_sync_interval_hours': modelSyncIntervalHours,
      'auto_disable_removed_models': autoDisableRemovedModels,
      'keep_alive_enabled': keepAliveEnabled,
      'auto_start_on_boot': autoStartOnBoot,
      'ignore_battery_optimization': ignoreBatteryOptimization,
      'global_headers': globalHeaders,
    };
  }

  UserSettings copyWith({
    int? port,
    String? host,
    String? loadBalanceStrategy,
    String? language,
    bool? appLockEnabled,
    String? appLockPin,
    int? logRetentionDays,
    int? maxLogEntries,
    double? quotaWarnThreshold,
    double? errorRateThreshold,
    bool? alertsEnabled,
    bool? rulesEnabled,
    bool? rateLimitEnabled,
    int? upstreamTimeoutSeconds,
    int? maxRetryKeys,
    bool? cacheEnabled,
    int? cacheTtlSeconds,
    int? cacheMaxEntries,
    int? ipRateLimitPerMinute,
    int? globalRpmLimit,
    int? tokenRateLimitPerMinute,
    double? burstMultiplier,
    bool? adaptiveTpmEnabled,
    bool? adaptiveQpsEnabled,
    int? keyCooldownSeconds,
    int? quotaCooldownSeconds,
    int? rateLimitWindowSeconds,
    int? tpmWaitBudgetSeconds,
    int? qpsWaitBudgetSeconds,
    String? updateFeedUrl,
    String? updateChannel,
    bool? autoCheckUpdate,
    String? updateGithubRepo,
    bool? autoSyncModelsOnStartup,
    int? modelSyncIntervalHours,
    bool? autoDisableRemovedModels,
    bool? keepAliveEnabled,
    bool? autoStartOnBoot,
    bool? ignoreBatteryOptimization,
  }) {
    return UserSettings(
      port: port ?? this.port,
      host: host ?? this.host,
      loadBalanceStrategy: loadBalanceStrategy ?? this.loadBalanceStrategy,
      language: language ?? this.language,
      appLockEnabled: appLockEnabled ?? this.appLockEnabled,
      appLockPin: appLockPin ?? this.appLockPin,
      logRetentionDays: logRetentionDays ?? this.logRetentionDays,
      maxLogEntries: maxLogEntries ?? this.maxLogEntries,
      quotaWarnThreshold: quotaWarnThreshold ?? this.quotaWarnThreshold,
      errorRateThreshold: errorRateThreshold ?? this.errorRateThreshold,
      alertsEnabled: alertsEnabled ?? this.alertsEnabled,
      rulesEnabled: rulesEnabled ?? this.rulesEnabled,
      rateLimitEnabled: rateLimitEnabled ?? this.rateLimitEnabled,
      upstreamTimeoutSeconds:
          upstreamTimeoutSeconds ?? this.upstreamTimeoutSeconds,
      maxRetryKeys: maxRetryKeys ?? this.maxRetryKeys,
      cacheEnabled: cacheEnabled ?? this.cacheEnabled,
      cacheTtlSeconds: cacheTtlSeconds ?? this.cacheTtlSeconds,
      cacheMaxEntries: cacheMaxEntries ?? this.cacheMaxEntries,
      ipRateLimitPerMinute: ipRateLimitPerMinute ?? this.ipRateLimitPerMinute,
      globalRpmLimit: globalRpmLimit ?? this.globalRpmLimit,
      tokenRateLimitPerMinute:
          tokenRateLimitPerMinute ?? this.tokenRateLimitPerMinute,
      burstMultiplier: burstMultiplier ?? this.burstMultiplier,
      adaptiveTpmEnabled: adaptiveTpmEnabled ?? this.adaptiveTpmEnabled,
      adaptiveQpsEnabled: adaptiveQpsEnabled ?? this.adaptiveQpsEnabled,
      keyCooldownSeconds: keyCooldownSeconds ?? this.keyCooldownSeconds,
      quotaCooldownSeconds: quotaCooldownSeconds ?? this.quotaCooldownSeconds,
      rateLimitWindowSeconds:
          rateLimitWindowSeconds ?? this.rateLimitWindowSeconds,
      tpmWaitBudgetSeconds: tpmWaitBudgetSeconds ?? this.tpmWaitBudgetSeconds,
      qpsWaitBudgetSeconds: qpsWaitBudgetSeconds ?? this.qpsWaitBudgetSeconds,
      updateFeedUrl: updateFeedUrl ?? this.updateFeedUrl,
      updateChannel: updateChannel ?? this.updateChannel,
      autoCheckUpdate: autoCheckUpdate ?? this.autoCheckUpdate,
      updateGithubRepo: updateGithubRepo ?? this.updateGithubRepo,
      autoSyncModelsOnStartup:
          autoSyncModelsOnStartup ?? this.autoSyncModelsOnStartup,
      modelSyncIntervalHours:
          modelSyncIntervalHours ?? this.modelSyncIntervalHours,
      autoDisableRemovedModels:
          autoDisableRemovedModels ?? this.autoDisableRemovedModels,
      keepAliveEnabled: keepAliveEnabled ?? this.keepAliveEnabled,
      autoStartOnBoot: autoStartOnBoot ?? this.autoStartOnBoot,
      ignoreBatteryOptimization:
          ignoreBatteryOptimization ?? this.ignoreBatteryOptimization,
    );
  }
}
