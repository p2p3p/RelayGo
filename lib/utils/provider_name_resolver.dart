import 'package:relaygo/app.dart';
import 'package:relaygo/models/provider_config.dart';
import 'package:relaygo/models/rate_limit_event.dart';

/// 提供商名称解析工具
///
/// 统一根据 providerType + providerId 返回用户可读的提供商名称。
/// 已解决「多个自定义提供商都显示为『自定义』」的问题。
class ProviderNameResolver {
  /// 根据 [providerType]（ProviderType.name，如 openai/custom）和
  /// [providerId]（如 sensetime/deepseek）解析显示名称。
  ///
  /// 优先级：
  /// 1. 从 [ProviderRepository] 查找 providerId 匹配的自定义提供商定义→取 name；
  /// 2. 从 [ProviderTypeX.fromString] 标准名称映射→取 displayName；
  /// 3. 回退到 providerId 自身。
  static String resolve(
    String providerType,
    String providerId, {
    required AppState app,
  }) {
    // 优先查自定义提供商定义
    if (providerId.isNotEmpty) {
      final def = app.getProvider(providerId);
      if (def != null) return def.name;
    }
    // 查标准映射
    try {
      final pt = ProviderTypeX.fromString(providerType);
      return pt.displayName;
    } catch (_) {}
    // 回退
    return providerId.isNotEmpty ? providerId : providerType;
  }

  /// 从限流事件解析提供商显示名
  static String resolveFromEvent(RateLimitEvent event, AppState app) {
    return resolve(event.providerType, event.providerId, app: app);
  }

  /// 便捷版：使用 providerType 和 providerId 的常见组合。
  /// 如 providerType='custom', providerId='sensetime' → 'SenseTime'
  /// 如 providerType='openai', providerId='openai' → 'OpenAI'
  static String fromKey(
    String providerType,
    String providerId,
    AppState app,
  ) {
    // 对于 custom 类型的，providerId 是用户填写时传入的名称
    if (providerType == 'custom' && providerId.isNotEmpty &&
        providerId != 'custom') {
      final def = app.getProvider(providerId);
      if (def != null) return def.name;
      // 如果 getProvider 找不到（可能用户添加 key 时填了名称而非已定义提供商）
      // 直接使用 providerId（这就是添加 Key 时用户选择的 providerId/Name）
      return providerId;
    }
    // 非 custom 提供商
    try {
      final pt = ProviderTypeX.fromString(providerType);
      return pt.displayName;
    } catch (_) {
      return providerId.isNotEmpty ? providerId : providerType;
    }
  }
}