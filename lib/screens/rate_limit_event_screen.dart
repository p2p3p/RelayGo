import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:relaygo/app.dart';
import 'package:relaygo/config/theme.dart';
import 'package:relaygo/l10n/app_strings.dart';
import 'package:relaygo/models/rate_limit_event.dart';
import 'package:relaygo/utils/provider_name_resolver.dart';

/// 限流切换 Key 事件查看页
///
/// 展示每次因限流（RPM / TPM / 429 / 额度耗尽）而切换 Key 的事件，
/// 包括时间、Key、原因与更新后的限制值。最新在前，支持清空。
class RateLimitEventScreen extends StatefulWidget {
  const RateLimitEventScreen({Key? key}) : super(key: key);

  @override
  State<RateLimitEventScreen> createState() => _RateLimitEventScreenState();
}

class _RateLimitEventScreenState extends State<RateLimitEventScreen> {
  @override
  Widget build(BuildContext context) {
    final app = Provider.of<AppState>(context);
    final events = app.rateLimitEvents;

    return Scaffold(
      appBar: AppBar(
        title: Text(L10n.tr('限流切换事件')),
        actions: [
          if (events.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: L10n.tr('清空'),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: Text(L10n.tr('清空限流事件')),
                    content: Text(L10n.tr('确认清空全部限流切换事件记录？')),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: Text(L10n.tr('取消'))),
                      TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: Text(L10n.tr('清空'))),
                    ],
                  ),
                );
                if (ok == true) await app.rateLimitEventLog.clear();
              },
            ),
        ],
      ),
      body: events.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.shield_outlined,
                      size: 56, color: AppTheme.text3),
                  const SizedBox(height: 12),
                  Text(
                    L10n.tr('暂无限流切换事件\n服务运行后，每次因限流切换 Key 都会记录在这里'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                // 统计条
                Container(
                  margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF2F7F4),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      _StatChip(
                          icon: Icons.request_page,
                          label: L10n.tr('事件'),
                          value: '${events.length}'),
                      _StatChip(
                          icon: Icons.bolt,
                          label: 'RPM',
                          value: '${events.where((e) => e.isRpm).length}'),
                      _StatChip(
                          icon: Icons.token,
                          label: 'TPM',
                          value: '${events.where((e) => e.isTpm).length}'),
                      _StatChip(
                          icon: Icons.warning_amber,
                          label: '429',
                          value: '${events.where((e) => e.isStatus429).length}'),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    itemCount: events.length,
                    itemBuilder: (ctx, i) => _EventTile(
                      event: events[i],
                      providerName:
                          ProviderNameResolver.resolveFromEvent(events[i], app),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _StatChip(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 14, color: AppTheme.brandGreen),
          const SizedBox(width: 4),
          Text('$label ',
              style: const TextStyle(fontSize: 11, color: AppTheme.text2)),
          Text(value,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  fontFamily: AppTheme.monoFontFamily)),
        ],
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  final RateLimitEvent event;
  final String providerName;

  const _EventTile({required this.event, required this.providerName});

  Color get _reasonColor {
    if (event.isQuota) return AppTheme.danger;
    if (event.isTpm) return Colors.orange;
    if (event.isRpm) return Colors.indigo;
    return Colors.deepPurple;
  }

  String get _reasonLabel {
    if (event.isQuota) return '额度';
    if (event.isTpm) return 'TPM';
    if (event.isRpm) return 'RPM';
    return '429';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // 原因徽章
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _reasonColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _reasonLabel,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _reasonColor,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    event.keyName,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  DateFormat('HH:mm:ss')
                      .format(event.dateTime.toLocal()),
                  style: const TextStyle(
                      fontSize: 12,
                      color: Colors.grey,
                      fontFamily: AppTheme.monoFontFamily),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              providerName,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            if (event.model.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                L10n.fmt('模型：{model}', {'model': event.model}),
                style: const TextStyle(fontSize: 12, color: AppTheme.text2),
              ),
            ],
            // 限制值变化
            if (event.oldRpmLimit > 0 || event.newRpmLimit > 0 ||
                event.oldTpmLimit > 0 || event.newTpmLimit > 0) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  if (event.oldTpmLimit > 0 || event.newTpmLimit > 0)
                    _chip('TPM', event.oldTpmLimit, event.newTpmLimit,
                        Colors.orange),
                  if (event.oldRpmLimit > 0 || event.newRpmLimit > 0)
                    _chip('RPM', event.oldRpmLimit, event.newRpmLimit,
                        Colors.indigo),
                ],
              ),
            ],
            // 详情
            if (event.detail.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: AppTheme.surface2,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  event.detail,
                  style: const TextStyle(fontSize: 11, color: AppTheme.text2),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, int oldVal, int newVal, Color color) {
    final arrow = oldVal > 0 && newVal > 0 && oldVal != newVal
        ? '${_fmt(oldVal)} → ${_fmt(newVal)}'
        : (newVal > 0 ? _fmt(newVal) : (oldVal > 0 ? _fmt(oldVal) : '—'));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$label $arrow',
        style: TextStyle(
            fontSize: 11.5,
            fontFamily: AppTheme.monoFontFamily,
            color: color,
            fontWeight: FontWeight.w600),
      ),
    );
  }

  static String _fmt(int v) {
    if (v >= 1000000) return '${(v / 10000).toStringAsFixed(0)}万';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
    return '$v';
  }
}