import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:relaygo/models/api_key.dart';
import 'package:relaygo/services/key_manager.dart';
import 'package:relaygo/utils/encryption.dart';

/// OAuth Token 自动刷新服务
///
/// 在转发请求前检查 OAuth 类型 key 的 token 是否即将过期，
/// 若是则使用 refresh_token 向 token_endpoint 发起刷新请求，
/// 获取新的 access_token 并更新 key 的加密存储与 oauth_metadata。
class OAuthTokenRefresher {
  final KeyManager keyManager;

  /// 刷新锁：同一 key 同时只有一个刷新请求
  final Map<String, Future<bool>> _pending = {};

  OAuthTokenRefresher(this.keyManager);

  /// 检查并刷新 OAuth key 的 token（如需要）。
  ///
  /// 返回 true 表示 key 可用（token 有效或刷新成功）；
  /// 返回 false 表示刷新失败或无法刷新，调用方应跳过此 key。
  Future<bool> ensureFreshToken(ApiKey key) async {
    if (!key.isOAuth) return true; // 非 OAuth key 无需刷新
    if (!key.oauthTokenNeedsRefresh) return true; // token 仍有效

    debugPrint('[OAuthRefresh] key=${key.name} token needs refresh, starting...');

    // 防止同一 key 并发刷新
    final pending = _pending[key.id];
    if (pending != null) return pending;

    final future = _doRefresh(key);
    _pending[key.id] = future;
    try {
      return await future;
    } finally {
      _pending.remove(key.id);
    }
  }

  /// 实际执行 token 刷新
  Future<bool> _doRefresh(ApiKey key) async {
    final refreshToken = key.oauthRefreshToken;
    final tokenEndpoint = key.oauthTokenEndpoint;

    debugPrint('[OAuthRefresh] key=${key.name} '
        'refreshToken=${refreshToken != null ? "${refreshToken.substring(0, refreshToken.length > 10 ? 10 : refreshToken.length)}..." : "null"} '
        'tokenEndpoint=${tokenEndpoint ?? "null"}');

    if (refreshToken == null || refreshToken.isEmpty) {
      debugPrint('[OAuthRefresh] FAIL: refresh_token is null or empty');
      return false;
    }
    if (tokenEndpoint == null || tokenEndpoint.isEmpty) {
      debugPrint('[OAuthRefresh] FAIL: token_endpoint is null or empty');
      return false;
    }

    try {
      final httpClient = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..idleTimeout = const Duration(seconds: 10);

      final uri = Uri.parse(tokenEndpoint);
      debugPrint('[OAuthRefresh] POST $tokenEndpoint');
      final request = await httpClient.openUrl('POST', uri);
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
      );

      // 标准 OAuth 2.0 refresh_token grant
      // 参考 CLIProxyAPI 的 refreshTokensSingleFlight：
      // xAI OAuth 要求同时传 client_id，否则返回 400 invalid_request。
      final body = <String, String>{
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      };
      // 优先从 oauth_metadata 读取 client_id；若缺失则使用 xAI 公共 client_id
      final clientId = key.oauthMetadata['client_id'] as String? ??
          'b1a00492-073a-47ea-816f-4c329264a828';
      if (clientId.isNotEmpty) {
        body['client_id'] = clientId;
      }
      final bodyStr = body.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
      request.contentLength = bodyStr.length;
      request.add(utf8.encode(bodyStr));

      final response = await request.close().timeout(const Duration(seconds: 20));
      final respBody = await _drainResponse(response);
      httpClient.close(force: true);

      debugPrint('[OAuthRefresh] response status=${response.statusCode}, body=${respBody.length > 500 ? respBody.substring(0, 500) : respBody}');

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('[OAuthRefresh] FAIL: HTTP ${response.statusCode} - $respBody');
        return false;
      }

      // 解析刷新响应
      final json = jsonDecode(respBody) as Map<String, dynamic>;
      final newAccessToken = json['access_token'] as String?;
      if (newAccessToken == null || newAccessToken.isEmpty) {
        debugPrint('[OAuthRefresh] FAIL: access_token missing in response. Keys: ${json.keys.toList()}');
        return false;
      }

      // 新的 refresh_token（某些 OAuth 服务器会返回新的 refresh_token，
      // 不返回则沿用旧的）
      final newRefreshToken = json['refresh_token'] as String? ?? refreshToken;
      final expiresIn = json['expires_in'] as int?;
      final tokenType = json['token_type'] as String? ?? 'Bearer';

      // 计算新的过期时间
      final now = DateTime.now();
      final expiry = expiresIn != null
          ? now.add(Duration(seconds: expiresIn))
          : now.add(const Duration(hours: 6)); // 默认 6 小时

      // 更新 key
      final newEncryptedKey = EncryptionUtil.encrypt(newAccessToken);
      final newRefreshEncrypted = EncryptionUtil.encrypt(newRefreshToken);

      final updatedOauthMetadata = Map<String, dynamic>.from(key.oauthMetadata);
      updatedOauthMetadata['refresh_token'] = newRefreshEncrypted;
      updatedOauthMetadata['expired'] = expiry.toUtc().toIso8601String();
      updatedOauthMetadata['expires_in'] = expiresIn ?? key.oauthMetadata['expires_in'];
      updatedOauthMetadata['last_refresh'] = now.toUtc().toIso8601String();
      updatedOauthMetadata['token_type'] = tokenType;

      key.encryptedKey = newEncryptedKey;
      key.oauthMetadata = updatedOauthMetadata;
      await keyManager.updateKey(key);

      debugPrint('[OAuthRefresh] SUCCESS: key=${key.name} token refreshed, expires at $expiry');
      return true;
    } catch (e) {
      debugPrint('[OAuthRefresh] EXCEPTION: $e');
      return false;
    }
  }

  /// 读取完整响应体
  Future<String> _drainResponse(HttpClientResponse resp) async {
    final bytes = await resp.fold<List<int>>(<int>[], (prev, el) => prev..addAll(el));
    return utf8.decode(bytes, allowMalformed: true);
  }
}
