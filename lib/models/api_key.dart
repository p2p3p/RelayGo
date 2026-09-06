import 'package:relaygo/config/constants.dart';
import 'package:relaygo/models/provider_config.dart';
import 'package:relaygo/models/key_test.dart';
import 'package:relaygo/utils/encryption.dart';

/// API Key 状态
enum KeyStatus { active, inactive, exhausted, error }

extension KeyStatusX on KeyStatus {
  String get name => toString().split('.').last;

  static KeyStatus fromString(String value) {
    switch (value) {
      case 'active':
        return KeyStatus.active;
      case 'inactive':
        return KeyStatus.inactive;
      case 'exhausted':
        return KeyStatus.exhausted;
      case 'error':
        return KeyStatus.error;
      default:
        return KeyStatus.active;
    }
  }

  bool get isUsable => this == KeyStatus.active;

  /// 用户点击 Key 卡片时的「启用 ↔ 禁用」切换语义。
  ///
  /// 只有当前已禁用（inactive）才恢复为 active；其余任意状态
  /// （active / error / exhausted）点击一律切到 inactive（禁用）。
  ///
  /// 修复历史 bug：旧逻辑 `active ? inactive : active` 在 key 进入 error /
  /// exhausted（用了一段时间后常见）时，用户想禁用却被切成 active（启用），
  /// 表现为「点了没反应 / 禁用不生效」。新语义保证任意状态下都能一键禁用，
  /// 且禁用后该 key 从转发链路完全摘除（getUsableByProvider 不再返回 inactive）。
  KeyStatus toggledStatus() =>
      this == KeyStatus.inactive ? KeyStatus.active : KeyStatus.inactive;

  String get label {
    switch (this) {
      case KeyStatus.active:
        return '可用';
      case KeyStatus.inactive:
        return '已停用';
      case KeyStatus.exhausted:
        return '额度耗尽';
      case KeyStatus.error:
        return '异常冷却';
    }
  }
}

/// API Key 模型
///
/// 注意：[encryptedKey] 在持久化与内存中均以加密形式保存，明文仅在转发瞬间临时解密。
class ApiKey {
  final String id;
  final String provider; // ProviderType.name
  final String providerId; // 关联的提供商定义 ID（内置或自定义）
  String encryptedKey;
  final String name;
  final String note; // 备注说明（需求 1.2，最大 200 字符）
  final String? baseUrl;
  String group; // 分组（需求 2.1.2 key 分组管理，可用于规则引擎按组路由）
  int priority;
  int weight;
  int maxRequestsPerMinute;
  int dailyQuota; // 每日 token 额度
  int usedToday; // 今日已用 token
  int usedMonth; // 本月已用 token
  int requestsToday; // 今日请求数
  int requestsMonth; // 本月请求数
  int errorsToday; // 今日错误数
  String dayStamp; // yyyyMMdd，用于按日滚动重置
  String monthStamp; // yyyyMM，用于按月滚动重置
  KeyStatus status;
  int? lastTested; // 最后测试时间戳(ms)
  String? testResult; // KeyTestStatus.name：valid/invalid/timeout/error
  String? testError; // 测试失败原因（如 "401 Unauthorized"）
  final int createdAt;
  int lastUsed;
  int failureCount;
  int? cooldownUntil; // 冷却到期时间戳（毫秒）
  Map<String, dynamic> metadata;
  Map<String, String> customHeaders; // 自定义请求头（需求 2.2.8）

  /// 认证类型：'api_key'（默认，向后兼容）或 'oauth'
  ///
  /// OAuth 类型的 key 包含 refresh_token 等信息，可由 [OAuthTokenRefresher]
  /// 自动刷新过期 token，无需用户手动重新导入。
  String authType;

  /// OAuth 专用元数据（仅当 [authType] == 'oauth' 时有效）
  ///
  /// 包含字段：
  /// - `refresh_token`：加密后的 refresh_token
  /// - `token_endpoint`：OAuth token 刷新端点 URL
  /// - `expired`：token 过期时间（ISO 8601 字符串）
  /// - `expires_in`：token 有效期（秒）
  /// - `last_refresh`：上次刷新时间（ISO 8601 字符串）
  /// - `client_id`：OAuth client_id（如需要）
  /// - `token_type`：token 类型，默认 'Bearer'
  /// - `credential_type`：凭据来源类型（如 'xai'）
  Map<String, dynamic> oauthMetadata;

  ApiKey({
    required this.id,
    required this.provider,
    required this.encryptedKey,
    required this.name,
    this.providerId = '',
    this.note = '',
    this.baseUrl,
    this.group = '',
    this.priority = 100,
    this.weight = 1,
    this.maxRequestsPerMinute = Constants.defaultMaxRpm,
    this.dailyQuota = 1000000,
    this.usedToday = 0,
    this.usedMonth = 0,
    this.requestsToday = 0,
    this.requestsMonth = 0,
    this.errorsToday = 0,
    this.dayStamp = '',
    this.monthStamp = '',
    this.status = KeyStatus.active,
    this.lastTested,
    this.testResult,
    this.testError,
    required this.createdAt,
    this.lastUsed = 0,
    this.failureCount = 0,
    this.cooldownUntil,
    this.metadata = const {},
    this.customHeaders = const {},
    this.authType = 'api_key',
    this.oauthMetadata = const {},
  });

  factory ApiKey.fromJson(Map<String, dynamic> json) {
    return ApiKey(
      id: json['id'] as String,
      provider: json['provider'] as String,
      providerId: json['provider_id'] as String? ?? '',
      encryptedKey: json['key'] as String,
      name: json['name'] as String,
      note: json['note'] as String? ?? '',
      baseUrl: json['base_url'] as String?,
      group: json['group'] as String? ?? '',
      priority: json['priority'] as int? ?? 100,
      weight: json['weight'] as int? ?? 1,
      maxRequestsPerMinute:
          json['max_requests_per_minute'] as int? ?? Constants.defaultMaxRpm,
      dailyQuota: json['daily_quota'] as int? ?? 1000000,
      usedToday: json['used_today'] as int? ?? 0,
      usedMonth: json['used_month'] as int? ?? 0,
      requestsToday: json['requests_today'] as int? ?? 0,
      requestsMonth: json['requests_month'] as int? ?? 0,
      errorsToday: json['errors_today'] as int? ?? 0,
      dayStamp: json['day_stamp'] as String? ?? '',
      monthStamp: json['month_stamp'] as String? ?? '',
      status: KeyStatusX.fromString(json['status'] as String? ?? 'active'),
      lastTested: json['last_tested'] as int?,
      testResult: json['test_result'] as String?,
      testError: json['test_error'] as String?,
      createdAt: json['created_at'] as int? ?? 0,
      lastUsed: json['last_used'] as int? ?? 0,
      failureCount: json['failure_count'] as int? ?? 0,
      cooldownUntil: json['cooldown_until'] as int?,
      metadata: json['metadata'] == null
          ? {}
          : Map<String, dynamic>.from(json['metadata'] as Map),
      customHeaders: json['custom_headers'] == null
          ? {}
          : Map<String, String>.from(json['custom_headers'] as Map),
      authType: json['auth_type'] as String? ?? 'api_key',
      oauthMetadata: json['oauth_metadata'] == null
          ? {}
          : Map<String, dynamic>.from(json['oauth_metadata'] as Map),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'provider': provider,
      'provider_id': providerId,
      'key': encryptedKey,
      'name': name,
      'note': note,
      'base_url': baseUrl,
      'group': group,
      'priority': priority,
      'weight': weight,
      'max_requests_per_minute': maxRequestsPerMinute,
      'daily_quota': dailyQuota,
      'used_today': usedToday,
      'used_month': usedMonth,
      'requests_today': requestsToday,
      'requests_month': requestsMonth,
      'errors_today': errorsToday,
      'day_stamp': dayStamp,
      'month_stamp': monthStamp,
      'status': status.name,
      'last_tested': lastTested,
      'test_result': testResult,
      'test_error': testError,
      'created_at': createdAt,
      'last_used': lastUsed,
      'failure_count': failureCount,
      'cooldown_until': cooldownUntil,
      'metadata': metadata,
      'custom_headers': customHeaders,
      'auth_type': authType,
      'oauth_metadata': oauthMetadata,
    };
  }

  ProviderType get providerType => ProviderTypeX.fromString(provider);

  /// 今日额度使用比例（0-1），dailyQuota <= 0 视为不限额
  double get quotaRatio {
    if (dailyQuota <= 0) return 0;
    final r = usedToday / dailyQuota;
    return r > 1 ? 1 : r;
  }

  /// 今日剩余额度（不限额返回 -1）
  int get quotaRemaining =>
      dailyQuota <= 0 ? -1 : (dailyQuota - usedToday).clamp(0, dailyQuota);

  /// 今日错误率（0-1）
  double get errorRate =>
      requestsToday == 0 ? 0 : errorsToday / requestsToday;

  /// 是否处于冷却中
  bool get inCooldown =>
      cooldownUntil != null &&
      cooldownUntil! > DateTime.now().millisecondsSinceEpoch;

  /// 脱敏显示：保留前后各 4 位（作用于密文，日志与 UI 均不含明文）
  String get maskedKey {
    final plain = encryptedKey;
    if (plain.isEmpty) return '****';
    if (plain.length <= 8) return '*' * plain.length;
    return '${plain.substring(0, 4)}••••${plain.substring(plain.length - 4)}';
  }

  /// 上次测试结果状态（未测试返回 null）
  KeyTestStatus? get lastTestStatus => KeyTestStatusX.fromString(testResult);

  /// 是否已测试过
  bool get tested => testResult != null;

  /// 是否为 OAuth 认证类型
  bool get isOAuth => authType == 'oauth';

  /// OAuth token 是否即将过期（提前 5 分钟视为需刷新）
  bool get oauthTokenNeedsRefresh {
    if (!isOAuth) return false;
    final expiredStr = oauthMetadata['expired'] as String?;
    if (expiredStr == null || expiredStr.isEmpty) return true; // 无过期信息，保守刷新
    final expiry = DateTime.tryParse(expiredStr);
    if (expiry == null) return true;
    return expiry.isBefore(DateTime.now().add(const Duration(minutes: 5)));
  }

  /// 获取 OAuth refresh_token（解密后的明文，仅内部使用）
  String? get oauthRefreshToken {
    if (!isOAuth) return null;
    final encrypted = oauthMetadata['refresh_token'] as String?;
    if (encrypted == null || encrypted.isEmpty) return null;
    return EncryptionUtil.decrypt(encrypted);
  }

  /// OAuth token 刷新端点 URL
  String? get oauthTokenEndpoint => oauthMetadata['token_endpoint'] as String?;

  /// 最后测试时间（DateTime，未测试返回 null）
  DateTime? get lastTestedTime => lastTested == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(lastTested!);

  ApiKey copyWith({
    String? provider,
    String? providerId,
    String? name,
    String? note,
    String? encryptedKey,
    String? baseUrl,
    String? group,
    int? priority,
    int? weight,
    int? maxRequestsPerMinute,
    int? dailyQuota,
    KeyStatus? status,
    int? usedToday,
    int? usedMonth,
    int? requestsToday,
    int? requestsMonth,
    int? errorsToday,
    String? dayStamp,
    String? monthStamp,
    int? lastUsed,
    int? failureCount,
    int? cooldownUntil,
    int? lastTested,
    String? testResult,
    String? testError,
    bool clearCooldown = false,
    Map<String, dynamic>? metadata,
    Map<String, String>? customHeaders,
    String? authType,
    Map<String, dynamic>? oauthMetadata,
  }) {
    return ApiKey(
      id: id,
      provider: provider ?? this.provider,
      providerId: providerId ?? this.providerId,
      encryptedKey: encryptedKey ?? this.encryptedKey,
      name: name ?? this.name,
      note: note ?? this.note,
      baseUrl: baseUrl ?? this.baseUrl,
      group: group ?? this.group,
      priority: priority ?? this.priority,
      weight: weight ?? this.weight,
      maxRequestsPerMinute: maxRequestsPerMinute ?? this.maxRequestsPerMinute,
      dailyQuota: dailyQuota ?? this.dailyQuota,
      usedToday: usedToday ?? this.usedToday,
      usedMonth: usedMonth ?? this.usedMonth,
      requestsToday: requestsToday ?? this.requestsToday,
      requestsMonth: requestsMonth ?? this.requestsMonth,
      errorsToday: errorsToday ?? this.errorsToday,
      dayStamp: dayStamp ?? this.dayStamp,
      monthStamp: monthStamp ?? this.monthStamp,
      status: status ?? this.status,
      lastTested: lastTested ?? this.lastTested,
      testResult: testResult ?? this.testResult,
      testError: testError ?? this.testError,
      createdAt: createdAt,
      lastUsed: lastUsed ?? this.lastUsed,
      failureCount: failureCount ?? this.failureCount,
      cooldownUntil: clearCooldown ? null : (cooldownUntil ?? this.cooldownUntil),
      metadata: metadata ?? this.metadata,
      customHeaders: customHeaders ?? this.customHeaders,
      authType: authType ?? this.authType,
      oauthMetadata: oauthMetadata ?? this.oauthMetadata,
    );
  }
}
