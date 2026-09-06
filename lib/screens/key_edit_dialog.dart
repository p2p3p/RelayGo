import 'package:flutter/material.dart';
import 'package:relaygo/app.dart';
import 'package:relaygo/config/theme.dart';
import 'package:relaygo/models/api_key.dart';
import 'package:relaygo/models/provider_definition.dart';
import 'package:relaygo/utils/encryption.dart';
import 'package:relaygo/utils/validators.dart';
import 'package:relaygo/l10n/app_strings.dart';

/// 添加 / 编辑 API Key 对话框
///
/// [existing] 为 null 表示新增，否则为编辑（key 留空则保持原密文）。
/// 支持备注字段（最大 200 字符）。提供商可从内置 + 自定义列表中选择。
class KeyEditDialog extends StatefulWidget {
  final AppState app;
  final ApiKey? existing;

  const KeyEditDialog({Key? key, required this.app, this.existing})
      : super(key: key);

  @override
  State<KeyEditDialog> createState() => _KeyEditDialogState();
}

class _KeyEditDialogState extends State<KeyEditDialog> {
  final _formKey = GlobalKey<FormState>();
  late String _provider;
  late String _providerId;
  final _nameCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _apiPathCtrl = TextEditingController(text: '/chat/completions');
  final _groupCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  final _prioCtrl = TextEditingController(text: '100');
  final _weightCtrl = TextEditingController(text: '1');
  final _rpmCtrl = TextEditingController(text: '60');
  final _quotaCtrl = TextEditingController(text: '0');
  bool _showAdvanced = false;
  final _headerControllers = <_HeaderPair>[];

  @override
  void initState() {
    super.initState();
    final k = widget.existing;
    if (k != null) {
      _provider = k.provider;
      _providerId = k.providerId.isEmpty ? k.provider : k.providerId;
      _nameCtrl.text = k.name;
      _urlCtrl.text = k.baseUrl ?? '';
      _apiPathCtrl.text =
          (k.metadata['api_path'] as String?) ?? '/chat/completions';
      _groupCtrl.text = k.group;
      _noteCtrl.text = k.note;
      _prioCtrl.text = '${k.priority}';
      _weightCtrl.text = '${k.weight}';
      _rpmCtrl.text = '${k.maxRequestsPerMinute}';
      _quotaCtrl.text = '${k.dailyQuota}';
      // 加载已有自定义请求头
      k.customHeaders.forEach((key, value) {
        _headerControllers.add(_HeaderPair()..keyCtrl.text = key..valueCtrl.text = value);
      });
    } else {
      // 新增：默认选中第一个提供商
      final providers = widget.app.providers;
      if (providers.isNotEmpty) {
        final first = providers.first;
        _providerId = first.id;
        _provider = _mapToProviderType(first);
        _urlCtrl.text = first.apiUrl;
        _apiPathCtrl.text = first.apiPath;
      } else {
        _provider = 'custom';
        _providerId = 'custom';
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _keyCtrl.dispose();
    _urlCtrl.dispose();
    _apiPathCtrl.dispose();
    _groupCtrl.dispose();
    _noteCtrl.dispose();
    _prioCtrl.dispose();
    _weightCtrl.dispose();
    _rpmCtrl.dispose();
    _quotaCtrl.dispose();
    for (final h in _headerControllers) {
      h.dispose();
    }
    super.dispose();
  }

  /// 选择提供商后自动带入 API URL 与 API 路径
  ///
  /// 切换提供商时总是更新 URL（内置预设带官方地址；azure/custom 预设为空，
  /// 会清空让用户手动填写），避免沿用上一个提供商的地址导致连接错误。
  void _onProviderSelected(ProviderDefinition? p) {
    if (p == null) return;
    setState(() {
      _providerId = p.id;
      _provider = _mapToProviderType(p);
      _urlCtrl.text = p.apiUrl;
      _apiPathCtrl.text = p.apiPath;
    });
  }

  /// 将提供商定义映射为路由用的 ProviderType.name
  String _mapToProviderType(ProviderDefinition p) {
    switch (p.id) {
      case 'openai':
        return 'openai';
      case 'anthropic':
        return 'anthropic';
      case 'google':
        return 'google';
      case 'azure':
        return 'azure';
      case 'xai':
        return 'xai';
      default:
        return 'custom';
    }
  }

  /// 构建该提供商的 metadata（api_path / model_list_path / auth 等）
  Map<String, dynamic> _buildMetadata(ProviderDefinition? p) {
    final meta = <String, dynamic>{};
    if (p != null) {
      meta['api_path'] = p.apiPath;
      meta['model_list_path'] = p.modelListPath;
      if (p.authType == 'api-key') {
        meta['auth_header'] = 'api-key';
        meta['auth_prefix'] = '';
      } else {
        meta['auth_header'] = 'authorization';
        meta['auth_prefix'] = 'Bearer ';
      }
    }
    return meta;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final navigator = Navigator.of(context);
    final note = _noteCtrl.text.trim();
    final provider = widget.app.getProvider(_providerId);
    final metadata = _buildMetadata(provider);
    final apiPath = _apiPathCtrl.text.trim().isEmpty
        ? '/chat/completions'
        : _apiPathCtrl.text.trim();
    metadata['api_path'] = apiPath;
    // 收集自定义请求头（忽略空键）
    final customHeaders = <String, String>{
      for (final h in _headerControllers)
        if (h.headerKey.isNotEmpty) h.headerKey: h.headerValue,
    };

    if (widget.existing == null) {
      // 新增：支持一行一个 Key 批量添加
      final keys = _keyCtrl.text
          .split(RegExp(r'[\r\n]+'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      final baseName = _nameCtrl.text.trim();
      final providerName = provider?.name ?? _provider;
      for (var i = 0; i < keys.length; i++) {
        final keyName = keys.length > 1
            ? (baseName.isEmpty
                ? '$providerName-${i + 1}'
                : '$baseName-${i + 1}')
            : (baseName.isEmpty ? providerName : baseName);
        await widget.app.addKey(
          provider: _provider,
          providerId: _providerId,
          plainKey: keys[i],
          name: keyName,
          baseUrl: _urlCtrl.text.trim().isEmpty ? null : _urlCtrl.text.trim(),
          note: note,
          priority: int.tryParse(_prioCtrl.text) ?? 100,
          weight: int.tryParse(_weightCtrl.text) ?? 1,
          maxRpm: int.tryParse(_rpmCtrl.text) ?? 60,
          dailyQuota: int.tryParse(_quotaCtrl.text) ?? 0,
          group: _groupCtrl.text.trim(),
          metadata: metadata,
          customHeaders: customHeaders,
        );
      }
      navigator.pop(true);
    } else {
      final k = widget.existing!;
      final encrypted = _keyCtrl.text.trim().isEmpty
          ? k.encryptedKey
          : EncryptionUtil.encrypt(_keyCtrl.text.trim());
      await widget.app.updateKey(k.copyWith(
        provider: _provider,
        providerId: _providerId,
        encryptedKey: encrypted,
        name: _nameCtrl.text.trim(),
        note: note,
        baseUrl: _urlCtrl.text.trim().isEmpty ? null : _urlCtrl.text.trim(),
        group: _groupCtrl.text.trim(),
        priority: int.tryParse(_prioCtrl.text) ?? k.priority,
        weight: int.tryParse(_weightCtrl.text) ?? k.weight,
        maxRequestsPerMinute: int.tryParse(_rpmCtrl.text) ?? k.maxRequestsPerMinute,
        dailyQuota: int.tryParse(_quotaCtrl.text) ?? k.dailyQuota,
        metadata: metadata,
        customHeaders: customHeaders,
      ));
      navigator.pop(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    final providers = widget.app.providers;
    // 当前选中的提供商（找不到时回退到第一个）
    ProviderDefinition? current = providers
        .where((p) => p.id == _providerId)
        .cast<ProviderDefinition?>()
        .firstWhere((p) => true, orElse: () => null);
    if (current == null && providers.isNotEmpty) {
      current = providers.first;
    }

    return AlertDialog(
      title: Text(isEdit ? L10n.tr('编辑 API Key') : L10n.tr('添加 API Key')),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // —————— 基础信息 ——————
              DropdownButtonFormField<String>(
                initialValue: current?.id,
                items: providers.map((p) {
                  return DropdownMenuItem(
                    value: p.id,
                    child: Text(
                      p.builtIn
                          ? p.name
                          : L10n.fmt('{name} (自定义)', {'name': p.name}),
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }).toList(),
                onChanged: (v) {
                  if (v == null) return;
                  _onProviderSelected(widget.app.getProvider(v));
                },
                decoration: InputDecoration(labelText: L10n.tr('提供商')),
              ),
              TextFormField(
                controller: _nameCtrl,
                decoration: InputDecoration(
                  labelText: L10n.tr('名称'),
                  hintText: L10n.tr('留空则自动生成'),
                ),
              ),
              TextFormField(
                controller: _noteCtrl,
                maxLength: 200,
                decoration: InputDecoration(
                  labelText: L10n.tr('备注说明(可选)'),
                  hintText: L10n.tr('选填，例如：账号A-免费额度'),
                  counterText: '',
                ),
              ),
              TextFormField(
                controller: _keyCtrl,
                decoration: InputDecoration(
                  labelText: L10n.tr('API Key'),
                  hintText: isEdit
                      ? L10n.tr('留空则保持不变')
                      : L10n.tr('支持一行一个 Key 批量添加'),
                ),
                obscureText: false,
                maxLines: 3,
                minLines: 1,
                validator: isEdit
                    ? null
                    : (v) {
                        final lines = (v ?? '')
                            .split(RegExp(r'[\r\n]+'))
                            .map((s) => s.trim())
                            .where((s) => s.isNotEmpty)
                            .toList();
                        return lines.isEmpty ? L10n.tr('请填写至少一个 API Key') : null;
                      },
              ),
              // API URL：仅自定义提供商时显示
              if (_provider == 'custom' || current?.builtIn == false)
                TextFormField(
                  controller: _urlCtrl,
                  decoration: InputDecoration(
                    labelText: L10n.tr('API URL'),
                    hintText: L10n.tr('例如 https://api.example.com/v1'),
                  ),
                  validator: (v) {
                    if (v!.trim().isEmpty) {
                      return L10n.tr('请填写 API URL');
                    }
                    if (!v.trim().startsWith('http://') &&
                        !v.trim().startsWith('https://')) {
                      return L10n.tr('URL 必须以 http:// 或 https:// 开头');
                    }
                    return null;
                  },
                ),
              // —————— 高级设置（折叠）——————
              const SizedBox(height: 8),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _showAdvanced = !_showAdvanced),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(
                        _showAdvanced
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 20,
                        color: AppTheme.text2,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        L10n.tr('高级设置'),
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.text2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_showAdvanced) ...[
                const SizedBox(height: 4),
                TextFormField(
                  controller: _groupCtrl,
                  decoration: InputDecoration(
                    labelText: L10n.tr('分组(可选)'),
                    hintText: L10n.tr('用于规则按组路由'),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _prioCtrl,
                        keyboardType: TextInputType.number,
                        decoration:
                            InputDecoration(labelText: L10n.tr('优先级')),
                        validator: (v) =>
                            Validators.validatePositiveInt(v, '优先级'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        controller: _weightCtrl,
                        keyboardType: TextInputType.number,
                        decoration:
                            InputDecoration(labelText: L10n.tr('权重')),
                        validator: (v) =>
                            Validators.validatePositiveInt(v, '权重'),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _rpmCtrl,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                            labelText: L10n.tr('每分钟上限(RPM)')),
                        validator: (v) =>
                            Validators.validatePositiveInt(v, 'RPM'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        controller: _quotaCtrl,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: L10n.tr('每日额度(token)'),
                          hintText: L10n.tr('0 = 不限制'),
                        ),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) {
                            return L10n.tr('每日额度不能为空');
                          }
                          final n = int.tryParse(v.trim());
                          if (n == null || n < 0) {
                            return L10n.tr('额度必须为非负整数');
                          }
                          return null;
                        },
                      ),
                    ),
                  ],
                ),
                TextFormField(
                  controller: _apiPathCtrl,
                  decoration: InputDecoration(
                    labelText: L10n.tr('API 路径'),
                    hintText: L10n.tr('默认 /chat/completions'),
                  ),
                ),
                const SizedBox(height: 8),
                _buildCustomHeadersSection(),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(L10n.tr('取消')),
        ),
        ElevatedButton(
          onPressed: _submit,
          child: Text(isEdit ? L10n.tr('保存') : L10n.tr('添加')),
        ),
      ],
    );
  }

  /// 自定义请求头编辑区（需求 2.2.8）
  Widget _buildCustomHeadersSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Icon(Icons.code, size: 16, color: Colors.grey),
            const SizedBox(width: 6),
            const Text('自定义请求头（可选）',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Colors.grey)),
            const Spacer(),
            TextButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text('添加'),
              onPressed: () => setState(() => _headerControllers.add(_HeaderPair())),
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
            ),
          ],
        ),
        if (_headerControllers.isEmpty)
          const Padding(
            padding: EdgeInsets.only(left: 22, bottom: 4),
            child: Text('用于伪装 X-Client-ID / User-Agent 等请求头',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
          )
        else
          ...List.generate(_headerControllers.length, (i) {
            final h = _headerControllers[i];
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: h.keyCtrl,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'X-Client-ID',
                        border: OutlineInputBorder(),
                        labelStyle: TextStyle(fontSize: 12),
                      ),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: h.valueCtrl,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: '值',
                        border: OutlineInputBorder(),
                      ),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline, size: 18, color: Colors.red),
                    onPressed: () {
                      setState(() {
                        h.dispose();
                        _headerControllers.removeAt(i);
                      });
                    },
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }
}

/// 自定义请求头键值对（控制器封装）
class _HeaderPair {
  final TextEditingController keyCtrl = TextEditingController();
  final TextEditingController valueCtrl = TextEditingController();

  String get headerKey => keyCtrl.text.trim();
  String get headerValue => valueCtrl.text.trim();

  void dispose() {
    keyCtrl.dispose();
    valueCtrl.dispose();
  }
}