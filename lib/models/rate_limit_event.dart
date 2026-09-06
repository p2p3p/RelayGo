/// 限流切换 Key 事件记录
///
/// 记录每次因限流（RPM / TPM / 429 / 额度耗尽）而切换 Key 的事件，
/// 包含时间、Key、原因与更新后的限制值，供首页实时监控与事件查看页展示。
class RateLimitEvent {
  final String id;
  final int timestamp; // 毫秒
  final String keyId;
  final String keyName; // Key 名称（用户可见）
  final String providerId; // 提供商定义 ID（用于解析显示名称）
  final String providerType; // ProviderType.name（openai/custom...）

  /// 触发原因：rpm / tpm / 429 / quota
  final String reason;

  final String model; // 关联模型（可能为空）

  /// 更新前限制值（0 = 无此维度数据）
  final int oldRpmLimit;
  final int oldTpmLimit;

  /// 更新后限制值（自适应学习后生效的值）
  final int newRpmLimit;
  final int newTpmLimit;

  final String detail; // 补充说明

  RateLimitEvent({
    required this.id,
    required this.timestamp,
    required this.keyId,
    required this.keyName,
    required this.providerId,
    required this.providerType,
    required this.reason,
    this.model = '',
    this.oldRpmLimit = 0,
    this.oldTpmLimit = 0,
    this.newRpmLimit = 0,
    this.newTpmLimit = 0,
    this.detail = '',
  });

  factory RateLimitEvent.fromJson(Map<String, dynamic> json) {
    return RateLimitEvent(
      id: json['id'] as String,
      timestamp: json['timestamp'] as int? ?? 0,
      keyId: json['key_id'] as String? ?? '',
      keyName: json['key_name'] as String? ?? '',
      providerId: json['provider_id'] as String? ?? '',
      providerType: json['provider_type'] as String? ?? '',
      reason: json['reason'] as String? ?? '',
      model: json['model'] as String? ?? '',
      oldRpmLimit: json['old_rpm'] as int? ?? 0,
      oldTpmLimit: json['old_tpm'] as int? ?? 0,
      newRpmLimit: json['new_rpm'] as int? ?? 0,
      newTpmLimit: json['new_tpm'] as int? ?? 0,
      detail: json['detail'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp,
        'key_id': keyId,
        'key_name': keyName,
        'provider_id': providerId,
        'provider_type': providerType,
        'reason': reason,
        'model': model,
        'old_rpm': oldRpmLimit,
        'old_tpm': oldTpmLimit,
        'new_rpm': newRpmLimit,
        'new_tpm': newTpmLimit,
        'detail': detail,
      };

  bool get isRpm => reason == 'rpm';
  bool get isTpm => reason == 'tpm';
  bool get isQuota => reason == 'quota';
  bool get isStatus429 => reason == '429';

  DateTime get dateTime => DateTime.fromMillisecondsSinceEpoch(timestamp);
}