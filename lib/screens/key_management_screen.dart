import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:relaygo/app.dart';
import 'package:relaygo/config/theme.dart';
import 'package:relaygo/models/api_key.dart';
import 'package:relaygo/models/provider_config.dart';
import 'package:relaygo/models/key_test.dart';
import 'package:relaygo/widgets/key_card.dart';
import 'package:relaygo/widgets/provider_logo.dart';
import 'package:relaygo/screens/key_edit_dialog.dart';
import 'package:relaygo/screens/batch_test_dialog.dart';
import 'package:relaygo/screens/candidate_pool_screen.dart';
import 'package:relaygo/screens/key_import_dialog.dart';
import 'package:relaygo/screens/key_export_dialog.dart';
import 'package:relaygo/screens/model_management_screen.dart';
import 'package:relaygo/utils/provider_name_resolver.dart';
import 'package:relaygo/l10n/app_strings.dart';

/// API Keys 管理页（对应设计稿 API Keys 管理）
///
/// 顶部搜索 + 筛选；按服务商分组卡片（提供商名 + 数量 + 测试全部）；
/// 每组卡片内为 Key 行（状态圆点 + 掩码 Key + 备注 + 状态徽章）；右下 FAB 添加。
class KeyManagementScreen extends StatefulWidget {
  const KeyManagementScreen({Key? key}) : super(key: key);

  @override
  State<KeyManagementScreen> createState() => _KeyManagementScreenState();
}

class _KeyManagementScreenState extends State<KeyManagementScreen> {
  final Map<String, bool> _testing = {};
  final TextEditingController _searchCtrl = TextEditingController();
  String _filter = '';
  String _query = '';

  /// 提供商分组折叠状态：key=providerId，true=已折叠；缺省/false=展开
  final Map<String, bool> _collapsed = {};

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<ApiKey> _visible(AppState app) {
    var list = app.keys;
    if (_filter.isNotEmpty) {
      list = list.where((k) => k.provider == _filter).toList();
    }
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      list = list.where((k) {
        return k.name.toLowerCase().contains(q) ||
            k.maskedKey.toLowerCase().contains(q) ||
            k.note.toLowerCase().contains(q) ||
            k.provider.toLowerCase().contains(q);
      }).toList();
    }
    return list;
  }

  /// 当前分组中是否存在任一「展开」的分组（用于 AppBar 全部展开/折叠按钮判定）。
  /// 搜索态（_query 非空）下所有分组强制展开，故视为存在展开分组。
  bool _anyExpanded(Iterable<String> providerIds) {
    if (_query.trim().isNotEmpty) return true;
    return providerIds.any((id) => !(_collapsed[id] ?? false));
  }

  @override
  Widget build(BuildContext context) {
    final app = Provider.of<AppState>(context);
    final visible = _visible(app);
    final grouped = <String, List<ApiKey>>{};
    for (final k in visible) {
      grouped
          .putIfAbsent(k.providerId.isEmpty ? k.provider : k.providerId, () => [])
          .add(k);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('API Keys'),
        actions: [
          // 全部展开 / 全部折叠：当前存在任一分组展开则一键折叠，否则一键展开。
          // 搜索态下分组被强制展开，此按钮同样按 effective 展开态判定。
          IconButton(
            icon: Icon(_anyExpanded(grouped.keys)
                ? Icons.unfold_less
                : Icons.unfold_more),
            tooltip: _anyExpanded(grouped.keys)
                ? L10n.tr('全部折叠')
                : L10n.tr('全部展开'),
            onPressed: () => setState(() {
              if (_anyExpanded(grouped.keys)) {
                for (final id in grouped.keys) {
                  _collapsed[id] = true;
                }
              } else {
                _collapsed.clear();
              }
            }),
          ),
          // 候选池（排错诊断高频入口，提升为 AppBar 独立图标）
          IconButton(
            icon: const Icon(Icons.pool_outlined),
            tooltip: L10n.tr('候选 Key 池'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CandidatePoolScreen()),
            ),
          ),
          // 更多操作：导入 / 导出 Key
          PopupMenuButton<String>(
            tooltip: L10n.tr('更多操作'),
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              if (v == 'import') {
                _showImportDialog(context, app);
              } else if (v == 'export') {
                _exportKeys(context, app);
              }
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                  value: 'import', child: Text(L10n.tr('导入 Key'))),
              PopupMenuItem(
                  value: 'export', child: Text(L10n.tr('导出 Key'))),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // 搜索 + 筛选（对应设计稿：搜索框 + tune 筛选按钮）
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search, size: 20),
                      hintText: L10n.tr('搜索 Key...'),
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(() => _query = v.trim()),
                  ),
                ),
                const SizedBox(width: 8),
                // 筛选按钮（对应设计稿 tune）
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    border: Border.all(color: AppTheme.borderStrong),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: PopupMenuButton<String>(
                    tooltip: L10n.tr('筛选服务商'),
                    icon: const Icon(Icons.tune, size: 20),
                    onSelected: (v) => setState(() => _filter = v),
                    itemBuilder: (ctx) => [
                      PopupMenuItem(
                          value: '', child: Text(L10n.tr('全部服务商'))),
                      ...ProviderType.values.map((p) => PopupMenuItem(
                            value: p.name,
                            child: Text(p.displayName),
                          )),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: visible.isEmpty
                ? Center(
                    child: Text(
                      app.keys.isEmpty
                          ? L10n.tr('还没有添加任何 Key\n点击右下角按钮新增')
                          : L10n.tr('没有匹配的 Key'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 88),
                    children: grouped.entries.map((entry) {
                      // 统一提供商名称解析：自定义提供商优先显示其定义名 / providerId，
                      // 内置提供商显示标准 displayName，避免多个自定义都显示"自定义"
                      final displayName = ProviderNameResolver.fromKey(
                        entry.value.isNotEmpty
                            ? entry.value.first.provider
                            : entry.key,
                        entry.key,
                        app,
                      );
                      final keys = entry.value;
                      // 搜索联动：_query 非空时强制展开，避免匹配 Key 被折叠隐藏
                      final collapsed = _query.trim().isNotEmpty
                          ? false
                          : (_collapsed[entry.key] ?? false);
                      return _providerGroup(context, app, entry.key,
                          displayName, keys, collapsed);
                    }).toList(),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.add),
        onPressed: () => _showEditDialog(context, app, null),
      ),
    );
  }

  /// 服务商分组（对应设计稿：组标题 + 单张卡片内含所有 Key 行）
  ///
  /// 标题行整体可点击折叠/展开：折叠时仅保留标题行，隐藏 KeyCard 列表；
  /// [collapsed] 由 build 结合搜索态（_query）与 [_collapsed] 预先算好后传入。
  Widget _providerGroup(BuildContext context, AppState app, String providerId,
      String displayName, List<ApiKey> keys, bool collapsed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题行：Material(Transparency)+InkWell 提供点击水波纹与整行折叠热区；
        // 行内 TextButton 自身会拦截其点击，不会误触发整行折叠。
        Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: () =>
                setState(() => _collapsed[providerId] = !collapsed),
            child: Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: Row(
                children: [
                  // 折叠指示 chevron：展开=expand_more，折叠=chevron_right
                  Icon(
                    collapsed ? Icons.chevron_right : Icons.expand_more,
                    size: 20,
                    color: AppTheme.text2,
                  ),
                  // 提供商小 Logo
                  ProviderLogo(
                      providerId: providerId, providerName: displayName),
                  const SizedBox(width: 8),
                  Text(displayName,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.text)),
                  const SizedBox(width: 8),
                  // 数量（mono-tag）
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.surface2,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      L10n.count(keys.length),
                      style: const TextStyle(
                          fontFamily: AppTheme.monoFontFamily,
                          fontSize: 11.5,
                          color: AppTheme.text2),
                    ),
                  ),
                  // 折叠摘要提示（仅折叠态显示）
                  if (collapsed) ...[
                    const SizedBox(width: 8),
                    Text(
                      L10n.tr('已折叠'),
                      style: const TextStyle(
                          fontFamily: AppTheme.monoFontFamily,
                          fontSize: 11.5,
                          color: AppTheme.text2),
                    ),
                  ],
                  const Spacer(),
                  // 测试全部（text 小按钮）
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      textStyle: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    onPressed: () => _batchTest(app, keys,
                        L10n.fmt('测试 {name}', {'name': displayName})),
                    child: Text(L10n.tr('测试全部')),
                  ),
                  // 全部删除（text 小按钮，红色）
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: AppTheme.danger,
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      textStyle: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    onPressed: () => _confirmDeleteByProvider(
                        context, app, displayName, keys),
                    child: Text(L10n.tr('全部删除')),
                  ),
                ],
              ),
            ),
          ),
        ),
        // 单张卡片（圆角12 · 边框 1px #E0E0E0）；折叠态不渲染 KeyCard 列表
        if (!collapsed)
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              border: Border.all(color: AppTheme.border),
            ),
            child: Column(
              children: List.generate(keys.length, (i) {
                final k = keys[i];
                return Column(
                  children: [
                    if (i > 0)
                      const Divider(
                          height: 1,
                          thickness: 1,
                          indent: 26,
                          color: AppTheme.border),
                    KeyCard(
                      key: ValueKey(k.id),
                      apiKey: k,
                      testing: _testing[k.id] ?? false,
                      onTest: () => _testKey(context, app, k),
                      onEdit: () => _showEditDialog(context, app, k),
                      onDelete: () => _confirmDelete(context, app, k),
                      onToggle: () => _toggleKey(app, k),
                    ),
                  ],
                );
              }),
            ),
          ),
        const SizedBox(height: 12),
      ],
    );
  }

  Future<void> _testKey(
      BuildContext context, AppState app, ApiKey k) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _testing[k.id] = true);
    final outcome = await app.testKey(k);
    setState(() => _testing[k.id] = false);
    if (!mounted) return;
    var msg = L10n.tr('连接完成');
    var color = Colors.grey;
    switch (outcome.status) {
      case KeyTestStatus.valid:
        msg = L10n.fmt('连接成功：{name}', {'name': k.name});
        color = Colors.green;
        break;
      case KeyTestStatus.invalid:
        msg = L10n.fmt('连接失败：{name}（{err}）',
            {'name': k.name, 'err': outcome.error ?? L10n.tr('无效')});
        color = Colors.red;
        break;
      case KeyTestStatus.timeout:
        msg = L10n.fmt('连接超时：{name}', {'name': k.name});
        color = Colors.orange;
        break;
      case KeyTestStatus.error:
        msg = L10n.fmt('连接异常：{name}（{err}）',
            {'name': k.name, 'err': outcome.error ?? L10n.tr('错误')});
        color = Colors.orange;
        break;
    }
    messenger.showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  Future<void> _toggleKey(AppState app, ApiKey k) async {
    // 点击卡片 = 明确的「启用 ↔ 禁用」二态切换。
    // 修复原逻辑 bug：`k.status == active ? inactive : active` 在一个 key 进入
    // error（无效）或 exhausted（用尽）状态后，用户想禁用却被改成 active（启用），
    // 表现为「点了没反应 / 反而变有效」。
    // 新语义：只有当前是 inactive（已禁用）时点击才恢复 active；其余任意状态
    // （active / error / exhausted）点击一律切到 inactive（禁用），即「用一段时间后
    // 也能稳定禁用它，禁用 = 从转发链路完全摘除」。
    final next = k.status.toggledStatus();
    await app.updateKey(k.copyWith(status: next));
    if (next == KeyStatus.inactive) {
      // 需求：禁用 key 时同步删除该 key 拉取的模型
      await app.modelRepository.removeBySourceKey(k.id);
      // 重同步同提供商的其他 active key，恢复应保留的模型
      try {
        await app.modelSync.syncProvider(k.provider, providerId: k.providerId);
      } catch (_) {
        // 网络失败等场景静默处理
      }
    }
  }

  Future<void> _confirmDelete(
      BuildContext context, AppState app, ApiKey k) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.tr('删除 Key')),
        content: Text(
            L10n.fmt('确认删除「{name}」？此操作不可撤销。', {'name': k.name})),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L10n.tr('取消'))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(L10n.tr('删除'))),
        ],
      ),
    );
    if (confirm == true) await app.deleteKey(k.id);
  }

  /// 一键删除某提供商下所有 Key
  Future<void> _confirmDeleteByProvider(BuildContext context, AppState app,
      String displayName, List<ApiKey> keys) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.tr('删除全部 Key')),
        content: Text(L10n.fmt(
            '确认删除「{name}」下全部 {n} 个 Key？此操作不可撤销。',
            {'name': displayName, 'n': '${keys.length}'})),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L10n.tr('取消'))),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L10n.tr('全部删除')),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    // 逐个删除（复用 app.deleteKey 的清理逻辑：删模型 + 重同步）
    for (final k in keys) {
      await app.deleteKey(k.id);
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(this.context);
    messenger.showSnackBar(SnackBar(
      content: Text(L10n.fmt('已删除「{name}」下全部 {n} 个 Key',
          {'name': displayName, 'n': '${keys.length}'})),
    ));
  }

  Future<void> _showEditDialog(BuildContext context, AppState app, ApiKey? existing) async {
    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => KeyEditDialog(app: app, existing: existing),
    );
    // 新增 Key 成功后提醒同步模型列表，并提供直达入口
    if (added == true && mounted) {
      ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(
        content: Text(L10n.tr('Key 已添加，请同步模型列表')),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: L10n.tr('去同步'),
          onPressed: () {
            Navigator.push(this.context,
                MaterialPageRoute(builder: (_) => const ModelManagementScreen()));
          },
        ),
      ));
    }
  }

  void _batchTest(AppState app, List<ApiKey> keys, String title) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => BatchTestDialog(app: app, keys: keys, title: title),
    );
  }

  /// 批量导入：从文件读取或直接粘贴（调用 [KeyImportDialog]）
  Future<void> _showImportDialog(BuildContext context, AppState app) async {
    final n = await showDialog<int>(
      context: context,
      builder: (ctx) => KeyImportDialog(app: app),
    );
    if (n != null && n > 0 && mounted) {
      ScaffoldMessenger.of(this.context).showSnackBar(
        SnackBar(content: Text(L10n.fmt('成功导入 {n} 个 Key', {'n': '$n'}))));
    }
  }

  /// 一键导出全部 Key：展示 JSON 内容 + 一键复制（移动端无系统保存对话框）
  Future<void> _exportKeys(BuildContext context, AppState app) async {
    if (app.keys.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.tr('暂无 Key 可导出'))));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => KeyExportDialog(
        jsonContent: app.exportKeysJson(),
        keyCount: app.keys.length,
      ),
    );
  }
}
