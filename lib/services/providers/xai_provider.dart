import 'package:relaygo/models/api_key.dart';
import 'package:relaygo/models/provider_config.dart';
import 'package:relaygo/services/providers/base_provider.dart';

/// xAI (Grok) 适配器
///
/// 覆盖 Grok 系列聊天补全、模型列表等 `/v1/*` 接口。
/// 上游端点：`https://api.x.ai/v1`
/// 鉴权方式：`Authorization: Bearer <access_token>`
///
/// 支持两种凭据：
/// 1. 普通 API Key（xAI 控制台生成的 `xai-` 前缀密钥）
/// 2. OAuth 认证文件导入的 access_token（由 [OAuthTokenRefresher] 自动刷新）
class XaiProvider extends BaseHttpProvider {
  @override
  ProviderType get type => ProviderType.xai;

  @override
  String resolveBaseUrl(ApiKey key) =>
      ProviderConfig.resolveBaseUrl(ProviderType.xai, key.baseUrl);

  @override
  String get testPath => '/v1/models';

  @override
  Map<String, String> authHeaders(String decryptedKey) {
    return {'authorization': 'Bearer $decryptedKey'};
  }
}
