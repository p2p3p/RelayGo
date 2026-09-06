import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:relaygo/app.dart';
import 'package:relaygo/config/theme.dart';
import 'package:relaygo/l10n/app_strings.dart';
import 'package:relaygo/models/model_info.dart';
import 'package:relaygo/models/api_key.dart';
import 'package:relaygo/screens/sync_progress_dialog.dart';
import 'package:relaygo/screens/sync_select_dialog.dart';
import 'package:relaygo/utils/provider_name_resolver.dart';

/// 模型管理页（REQ-003）
///
/// 展示从各服务商同步而来的统一模型列表，支持：
/// - 一键「同步全部」与下拉刷新触发同步
/// - 按来源 key 分组、关键字搜索
/// - 单个模型的启用 / 停用开关
/// - 同一 key 下全部模型的一键启用 / 关闭
class ModelManagementScreen extends StatefulWidget {
  const ModelManagementScreen({Key? key}) : super(key: key);

  @override
  State<ModelManagementScreen> createState() => _ModelManagementScreenState();
}

class _ModelManagementScreenState extends State<ModelManagementScreen> {
  String _query = '';
  bool _syncing = false;
  final Set<String> _collapsedGroups = {};

  /// 同步/开关变更后刷新界面（模型数据实时读自仓库）
  void _load() {
    if (mounted) setState(() {});
  }

  int _lastSync(List<ModelInfo> models) {
    var max = 0;
    for (final m in models) {
      if (m.lastSynced > max) max = m.lastSynced;
    }
    return max;
  }

  Future<void> _syncAll() async {
    if (_syncing) return;
    final app = Provider.of<AppState>(context, listen: false);
    // 可同步提供商（拥有 active key）
    final available = app.modelSync.activeProviderIds
        .map((t) => t.id)
        .toSet()
        .toList();
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可用 Key，请先添加或启用 Key')),
      );
      return;
    }
    // 弹出选择对话框：多选 / 一键全部
    final selected = await showDialog<List<String>>(
      context: context,
      builder: (_) => SyncSelectDialog(app: app, available: available),
    );
    if (selected == null || !mounted) return; // 取消

    setState(() => _syncing = true);
    await showDialog<dynamic>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SyncProgressDialog(app: app, providers: selected),
    );
    _load();
    if (mounted) setState(() => _syncing = false);
  }

  Future<void> _toggle(ModelInfo m, bool v) async {
    final app = Provider.of<AppState>(context, listen: false);
    await app.modelRepository.setEnabled(m.id, v);
    _load();
  }

  /// 一键启用 / 关闭同一 key（含旧数据 provider 伪组）下所有模型的启用开关
  Future<void> _toggleAll(List<ModelInfo> models, bool enabled) async {
    final app = Provider.of<AppState>(context, listen: false);
    for (final m in models) {
      await app.modelRepository.setEnabled(m.id, enabled);
    }
    _load();
  }

  /// 清理已下线模型（真正删除，避免越积越多）
  Future<void> _cleanupDeprecated() async {
    final app = Provider.of<AppState>(context, listen: false);
    final counts = app.modelRepository.deprecatedCounts();
    final total = counts.values.fold<int>(0, (s, c) => s + c);
    if (total == 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.tr('没有需要清理的已下线模型'))),
      );
      return;
    }
    final detail = counts.entries
        .map((e) => L10n.fmt('{provider}：{count} 个',
            {'provider': app.getProvider(e.key)?.name ?? e.key, 'count': '${e.value}'}))
        .join('\n');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(L10n.tr('清理已下线模型')),
        content: Text(L10n.fmt('将从模型库中删除以下已下线（deprecated）模型：\n\n{detail}\n\n删除后第三方将无法再获取这些模型。', {'detail': detail})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(L10n.tr('取消')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(L10n.tr('删除')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final removed = await app.modelRepository.removeDeprecated();
    _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L10n.fmt('已清理 {n} 个已下线模型', {'n': '$removed'}))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = Provider.of<AppState>(context);
    final all = app.models;
    final enabledModels = all.where((m) => m.isEnabled).toList();
    final disabledModels = all.where((m) => !m.isEnabled).toList();
    final deprecatedCount = all.where((m) => m.status == 'deprecated').length;
    final last = _lastSync(all);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(L10n.tr('模型管理')),
          actions: [
            IconButton(
              icon: const Icon(Icons.cleaning_services),
              tooltip: L10n.tr('清理已下线模型'),
              onPressed: _cleanupDeprecated,
            ),
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: L10n.tr('同步历史'),
              onPressed: () => _showHistory(app),
            ),
            IconButton(
              icon: _syncing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
              tooltip: L10n.tr('同步所有模型'),
              onPressed: _syncing ? null : _syncAll,
            ),
          ],
          bottom: TabBar(
            tabs: [
              Tab(text: L10n.fmt('已启用（{n}）', {'n': '${enabledModels.length}'})),
              Tab(text: L10n.fmt('已禁用（{n}）', {'n': '${disabledModels.length}'})),
            ],
          ),
        ),
        body: Column(
          children: [
            // 概览 + 搜索
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Column(
                children: [
                  Card(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          const Icon(Icons.model_training, color: AppTheme.brandGreen),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                    L10n.fmt('模型总数：{total}（已启用 {enabled}）',
                                        {'total': '${all.length}', 'enabled': '${enabledModels.length}'}),
                                    style: const TextStyle(fontWeight: FontWeight.bold)),
                                const SizedBox(height: 2),
                                Text(
                                  last > 0
                                      ? L10n.fmt('最后同步：{time}', {
                                          'time': DateFormat('yyyy-MM-dd HH:mm')
                                              .format(DateTime.fromMillisecondsSinceEpoch(last))
                                        })
                                      : L10n.tr('尚未同步，点击右上角同步模型'),
                                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                                ),
                                if (deprecatedCount > 0) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    L10n.fmt('已下线 {count} 个，点击右上角清理',
                                        {'count': '$deprecatedCount'}),
                                    style: const TextStyle(fontSize: 12, color: Colors.red),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search, size: 20),
                      hintText: L10n.tr('搜索模型名称 / 服务商'),
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(() => _query = v.trim()),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // Tab 内容区域
            Expanded(
              child: TabBarView(
                children: [
                  // Tab 1：已启用
                  _buildTabContent(app, enabledModels, keysById: app.keyManager.getAll().fold<Map<String, ApiKey>>({}, (map, k) {
                    map[k.id] = k;
                    return map;
                  })),
                  // Tab 2：已禁用
                  _buildTabContent(app, disabledModels, keysById: app.keyManager.getAll().fold<Map<String, ApiKey>>({}, (map, k) {
                    map[k.id] = k;
                    return map;
                  })),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建单个 Tab 的模型列表内容
  Widget _buildTabContent(AppState app, List<ModelInfo> models, {required Map<String, ApiKey> keysById}) {
    // 按来源 key 分组
    final keyGroups = <String, List<ModelInfo>>{};
    for (final m in models) {
      final gid = m.sourceKeyId.isNotEmpty ? m.sourceKeyId : '__legacy:${m.provider}';
      keyGroups.putIfAbsent(gid, () => []).add(m);
    }

    final q = _query.toLowerCase();
    final hasResults = q.isEmpty || keyGroups.values.any((list) => list.any((m) =>
        m.name.toLowerCase().contains(q) || m.provider.toLowerCase().contains(q) || m.displayName.toLowerCase().contains(q)));

    if (models.isEmpty) {
      return Center(
        child: Text(L10n.tr('还没有模型，点击右上角「同步」从各服务商拉取'),
            style: const TextStyle(color: Colors.grey)),
      );
    }

    if (!hasResults) {
      return Center(
        child: Text(L10n.tr('没有匹配的模型'),
            style: const TextStyle(color: Colors.grey)),
      );
    }

    return RefreshIndicator(
      onRefresh: _syncAll,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: keyGroups.entries.map((entry) {
          final gid = entry.key;
          final full = entry.value;
          // 搜索过滤
          final list = q.isEmpty
              ? full
              : full
                  .where((m) =>
                      m.name.toLowerCase().contains(q) ||
                      m.provider.toLowerCase().contains(q) ||
                      m.displayName.toLowerCase().contains(q))
                  .toList();
          if (list.isEmpty) return const SizedBox.shrink();

          final first = full.first;
          final key = keysById[gid];
          final providerName = ProviderNameResolver.fromKey(
            first.provider,
            first.provider,
            app,
          );
          final title = key?.name ?? providerName;
          final subtitle = key != null ? providerName : L10n.tr('未关联 key');
          final isCollapsed = _collapsedGroups.contains(gid);
          final allEnabled = full.every((m) => m.isEnabled);
          final noneEnabled = full.every((m) => !m.isEnabled);
          final triState = allEnabled ? true : (noneEnabled ? false : null);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 点击整行切换折叠
              GestureDetector(
                onTap: () => setState(() {
                  if (isCollapsed) {
                    _collapsedGroups.remove(gid);
                  } else {
                    _collapsedGroups.add(gid);
                  }
                }),
                child: Padding(
                  padding: const EdgeInsets.only(left: 4, top: 8, bottom: 4),
                  child: Row(
                    children: [
                      Icon(
                        isCollapsed ? Icons.expand_more : Icons.expand_less,
                        size: 18,
                        color: Colors.grey,
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '$subtitle（${full.length}）',
                              style: const TextStyle(fontSize: 11, color: Colors.grey),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            allEnabled
                                ? L10n.tr('全部启用')
                                : (noneEnabled ? L10n.tr('全部关闭') : L10n.tr('部分启用')),
                            style: TextStyle(fontSize: 11, color: allEnabled ? AppTheme.brandGreen : Colors.grey),
                          ),
                          Switch.adaptive(
                            value: triState ?? false,
                            onChanged: (v) => _toggleAll(full, v),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              // 折叠状态：隐藏模型卡片列表
              if (!isCollapsed) ...list.map((m) => _modelCard(m)),
            ],
          );
        }).toList(),
      ),
    );
  }

  /// 同步历史（最近 10 次）
  void _showHistory(AppState app) {
    final history = app.syncHistory;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(L10n.tr('同步历史')),
        content: SizedBox(
          width: 460,
          child: history.isEmpty
              ? Text(L10n.tr('暂无同步记录'))
              : ListView(
                  shrinkWrap: true,
                  children: history.map((h) {
                    final ts = h['timestamp'] as int? ?? 0;
                    final providers =
                        List<Map>.from((h['providers'] as List?) ?? const []);
                    final failed =
                        providers.where((p) => p['success'] != true).toList();
                    final detail = providers
                        .map((p) {
                          final pid = p['provider'] as String;
                          final pname = ProviderNameResolver.fromKey(
                              pid, pid, app);
                          return p['success'] == true
                              ? L10n.fmt('{name} {count} 个（新增 {new}）', {
                                  'name': pname,
                                  'count': '${p['count']}',
                                  'new': '${p['new']}',
                                })
                              : L10n.fmt('失败：{err}', {'err': '${p['error'] ?? ''}'});
                        })
                        .join('\n');
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        failed.isEmpty ? Icons.check_circle : Icons.warning,
                        color: failed.isEmpty ? Colors.green : Colors.orange,
                        size: 20,
                      ),
                      title: Text(
                        '${DateFormat('MM-dd HH:mm:ss').format(DateTime.fromMillisecondsSinceEpoch(ts))}  ${L10n.fmt('共 {n} 个模型', {'n': '${h['total_models'] ?? 0}'})}',
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(detail,
                          style: const TextStyle(fontSize: 12)),
                    );
                  }).toList(),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(L10n.tr('关闭')),
          ),
        ],
      ),
    );
  }

  Widget _modelCard(ModelInfo m) {
    final deprecated = m.status != 'active';
    final app = Provider.of<AppState>(context, listen: false);
    final providerName = ProviderNameResolver.fromKey(
        m.provider, m.provider, app);
    return Dismissible(
      key: ValueKey('model-${m.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: Colors.red.shade400,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(L10n.tr('删除模型')),
            content: Text(L10n.fmt('确认删除「{name}」？', {'name': m.displayName})),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(L10n.tr('取消'))),
              TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(L10n.tr('删除'))),
            ],
          ),
        );
        return ok ?? false;
      },
      onDismissed: (_) {
        // 从模型库中删除该模型
        Provider.of<AppState>(context, listen: false)
            .modelRepository
            .deleteById(m.id);
        _load();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.fmt('已删除「{name}」', {'name': m.displayName}))),
        );
      },
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          title: Text(m.displayName),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(providerName,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              if (m.capabilities.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    spacing: 4,
                    runSpacing: -8,
                    children: m.capabilities
                        .map((c) => Chip(
                              label: Text(c),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                              labelStyle: const TextStyle(fontSize: 11),
                              padding: EdgeInsets.zero,
                            ))
                        .toList(),
                  ),
                ),
              if (deprecated)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(L10n.tr('已下线'),
                      style: const TextStyle(fontSize: 11, color: Colors.red)),
                ),
            ],
          ),
          trailing: Switch(
            value: m.isEnabled,
            onChanged: (v) => _toggle(m, v),
          ),
        ),
      ),
    );
  }
}
