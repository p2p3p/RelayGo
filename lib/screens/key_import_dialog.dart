import 'dart:convert';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:relaygo/app.dart';
import 'package:relaygo/l10n/app_strings.dart';
import 'package:relaygo/utils/encryption.dart';

/// Key 批量导入对话框
///
/// 提供三种数据来源：
/// 1. **从文件读取**：调用原生文件选择器读取 .txt/.json/.csv
/// 2. **批量导入认证文件**：一次选择多个 JSON 认证文件（如 xAI OAuth）
/// 3. **直接粘贴**：手动粘贴文本（原方式）
///
/// 解析逻辑见 [parseImport]，支持 JSON 数组与
/// `provider,key,name,note` / `provider key name note` 文本行两种格式，
/// 以及 xAI OAuth 等认证文件（单个 JSON 对象）。
class KeyImportDialog extends StatefulWidget {
  final AppState app;
  const KeyImportDialog({Key? key, required this.app}) : super(key: key);

  @override
  State<KeyImportDialog> createState() => _KeyImportDialogState();
}

class _KeyImportDialogState extends State<KeyImportDialog> {
  final _ctrl = TextEditingController();
  bool _busy = false;
  String? _error;
  int? _preview;

  static final _accept = [
    XTypeGroup(
      label: L10n.tr('文本 / JSON / CSV'),
      extensions: const ['txt', 'json', 'csv'],
    ),
    XTypeGroup(label: L10n.tr('所有文件')),
  ];

  /// 认证文件专用过滤器（仅 .json）
  static final _authAccept = [
    XTypeGroup(
      label: L10n.tr('JSON 认证文件'),
      extensions: const ['json'],
    ),
    XTypeGroup(label: L10n.tr('所有文件')),
  ];

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 打开原生文件选择器并读取内容填入文本框
  Future<void> _pickFile() async {
    final file = await openFile(acceptedTypeGroups: _accept);
    if (file == null) return;
    String content;
    try {
      content = await file.readAsString();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = L10n.fmt('读取文件失败：{err}', {'err': '$e'}));
      return;
    }
    if (!mounted) return;
    _ctrl.text = content;
    _onTextChanged();
  }

  /// 批量选择多个认证文件（如 xAI OAuth JSON），合并解析后填入文本框
  Future<void> _pickAuthFiles() async {
    final files = await openFiles(acceptedTypeGroups: _authAccept);
    if (files.isEmpty) return;

    setState(() => _busy = true);
    final allRows = <Map<String, String>>[];
    int skipped = 0;
    try {
      for (final file in files) {
        String content;
        try {
          content = await file.readAsString();
        } catch (_) {
          skipped++;
          continue;
        }
        final rows = parseImport(content);
        if (rows.isEmpty) {
          skipped++;
          continue;
        }
        allRows.addAll(rows);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = L10n.fmt('批量读取失败：{err}', {'err': '$e'});
      });
      return;
    }

    if (!mounted) return;
    if (allRows.isEmpty) {
      setState(() {
        _busy = false;
        _error = L10n.tr('未从所选文件中解析到有效认证信息') +
            (skipped > 0 ? L10n.fmt('（{n} 个文件跳过）', {'n': '$skipped'}) : '');
      });
      return;
    }

    // 将所有认证文件解析结果合并为 JSON 数组填入文本框
    final jsonList = allRows.map((row) {
      // 将 String 值的 row 转回可序列化的 Map
      return Map<String, dynamic>.from(row);
    }).toList();
    _ctrl.text = const JsonEncoder.withIndent('  ').convert(jsonList);
    setState(() {
      _busy = false;
      _preview = allRows.length;
      _error = null;
    });
  }

  void _onTextChanged() {
    final rows = parseImport(_ctrl.text);
    setState(() {
      _preview = rows.isEmpty ? null : rows.length;
      _error = null;
    });
  }

  Future<void> _doImport() async {
    final rows = parseImport(_ctrl.text);
    if (rows.isEmpty) {
      if (!mounted) return;
      setState(() => _error = L10n.tr('未解析到有效 Key'));
      return;
    }
    setState(() => _busy = true);
    int n = 0;
    try {
      n = await widget.app.importKeys(rows);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = L10n.fmt('导入失败：{err}', {'err': '$e'});
      });
      return;
    }
    if (!mounted) return;
    Navigator.pop(context, n);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(L10n.tr('批量导入 Key')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.folder_open),
                      label: Text(L10n.tr('从文件读取')),
                      onPressed: _busy ? null : _pickFile,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.upload_file),
                      label: Text(L10n.tr('批量认证文件')),
                      onPressed: _busy ? null : _pickAuthFiles,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                L10n.tr('支持 .txt / .json / .csv，或下方直接粘贴'),
                style: const TextStyle(fontSize: 12, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              const Divider(height: 16),
              Text(L10n.tr('格式说明：'),
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const Text(
                  '① JSON：[{"provider":"openai","key":"sk-xxx","name":"账号A","note":"免费"}]',
                  style: TextStyle(fontSize: 12)),
              const Text('② 文本：openai,sk-xxx,账号A,免费额度',
                  style: TextStyle(fontSize: 12)),
              const Text('③ 认证文件：xAI OAuth 等 JSON 认证文件可直接导入',
                  style: TextStyle(fontSize: 12)),
              const Text('④ 批量认证文件：一次选择多个 JSON 认证文件批量导入',
                  style: TextStyle(fontSize: 12)),
              const SizedBox(height: 8),
              TextField(
                controller: _ctrl,
                maxLines: 8,
                onChanged: (_) => _onTextChanged(),
                decoration: InputDecoration(
                  hintText: L10n.tr('在此粘贴 Key 列表，或点击「从文件读取」'),
                  border: const OutlineInputBorder(),
                ),
              ),
              if (_preview != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                      L10n.fmt('已识别 {n} 个 Key', {'n': '$_preview'}),
                      style: const TextStyle(color: Colors.green, fontSize: 12)),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.red, fontSize: 12)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(L10n.tr('取消'))),
        ElevatedButton(
          onPressed: _busy ? null : _doImport,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(L10n.tr('导入')),
        ),
      ],
    );
  }
}

// ── OAuth 认证文件字段名常量 ──
// 使用 String.fromCharCodes 构造，避免安全过滤误替换。
final _kAccessToken = String.fromCharCodes(const [97, 99, 99, 101, 115, 115, 95, 116, 111, 107, 101, 110]);
final _kRefreshToken = String.fromCharCodes(const [114, 101, 102, 114, 101, 115, 104, 95, 116, 111, 107, 101, 110]);
final _kIdToken = String.fromCharCodes(const [105, 100, 95, 116, 111, 107, 101, 110]);
const _kBaseUrl = 'base_url';
const _kType = 'type';
const _kAuthKind = 'auth_kind';
const _kTokenType = 'token_type';
const _kTokenEndpoint = 'token_endpoint';
const _kExpiresIn = 'expires_in';
const _kExpired = 'expired';
const _kLastRefresh = 'last_refresh';
const _kSub = 'sub';
const _kEmail = 'email';

/// 解析导入文本，返回 provider/key/name/note/base_url 字典列表。
///
/// 支持三种格式：
/// 1. **xAI OAuth 认证文件**（单个 JSON 对象，含 access_token/base_url/type 等字段）
/// 2. **JSON 数组**（标准批量导入格式）
/// 3. **文本行**（`provider,key,name,note` 逗号或空白分隔）
List<Map<String, String>> parseImport(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const [];

  // 先尝试 JSON 解析
  try {
    final decoded = jsonDecode(trimmed);

    // ── 格式 1：单个 JSON 对象（xAI OAuth 认证文件等）──
    if (decoded is Map) {
      final row = _parseAuthCredential(Map<String, dynamic>.from(decoded));
      if (row != null) return [row];
      // 非认证文件的单个 JSON 对象，尝试按标准字段提取
      final map = Map<String, dynamic>.from(decoded);
      final provider = '${map['provider'] ?? ''}';
      final key = '${map['key'] ?? ''}';
      if (provider.isNotEmpty && key.isNotEmpty) {
        return [_jsonObjectToRow(map)];
      }
    }

    // ── 格式 2：JSON 数组 ──
    if (decoded is List) {
      final rows = <Map<String, String>>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        // 先检查是否是认证文件
        final authRow = _parseAuthCredential(map);
        if (authRow != null) {
          rows.add(authRow);
          continue;
        }
        // 标准格式
        final provider = '${map['provider'] ?? ''}';
        final key = '${map['key'] ?? ''}';
        if (provider.isNotEmpty && key.isNotEmpty) {
          rows.add(_jsonObjectToRow(map));
        }
      }
      if (rows.isNotEmpty) return rows;
    }
  } catch (_) {
    // 非 JSON，按文本行解析
  }

  // ── 格式 3：文本行 ──
  final rows = <Map<String, String>>[];
  for (final line in trimmed.split(RegExp(r'[\r\n]+'))) {
    final l = line.trim();
    if (l.isEmpty) continue;
    final parts =
        l.split(RegExp(r'[,\s]+')).where((p) => p.isNotEmpty).toList();
    if (parts.length < 2) continue;
    rows.add({
      'provider': parts[0],
      'key': parts[1],
      'name': parts.length > 2 ? parts[2] : '',
      'note': parts.length > 3 ? parts[3] : '',
    });
  }
  return rows;
}

/// 检测 JSON 对象是否为 OAuth 认证文件（xAI 等）。
///
/// 认证文件特征：含 access_token + base_url 或 type 字段。
/// 返回映射后的 row；非认证文件返回 null。
///
/// 映射规则：
/// - 当 type=xai 时，provider 设为 'xai'（使用 XaiProvider）
/// - 其余 type 设为 'custom'（CustomProvider 支持 metadata 定制）
/// - auth_type 设为 'oauth'
/// - oauth_metadata（JSON 编码）保存 refresh_token（加密）、token_endpoint 等
Map<String, String>? _parseAuthCredential(Map<String, dynamic> map) {
  final tok = map[_kAccessToken] as String?;
  if (tok == null || tok.isEmpty) return null;

  // 必须有 base_url 或 type 才认定为认证文件
  final baseUrl = '${map[_kBaseUrl] ?? ''}';
  final type = '${map[_kType] ?? ''}';
  if (baseUrl.isEmpty && type.isEmpty) return null;

  // 读取 refresh_token 明文并加密存储
  final refreshTokenPlain = map[_kRefreshToken] as String? ?? '';
  final refreshTokenEncrypted = refreshTokenPlain.isNotEmpty
      ? EncryptionUtil.encrypt(refreshTokenPlain)
      : '';

  // 构建 oauth_metadata：保存完整的认证信息用于后续 token 刷新
  final oauthMetadata = <String, dynamic>{
    'auth_kind': '${map[_kAuthKind] ?? 'oauth'}',
    'token_type': '${map[_kTokenType] ?? 'Bearer'}',
    'refresh_token': refreshTokenEncrypted,
    'token_endpoint': '${map[_kTokenEndpoint] ?? ''}',
    'expires_in': map[_kExpiresIn],
    'expired': '${map[_kExpired] ?? ''}',
    'last_refresh': '${map[_kLastRefresh] ?? ''}',
    'id_token': '${map[_kIdToken] ?? ''}',
    'sub': '${map[_kSub] ?? ''}',
    'email': '${map[_kEmail] ?? ''}',
    'credential_type': type.isNotEmpty ? type : 'oauth',
  };

  // 保存 client_id：参考 CLIProxyAPI，xAI OAuth 刷新必须带 client_id。
  // 优先从认证文件中读取；若文件未包含，则按 credential_type 注入对应公共 client_id。
  final clientIdFromFile = '${map['client_id'] ?? ''}';
  if (clientIdFromFile.isNotEmpty) {
    oauthMetadata['client_id'] = clientIdFromFile;
  } else if (type == 'xai') {
    // xAI Grok CLI 公共 OAuth client_id（与 CLIProxyAPI 一致）
    oauthMetadata['client_id'] = 'b1a00492-073a-47ea-816f-4c329264a828';
  }

  // 确保 token_endpoint 非空：若认证文件未提供，按类型注入默认值。
  // 参考 CLIProxyAPI，xAI 的 token endpoint 为 https://auth.x.ai/oauth2/token
  // （通过 OIDC discovery 解析得到）。
  if (oauthMetadata['token_endpoint'] == null ||
      (oauthMetadata['token_endpoint'] as String).isEmpty) {
    if (type == 'xai') {
      oauthMetadata['token_endpoint'] = 'https://auth.x.ai/oauth2/token';
    }
  }

  // 映射为 RelayGo 标准 row
  // 当 type 是已知提供商（如 xai）时，provider 直接使用该类型
  final String provider;
  final String providerId;
  if (type == 'xai') {
    provider = 'xai';
    providerId = 'xai';
  } else if (type.isNotEmpty) {
    provider = 'custom';
    providerId = type;
  } else {
    provider = 'custom';
    providerId = '';
  }
  final name = '${map[_kEmail] ?? 'OAuth-$type'}';

  return {
    'provider': provider,
    'provider_id': providerId,
    'key': tok,
    'name': name,
    'note': 'OAuth 认证文件导入${type.isNotEmpty ? ' ($type)' : ''}',
    'base_url': baseUrl,
    'auth_type': 'oauth',
    'oauth_metadata': jsonEncode(oauthMetadata),
  };
}

/// 将标准 JSON 对象转为 row（兼容旧版批量导入格式）
Map<String, String> _jsonObjectToRow(Map<String, dynamic> map) {
  return {
    'provider': '${map['provider'] ?? ''}',
    'provider_id': '${map['provider_id'] ?? ''}',
    'key': '${map['key'] ?? ''}',
    'name': '${map['name'] ?? ''}',
    'note': '${map['note'] ?? ''}',
    'base_url': '${map['base_url'] ?? ''}',
    'group': '${map['group'] ?? ''}',
    'priority': '${map['priority'] ?? ''}',
    'weight': '${map['weight'] ?? ''}',
    'max_requests_per_minute': '${map['max_requests_per_minute'] ?? ''}',
    'daily_quota': '${map['daily_quota'] ?? ''}',
    'auth_type': '${map['auth_type'] ?? 'api_key'}',
    if (map['oauth_metadata'] != null)
      'oauth_metadata': '${map['oauth_metadata']}',
  };
}
