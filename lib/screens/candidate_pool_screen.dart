import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:relaygo/app.dart';
import 'package:relaygo/config/theme.dart';
import 'package:relaygo/models/api_key.dart';
import 'package:relaygo/widgets/key_card.dart';
import 'package:relaygo/l10n/app_strings.dart';

/// 候选池 Key 状态窗口（排错辅助）
///
/// 列出每个提供商下的 Key 名称及当前状态（active/inactive/error/exhausted/
/// 冷却中/失败次数），并定时刷新，动态反映冷却恢复与状态变化。
class CandidatePoolScreen extends StatefulWidget {
  const CandidatePoolScreen({Key? key}) : super(key: key);

  @override
  State<CandidatePoolScreen> createState() => _CandidatePoolScreenState();
}

class _CandidatePoolScreenState extends State<CandidatePoolScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // 每 2 秒刷新一次，动态反映冷却恢复 / 状态变化
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = Provider.of<AppState>(context);
    final allKeys = app.keyManager.getAll();
    final providerWithKeys = <String>{for (final k in allKeys) k.provider}.toList()
      ..sort();

    return Scaffold(
      appBar: AppBar(title: Text(L10n.tr('候选 Key 池'))),
      body: allKeys.isEmpty
          ? Center(
              child: Text(L10n.tr('暂无 Key'),
                  style: const TextStyle(color: Colors.grey)))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    L10n.tr('每个提供商下可用的 Key 与实时状态'),
                    style: const TextStyle(
                        fontSize: 13, color: AppTheme.text3),
                  ),
                ),
                for (final provider in providerWithKeys) ...[
                  _buildProviderSection(app, provider),
                  const SizedBox(height: 12),
                ],
              ],
            ),
    );
  }

  Widget _buildProviderSection(AppState app, String provider) {
    final keys = app.keyManager.getByProvider(provider);
    final usable = app.keyManager.getUsableByProvider(provider);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.cloud, size: 18, color: AppTheme.text2),
                const SizedBox(width: 8),
                Text(provider,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
                const Spacer(),
                Text(
                  L10n.fmt('{n} 个 Key, {u} 个可用', {
                    'n': '${keys.length}',
                    'u': '${usable.length}',
                  }),
                  style: const TextStyle(fontSize: 12, color: AppTheme.text3),
                ),
              ],
            ),
            const Divider(height: 16),
            for (final k in keys) _buildKeyRow(k),
          ],
        ),
      ),
    );
  }

  Widget _buildKeyRow(ApiKey k) {
    final iconColor = statusColor(k.status);
    final label = statusLabel(k.status);
    final now = DateTime.now().millisecondsSinceEpoch;
    final isCooling = k.cooldownUntil != null && k.cooldownUntil! > now;
    final chips = <String>[];
    if (label.isNotEmpty) chips.add(label);
    if (isCooling) {
      final secs = (k.cooldownUntil! - now) ~/ 1000;
      chips.add(L10n.fmt('冷却 {s}s', {'s': '$secs'}));
    }
    if (k.failureCount > 0) {
      chips.add(L10n.fmt('失败 {n} 次', {'n': '${k.failureCount}'}));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: iconColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  k.name.isEmpty ? k.maskedKey : k.name,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w500),
                ),
                if (k.name.isNotEmpty)
                  Text(
                    k.maskedKey,
                    style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.text3,
                        fontFamily: 'monospace'),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              chips.isNotEmpty ? chips.join(' · ') : L10n.tr('可用'),
              style:
                  TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: iconColor),
            ),
          ),
        ],
      ),
    );
  }
}