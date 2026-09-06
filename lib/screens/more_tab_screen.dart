import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:relaygo/config/constants.dart';
import 'package:relaygo/config/theme.dart';
import 'package:relaygo/screens/rules_screen.dart';
import 'package:relaygo/screens/free_api_screen.dart';
import 'package:relaygo/screens/log_viewer_screen.dart';
import 'package:relaygo/screens/log_file_screen.dart';
import 'package:relaygo/screens/update_screen.dart';
import 'package:relaygo/screens/license_screen.dart';
import 'package:relaygo/screens/settings_screen.dart';
import 'package:relaygo/l10n/app_strings.dart';

/// 「更多」Tab：一页集中展示所有中低频功能入口。
///
/// 去重原则：
/// - 提供商管理 / 模型管理已在底部导航，不重复放
/// - 关于内容（更新/仓库/协议）整合在此页，设置页不再放
/// - 请求日志入口在此页，首页快捷操作不再放
class MoreTabScreen extends StatelessWidget {
  const MoreTabScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L10n.tr('更多'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          // —— 分组 1：高级功能 ——
          _section(L10n.tr('高级功能')),
          _card(context, [
            _tile(context, Icons.rule_outlined, L10n.tr('路由规则'),
                L10n.tr('按条件智能路由'), const RulesScreen()),
            _divider(),
            _tile(context, Icons.celebration_outlined, L10n.tr('免费 API'),
                L10n.tr('免费大模型接口推荐'), const FreeApiScreen()),
          ]),

          // —— 分组 2：日志与文件 ——
          _section(L10n.tr('日志与文件')),
          _card(context, [
            _tile(context, Icons.receipt_long_outlined, L10n.tr('请求日志'),
                L10n.tr('实时请求记录，可筛选与导出'), const LogViewerScreen()),
            _divider(),
            _tile(context, Icons.folder_open_outlined, L10n.tr('日志文件'),
                L10n.tr('按天记录，可查看与导出'), const LogFileScreen()),
          ]),

          // —— 分组 3：设置 ——
          _section(L10n.tr('设置')),
          _card(context, [
            _tile(context, Icons.settings_outlined, L10n.tr('设置'),
                L10n.tr('服务器、后台运行与日志'), const SettingsScreen()),
          ]),

          // —— 分组 4：关于 ——
          _section(L10n.tr('关于')),
          _card(context, [
            _tile(context, Icons.system_update_outlined, L10n.tr('在线更新'),
                'v${Constants.appVersion}', const UpdateScreen()),
            _divider(),
            _tile(context, Icons.code, L10n.tr('开源仓库'),
                'github.com/resooo/RelayGo', null,
                onTap: () => _openUrl('https://github.com/resooo/RelayGo')),
            _divider(),
            _tile(context, Icons.description_outlined, L10n.tr('开源协议'),
                L10n.tr('AGPL-3.0'), const LicenseScreen()),
          ]),

          const SizedBox(height: 12),
          const Center(
            child: Text(
              '${Constants.appName} v${Constants.appVersion}',
              style: TextStyle(fontSize: 12, color: AppTheme.text3),
            ),
          ),
        ],
      ),
    );
  }

  // ———————— 组件 ————————

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 4),
        child: Text(
          title.toUpperCase(),
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.04,
            color: Color(0xFF006B3F),
          ),
        ),
      );

  Widget _card(BuildContext context, List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color ?? Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        children: List.generate(children.length, (i) {
          return Column(
            children: [
              if (i > 0)
                const Divider(
                    height: 1, thickness: 1, indent: 16, color: AppTheme.border),
              children[i],
            ],
          );
        }),
      ),
    );
  }

  Widget _divider() => const Divider(
      height: 1, thickness: 1, indent: 16, endIndent: 16, color: AppTheme.border);

  Widget _tile(BuildContext context, IconData icon, String title,
      String subtitle, Widget? page,
      {VoidCallback? onTap}) {
    return ListTile(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: AppTheme.surface2,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        ),
        child: Icon(icon, size: 20, color: AppTheme.brandGreen),
      ),
      title: Text(title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle,
          style: const TextStyle(fontSize: 12, color: AppTheme.text2)),
      trailing: const Icon(Icons.chevron_right, color: AppTheme.text3, size: 20),
      onTap: onTap ??
          (page != null
              ? () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => page))
              : null),
    );
  }

  void _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
