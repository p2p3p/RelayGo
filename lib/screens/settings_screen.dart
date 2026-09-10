import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:provider/provider.dart';
import 'package:relaygo/app.dart';
import 'package:relaygo/config/constants.dart';
import 'package:relaygo/config/theme.dart';
import 'package:relaygo/services/keep_alive.dart';
import 'package:relaygo/screens/rules_screen.dart';
import 'package:relaygo/screens/free_api_screen.dart';
import 'package:relaygo/screens/log_viewer_screen.dart';
import 'package:relaygo/screens/log_file_screen.dart';
import 'package:relaygo/screens/update_screen.dart';
import 'package:relaygo/screens/license_screen.dart';
import 'package:relaygo/utils/validators.dart';
import 'package:relaygo/l10n/app_strings.dart';

/// 设置页（底部导航第 5 个 Tab）
///
/// 一页集中展示：服务器配置 / 后台运行 / 日志 / 通用 / 高级功能 / 日志与文件 / 关于。
/// 所有变更即时生效，无底部保存按钮。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late int _port;
  late String _host;
  late String _strategy;
  late String _lang;
  late bool _autoStartOnBoot;
  late bool _keepAliveEnabled;
  late bool _ignoreBatteryOptimization;
  late int _logRetentionDays;
  late int _keyCooldownSeconds;
  late int _quotaCooldownMinutes;
  late int _rateLimitWindowSeconds;
  late int _tpmWaitBudgetSeconds;
  late int _qpsWaitBudgetSeconds;

  final _portCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final s = Provider.of<AppState>(context, listen: false).settings;
    _port = s.port;
    _host = s.host;
    _strategy = s.loadBalanceStrategy;
    _lang = s.language;
    _autoStartOnBoot = s.autoStartOnBoot;
    _keepAliveEnabled = s.keepAliveEnabled;
    _ignoreBatteryOptimization = s.ignoreBatteryOptimization;
    _logRetentionDays = s.logRetentionDays;
    _keyCooldownSeconds = s.keyCooldownSeconds;
    _quotaCooldownMinutes = s.quotaCooldownMinutes;
    _rateLimitWindowSeconds = s.rateLimitWindowSeconds;
    _tpmWaitBudgetSeconds = s.tpmWaitBudgetSeconds;
    _qpsWaitBudgetSeconds = s.qpsWaitBudgetSeconds;
    _portCtrl.text = '$_port';
  }

  @override
  void dispose() {
    _portCtrl.dispose();
    super.dispose();
  }

  /// 即时保存设置
  Future<void> _save(AppState app) async {
    final newSettings = app.settings.copyWith(
      port: _port,
      host: _host,
      loadBalanceStrategy: _strategy,
      language: _lang,
      autoStartOnBoot: _autoStartOnBoot,
      keepAliveEnabled: _keepAliveEnabled,
      ignoreBatteryOptimization: _ignoreBatteryOptimization,
      logRetentionDays: _logRetentionDays,
      keyCooldownSeconds: _keyCooldownSeconds,
      quotaCooldownMinutes: _quotaCooldownMinutes,
      rateLimitWindowSeconds: _rateLimitWindowSeconds,
      tpmWaitBudgetSeconds: _tpmWaitBudgetSeconds,
      qpsWaitBudgetSeconds: _qpsWaitBudgetSeconds,
    );
    await app.saveSettings(newSettings);
  }

  Future<void> _requestBatteryExemption() async {
    final ignoring = await KeepAliveHelper.isIgnoringBatteryOptimizations();
    if (ignoring) return;
    await KeepAliveHelper.requestIgnoreBatteryOptimizations();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(L10n.tr('若未弹出授权框，请到「系统设置 → 应用 → 电池优化」中手动允许')),
      duration: const Duration(seconds: 4),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final app = Provider.of<AppState>(context);
    final t = L10n.instance;
    return Scaffold(
      appBar: AppBar(title: Text(t.t('设置'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          // —— 分组 1：服务器配置 ——
          _section(t.t('服务器配置')),
          _card(context, [
            _row(
              title: t.t('监听端口'),
              subtitle: L10n.tr('Relay 服务监听端口'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _monoTag('$_port'),
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      textStyle: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    onPressed: () => _editPort(context, app),
                    child: Text(L10n.tr('修改')),
                  ),
                ],
              ),
            ),
            _divider(),
            _row(
              title: t.t('局域网访问'),
              subtitle: L10n.tr('允许局域网内设备连接'),
              trailing: _switch(
                _host != '127.0.0.1',
                (v) {
                  setState(() => _host = v ? '0.0.0.0' : '127.0.0.1');
                  _save(app);
                },
              ),
            ),
            _divider(),
            _row(
              title: t.t('负载均衡策略'),
              trailing: _select<String>(
                value: _strategy,
                items: [
                  DropdownMenuItem(
                      value: 'round_robin', child: Text(L10n.tr('轮询'))),
                  DropdownMenuItem(
                      value: 'weighted_round_robin',
                      child: Text(L10n.tr('加权轮询'))),
                  DropdownMenuItem(
                      value: 'priority', child: Text(L10n.tr('优先级'))),
                  DropdownMenuItem(
                      value: 'least_connections',
                      child: Text(L10n.tr('最少连接'))),
                  DropdownMenuItem(
                      value: 'response_time', child: Text(L10n.tr('响应时间'))),
                  DropdownMenuItem(value: 'smart', child: Text(L10n.tr('智能'))),
                ],
                onChanged: (v) {
                  setState(() => _strategy = v!);
                  _save(app);
                },
              ),
            ),
            _divider(),
            _row(
              title: t.t('开机自启'),
              subtitle: L10n.tr('开机后自动运行服务'),
              trailing: _switch(_autoStartOnBoot, (v) {
                setState(() => _autoStartOnBoot = v);
                _save(app);
              }),
            ),
          ]),

          // —— 分组 2：限流与冷却 ——
          _section(t.t('限流与冷却')),
          _card(context, [
            _numberRow(
              title: t.t('失败冷却时长'),
              subtitle: L10n.tr('Key 连续失败后暂停使用的时间'),
              value: _keyCooldownSeconds,
              unit: L10n.tr('秒'),
              onTap: () => _editNumber(
                context: context,
                title: t.t('失败冷却时长'),
                value: _keyCooldownSeconds,
                min: 0,
                max: 86400,
                unit: L10n.tr('秒'),
                onSaved: (v) {
                  setState(() => _keyCooldownSeconds = v);
                  _save(app);
                },
              ),
            ),
            _divider(),
            _numberRow(
              title: t.t('额度耗尽冷却'),
              subtitle: L10n.tr('Key 额度耗尽后暂停使用的时间'),
              value: _quotaCooldownMinutes,
              unit: L10n.tr('分钟'),
              onTap: () => _editNumber(
                context: context,
                title: t.t('额度耗尽冷却'),
                value: _quotaCooldownMinutes,
                min: 1,
                max: 1440,
                unit: L10n.tr('分钟'),
                onSaved: (v) {
                  setState(() => _quotaCooldownMinutes = v);
                  _save(app);
                },
              ),
            ),
            _divider(),
            _numberRow(
              title: t.t('限流统计窗口'),
              subtitle: L10n.tr('IP / 全局 / Token 限流的统计时长'),
              value: _rateLimitWindowSeconds,
              unit: L10n.tr('秒'),
              onTap: () => _editNumber(
                context: context,
                title: t.t('限流统计窗口'),
                value: _rateLimitWindowSeconds,
                min: 5,
                max: 600,
                unit: L10n.tr('秒'),
                onSaved: (v) {
                  setState(() => _rateLimitWindowSeconds = v);
                  _save(app);
                },
              ),
            ),
            _divider(),
            _numberRow(
              title: t.t('TPM 等待预算'),
              subtitle: L10n.tr('撞 TPM 限流后同 Key 等待重试的时间'),
              value: _tpmWaitBudgetSeconds,
              unit: L10n.tr('秒'),
              onTap: () => _editNumber(
                context: context,
                title: t.t('TPM 等待预算'),
                value: _tpmWaitBudgetSeconds,
                min: 0,
                max: 120,
                unit: L10n.tr('秒'),
                onSaved: (v) {
                  setState(() => _tpmWaitBudgetSeconds = v);
                  _save(app);
                },
              ),
            ),
            _divider(),
            _numberRow(
              title: t.t('QPS 等待预算'),
              subtitle: L10n.tr('撞 QPS/RPM 限流后同 Key 等待重试的时间'),
              value: _qpsWaitBudgetSeconds,
              unit: L10n.tr('秒'),
              onTap: () => _editNumber(
                context: context,
                title: t.t('QPS 等待预算'),
                value: _qpsWaitBudgetSeconds,
                min: 0,
                max: 120,
                unit: L10n.tr('秒'),
                onSaved: (v) {
                  setState(() => _qpsWaitBudgetSeconds = v);
                  _save(app);
                },
              ),
            ),
          ]),

          // —— 分组 3：后台运行 ——
          _section(t.t('后台运行')),
          _card(context, [
            _row(
              title: t.t('后台保活'),
              subtitle: L10n.tr('前台服务 + 常驻通知，防止系统回收进程'),
              trailing: _switch(_keepAliveEnabled, (v) {
                setState(() => _keepAliveEnabled = v);
                _save(app);
              }),
            ),
            _divider(),
            _row(
              title: t.t('忽略电池优化'),
              subtitle: L10n.tr('加入白名单，避免 Doze 模式被杀'),
              trailing: _switch(_ignoreBatteryOptimization, (v) async {
                setState(() => _ignoreBatteryOptimization = v);
                await _save(app);
                if (v) await _requestBatteryExemption();
              }),
            ),
          ]),

          // —— 分组 4：日志 ——
          _section(t.t('日志')),
          _card(context, [
            _row(
              title: t.t('日志保留'),
              subtitle: L10n.tr('超过保留天数的日志自动清理'),
              trailing: _select<int>(
                value: _logRetentionDays == 0
                    ? 0
                    : (_logRetentionDays >= 30
                        ? 30
                        : (_logRetentionDays >= 15 ? 15 : 7)),
                items: [
                  DropdownMenuItem(value: 7, child: Text(L10n.tr('7 天'))),
                  DropdownMenuItem(value: 15, child: Text(L10n.tr('15 天'))),
                  DropdownMenuItem(value: 30, child: Text(L10n.tr('30 天'))),
                  DropdownMenuItem(
                      value: 0, child: Text(L10n.tr('永久保留'))),
                ],
                onChanged: (v) {
                  setState(() => _logRetentionDays = v!);
                  _save(app);
                },
              ),
            ),
            _divider(),
            _navTile(context, Icons.receipt_long_outlined, t.t('请求日志'),
                L10n.tr('实时请求记录，可筛选与导出'), const LogViewerScreen()),
            _divider(),
            _navTile(context, Icons.folder_open_outlined, t.t('日志文件'),
                L10n.tr('按天记录，可查看与导出'), const LogFileScreen()),
          ]),

          // —— 分组 5：通用 ——
          _section(t.t('通用')),
          _card(context, [
            _row(
              title: t.t('语言'),
              trailing: _select<String>(
                value: _lang,
                items: [
                  DropdownMenuItem(value: 'zh', child: Text(L10n.tr('中文'))),
                  const DropdownMenuItem(value: 'en', child: Text('English')),
                ],
                onChanged: (v) {
                  setState(() {
                    _lang = v!;
                    L10n.instance.setLanguage(v);
                  });
                  _save(app);
                },
              ),
            ),
            _divider(),
            _navTile(context, Icons.rule_outlined, t.t('路由规则'),
                L10n.tr('按条件智能路由'), const RulesScreen()),
            _divider(),
            _navTile(context, Icons.celebration_outlined, t.t('免费 API'),
                L10n.tr('免费大模型接口推荐'), const FreeApiScreen()),
          ]),

          // —— 分组 6：关于 ——
          _section(t.t('关于')),
          _card(context, [
            _row(
              leading: const Icon(Icons.info_outline,
                  size: 20, color: AppTheme.brandGreen),
              title: Constants.appName,
              subtitle: 'v${Constants.appVersion}',
              trailing: _chip(L10n.tr('最新版'), AppTheme.surface2, AppTheme.text2),
            ),
            _divider(),
            _navTile(context, Icons.system_update_outlined, t.t('在线更新'),
                'v${Constants.appVersion}', const UpdateScreen()),
            _divider(),
            _navTile(context, Icons.code, t.t('开源仓库'),
                'github.com/resooo/RelayGo', null,
                onTap: () => _openUrl('https://github.com/resooo/RelayGo')),
            _divider(),
            _navTile(context, Icons.description_outlined, t.t('开源协议'),
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

  Widget _row({
    Widget? leading,
    required String title,
    String? subtitle,
    required Widget trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          if (leading != null) ...[leading, const SizedBox(width: 12)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.text)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.text2)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          trailing,
        ],
      ),
    );
  }

  /// 数值配置行（右侧显示当前值 + 「修改」按钮）
  Widget _numberRow({
    required String title,
    String? subtitle,
    required int value,
    required String unit,
    required VoidCallback onTap,
  }) {
    return _row(
      title: title,
      subtitle: subtitle,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _monoTag('$value $unit'),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              textStyle:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            onPressed: onTap,
            child: Text(L10n.tr('修改')),
          ),
        ],
      ),
    );
  }

  /// 导航入口行（带箭头，点击跳转二级页面）
  Widget _navTile(BuildContext context, IconData icon, String title,
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
      trailing:
          const Icon(Icons.chevron_right, color: AppTheme.text3, size: 20),
      onTap: onTap ??
          (page != null
              ? () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => page))
              : null),
    );
  }

  Widget _monoTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.surface2,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: AppTheme.monoFontFamily,
          fontSize: 12,
          color: AppTheme.text2,
        ),
      ),
    );
  }

  Widget _chip(String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
            fontSize: 11.5, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }

  Widget _switch(bool value, ValueChanged<bool> onChanged) {
    return Switch(
      value: value,
      onChanged: onChanged,
      activeTrackColor: AppTheme.brandGreen,
    );
  }

  Widget _select<T>({
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    final safeValue =
        items.any((i) => i.value == value) ? value : items.first.value;
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: safeValue,
          isDense: true,
          items: items,
          onChanged: onChanged,
          style: const TextStyle(
              fontSize: 13, color: AppTheme.text, fontWeight: FontWeight.w600),
          icon: const Icon(Icons.expand_more, size: 18),
        ),
      ),
    );
  }

  void _editPort(BuildContext context, AppState app) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.tr('修改端口')),
        content: TextField(
          controller: _portCtrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(labelText: L10n.tr('监听端口')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(L10n.tr('取消'))),
          TextButton(
            onPressed: () {
              if (Validators.validatePort(_portCtrl.text) != null) {
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(L10n.tr('端口不合法'))));
                return;
              }
              setState(() => _port = int.tryParse(_portCtrl.text) ?? _port);
              Navigator.pop(ctx);
              _save(app);
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(L10n.tr('端口已更新，重启服务后生效'))));
            },
            child: Text(L10n.tr('确定')),
          ),
        ],
      ),
    );
  }

  /// 通用数值编辑弹框：校验范围后回调 [onSaved]
  Future<void> _editNumber({
    required BuildContext context,
    required String title,
    required int value,
    required int min,
    required int max,
    required String unit,
    required ValueChanged<int> onSaved,
  }) async {
    final ctrl = TextEditingController(text: '$value');
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            labelText: unit,
            helperText: '${L10n.tr('范围')}：$min - $max',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(L10n.tr('取消'))),
          TextButton(
            onPressed: () {
              final v = int.tryParse(ctrl.text.trim());
              if (v == null || v < min || v > max) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(
                        '${L10n.tr('请输入')} $min - $max ${L10n.tr('的整数')}')));
                return;
              }
              Navigator.pop(ctx, v);
            },
            child: Text(L10n.tr('确定')),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (result != null) onSaved(result);
  }

  void _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
