import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';
import 'package:relaygo/app.dart';
import 'package:relaygo/config/constants.dart';
import 'package:relaygo/config/theme.dart';
import 'package:relaygo/models/api_key.dart';
import 'package:relaygo/screens/key_management_screen.dart';
import 'package:relaygo/services/log_service.dart';
import 'package:relaygo/widgets/animated_count_text.dart';
import 'package:relaygo/screens/key_edit_dialog.dart';
import 'package:relaygo/screens/log_viewer_screen.dart';
import 'package:relaygo/screens/alerts_screen.dart';
import 'package:relaygo/screens/report_screen.dart';
import 'package:relaygo/screens/model_management_screen.dart';
import 'package:relaygo/screens/provider_management_screen.dart';
import 'package:relaygo/screens/candidate_pool_screen.dart';
import 'package:relaygo/screens/rate_limit_event_screen.dart';
import 'package:relaygo/screens/settings_screen.dart';
import 'package:relaygo/utils/network.dart';
import 'package:relaygo/l10n/app_strings.dart';

/// 首页（对应设计稿 HomeScreen）
///
/// 底部导航切换四个主页面：首页 / Keys / 日志 / 统计。
/// 首页：状态卡（呼吸圆点 + 运行状态）+ 今日统计 + 快捷操作 + 更多功能。
class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  /// 周期刷新定时器：让今日 Token 统计像秒表一样动态增加
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    // 每 2 秒重新统计一次今日 Token，配合 AnimatedCountText 产生滚动递增效果
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = Provider.of<AppState>(context);
    final running = app.serverRunning;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            // 品牌 Logo（渐变圆角方块 + 闪电）
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                gradient: AppTheme.brandGradient,
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(Icons.bolt, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 10),
            const Text(Constants.appName),
          ],
        ),
        actions: [
          // 告警铃铛（带未读徽标）
          IconButton(
            icon: Stack(
              children: [
                const Icon(Icons.notifications_outlined),
                if (app.unreadAlerts > 0)
                  Positioned(
                    top: 2,
                    right: 2,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(
                        color: AppTheme.danger,
                        shape: BoxShape.circle,
                      ),
                      constraints: const BoxConstraints(
                        minWidth: 8,
                        minHeight: 8,
                      ),
                    ),
                  ),
              ],
            ),
            tooltip: L10n.tr('告警'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AlertsScreen()),
            ),
          ),
        ],
      ),
      body: IndexedStack(
        index: _index,
        children: [
          _buildHomeTab(context, app, running),
          const KeyManagementScreen(),
          const ModelManagementScreen(),
          const ProviderManagementScreen(),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.home_outlined),
            selectedIcon: const Icon(Icons.home),
            label: L10n.tr('首页'),
          ),
          const NavigationDestination(
            icon: Icon(Icons.key_outlined),
            selectedIcon: Icon(Icons.key),
            label: 'Keys',
          ),
          NavigationDestination(
            icon: const Icon(Icons.model_training_outlined),
            selectedIcon: const Icon(Icons.model_training),
            label: L10n.tr('模型'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.cloud_outlined),
            selectedIcon: const Icon(Icons.cloud),
            label: L10n.tr('提供商'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings),
            label: L10n.tr('设置'),
          ),
        ],
      ),
    );
  }

  // ———————— 首页 Tab ————————
  Widget _buildHomeTab(BuildContext context, AppState app, bool running) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _statusCard(context, app, running),
        const SizedBox(height: 16),
        _KeyMonitorSectionWidget(
          builder: (ctx) => _keyMonitorSection(ctx,
              Provider.of<AppState>(ctx, listen: false)),
        ),
        const SizedBox(height: 16),
        _quickActions(context, app),
      ],
    );
  }

  /// 状态卡（对应设计稿：呼吸圆点 + Relay 服务 + 运行状态徽章 + 监听地址 + 运行时长 + 启停按钮）
  Widget _statusCard(BuildContext context, AppState app, bool running) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1A000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              _PulseDot(color: running ? AppTheme.brandGreen : AppTheme.danger),
              const SizedBox(width: 10),
              Text(L10n.tr('Relay 服务'),
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.text)),
              const Spacer(),
              // 状态徽章
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: running
                      ? const Color(0xFFA6F5C4)
                      : const Color(0xFFFFDAD6),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  running ? L10n.tr('运行中') : L10n.tr('已停止'),
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: running
                        ? const Color(0xFF00210F)
                        : const Color(0xFF410002),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // 监听地址（本机 + 局域网，点击复制完整 URL）
          Row(
            children: [
              Text(L10n.tr('监听地址'),
                  style: const TextStyle(fontSize: 12.5, color: AppTheme.text2)),
              const Spacer(),
              const Icon(Icons.copy, size: 13, color: AppTheme.text3),
              const SizedBox(width: 4),
              Text(L10n.tr('点击复制'),
                  style: const TextStyle(fontSize: 11, color: AppTheme.text3)),
            ],
          ),
          const SizedBox(height: 6),
          _copyRow(context, L10n.tr('本机'),
              'http://127.0.0.1:${app.proxy.port}/v1'),
          const SizedBox(height: 4),
          FutureBuilder<String?>(
            future: NetworkUtil.localIpv4(),
            builder: (context, snap) {
              final lan = snap.data;
              final url = lan == null || lan.isEmpty
                  ? 'http://0.0.0.0:${app.proxy.port}/v1'
                  : 'http://$lan:${app.proxy.port}/v1';
              return _copyRow(context, L10n.tr('局域网'), url);
            },
          ),
          const SizedBox(height: 8),
          // 运行时长
          Row(
            children: [
              Text(L10n.tr('运行时长'),
                  style: const TextStyle(fontSize: 12.5, color: AppTheme.text2)),
              const Spacer(),
              const _UptimeTextWidget(),
            ],
          ),
          const SizedBox(height: 16),
          // 启停按钮
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: Icon(running ? Icons.stop : Icons.play_arrow),
              label: Text(running ? L10n.tr('停止服务') : L10n.tr('启动服务')),
              style: FilledButton.styleFrom(
                backgroundColor: running ? AppTheme.danger : AppTheme.brandGreen,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: () async {
                try {
                  await app.toggleServer();
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('${L10n.tr('服务启动失败')}: $e'),
                    backgroundColor: AppTheme.danger,
                  ));
                }
              },
            ),
          ),
        ],
      ),
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
            color: AppTheme.text2),
      ),
    );
  }

  /// 可点击复制的监听地址行（点击复制完整 URL 到剪贴板）
  Widget _copyRow(BuildContext context, String label, String url) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: url));
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${L10n.tr('已复制到剪贴板')}: $url'),
          duration: const Duration(seconds: 2),
        ));
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Text(label,
                style:
                    const TextStyle(fontSize: 12, color: AppTheme.text2)),
            const SizedBox(width: 8),
            Expanded(child: _monoTag(url)),
          ],
        ),
      ),
    );
  }

  /// Key 实时监控栏：四图标（可用/冷却/候选池/限流事件）+ 今日 Token 统计
  Widget _keyMonitorSection(BuildContext context, AppState app) {
    final monitors = app.keyMonitors;
    final now = DateTime.now().millisecondsSinceEpoch;
    var usable = 0;
    var cooling = 0;
    for (final mon in monitors) {
      final key = mon['key'] as ApiKey;
      final inCooldown =
          key.cooldownUntil != null && key.cooldownUntil! > now;
      if (inCooldown) {
        cooling++;
      } else if (key.status == KeyStatus.active) {
        usable++;
      }
    }
    final rateLimitCount = app.rateLimitEvents.length;
    // 按日统计：只统计今天 0 点以来的日志
    final todayStart = DateTime.now()
        .copyWith(hour: 0, minute: 0, second: 0, millisecond: 0);
    final stats = app.logService.stats(
        filter: LogFilter(sinceMs: todayStart.millisecondsSinceEpoch));
    final todayTokens = stats.totalTokens;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        boxShadow: const [
          BoxShadow(
              color: Color(0x14000000),
              blurRadius: 12,
              offset: Offset(0, 3)),
        ],
      ),
      child: Column(
        children: [
          // —— 上半：四个状态图标 ——
          Row(
            children: [
              Expanded(
                child: _monitorIcon(
                  context,
                  icon: Icons.check_circle,
                  color: AppTheme.brandGreen,
                  count: usable,
                  label: L10n.tr('可用'),
                  onTap: () => setState(() {
                    _index = 1; // 切换到 Keys Tab
                  }),
                ),
              ),
              Expanded(
                child: _monitorIcon(
                  context,
                  icon: Icons.hourglass_bottom,
                  color: AppTheme.danger,
                  count: cooling,
                  label: L10n.tr('冷却'),
                  onTap: () => setState(() {
                    _index = 1;
                  }),
                ),
              ),
              Expanded(
                child: _monitorIcon(
                  context,
                  icon: Icons.pool_outlined,
                  color: Colors.blue,
                  count: monitors.length,
                  label: L10n.tr('候选池'),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const CandidatePoolScreen()),
                  ),
                ),
              ),
              Expanded(
                child: _monitorIcon(
                  context,
                  icon: Icons.shield_outlined,
                  color: Colors.orange,
                  count: rateLimitCount,
                  label: L10n.tr('限流事件'),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const RateLimitEventScreen()),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(height: 1, color: AppTheme.border),
          const SizedBox(height: 14),
          // —— 下半：今日 Token 统计 ——
          Row(
            children: [
              const Icon(Icons.token_outlined, size: 18, color: AppTheme.brandGreen),
              const SizedBox(width: 8),
              Text(L10n.tr('今日 Token'),
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.text2)),
              const Spacer(),
              AnimatedCountText(
                value: todayTokens,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  fontFamily: AppTheme.monoFontFamily,
                  color: AppTheme.brandDark,
                ),
                formatter: _fmtTokenNum,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 监控图标瓦片
  Widget _monitorIcon(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required int count,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, size: 22, color: color),
            ),
            const SizedBox(height: 6),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                fontFamily: AppTheme.monoFontFamily,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10.5, color: AppTheme.text2)),
          ],
        ),
      ),
    );
  }

  static String _fmtTokenNum(int v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}K';
    return '$v';
  }

  /// 快捷操作：高频动作（非页面跳转）
  Widget _quickActions(BuildContext context, AppState app) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(L10n.tr('快捷操作'),
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppTheme.text)),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _actionTile(
                context,
                icon: Icons.add_circle_outline,
                label: L10n.tr('添加 Key'),
                onTap: () => _showAddKeyDialog(context, app),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _actionTile(
                context,
                icon: Icons.sync,
                label: L10n.tr('一键同步'),
                onTap: () => _syncModels(context, app),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _actionTile(
                context,
                icon: Icons.receipt_long_outlined,
                label: L10n.tr('日志'),
                page: const LogViewerScreen(),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _actionTile(
                context,
                icon: Icons.insert_chart_outlined,
                label: L10n.tr('统计'),
                page: const ReportScreen(),
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _showAddKeyDialog(BuildContext context, AppState app) {
    showDialog(
      context: context,
      builder: (_) => KeyEditDialog(app: app),
    );
  }

  void _syncModels(BuildContext context, AppState app) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
      content: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Text(L10n.tr('正在同步模型...')),
        ],
      ),
      duration: const Duration(seconds: 30),
    ));
    try {
      final result = await app.syncModels();
      messenger.clearSnackBars();
      messenger.showSnackBar(SnackBar(
        content: Text(L10n.tr(
            '同步完成：${result.providerResults.length} 个服务商，${result.totalModels} 个模型')),
      ));
    } catch (e) {
      messenger.clearSnackBars();
      messenger.showSnackBar(
          SnackBar(content: Text('${L10n.tr('同步失败')}：$e')));
    }
  }

  /// 竖排紧凑操作瓦片
  Widget _actionTile(
    BuildContext context, {
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    Widget? page,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      onTap: onTap ??
          (page != null
              ? () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => page))
              : null),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1A000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: const Color(0xFFA6F5C4),
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              ),
              child: Icon(icon, size: 22, color: const Color(0xFF00210F)),
            ),
            const SizedBox(height: 6),
            Text(label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.text)),
          ],
        ),
      ),
    );
  }

  // _moreFeatures / _featureTile / _divider 已移至 MoreTabScreen
}

/// 迷你呼吸圆点（均衡条顶部 active Key 的状态指示，比 [_PulseDot] 更紧凑）
class _PulseDot extends StatefulWidget {
  final Color color;
  const _PulseDot({required this.color});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1600))
      ..repeat();
    _anim = Tween(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 18,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _anim,
            builder: (_, __) => Container(
              width: 18 + _anim.value * 12,
              height: 18 + _anim.value * 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color.withValues(alpha: (1 - _anim.value) * 0.35),
              ),
            ),
          ),
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color,
              boxShadow: [
                BoxShadow(color: widget.color.withValues(alpha: 0.5), blurRadius: 4),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 运行时长文本（自刷新，每秒更新，独立于父组件全局 rebuild）
class _UptimeTextWidget extends StatefulWidget {
  const _UptimeTextWidget();

  @override
  State<_UptimeTextWidget> createState() => _UptimeTextWidgetState();
}

class _UptimeTextWidgetState extends State<_UptimeTextWidget> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
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
    final app = context.read<AppState>();
    final start = app.serverStartedAt;
    if (start == null) {
      return const Text('—',
          style: TextStyle(fontSize: 12.5, color: AppTheme.text2));
    }
    final d = DateTime.now().difference(start);
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    final text =
        h > 0 ? '$h ${L10n.tr("小时")} $m ${L10n.tr("分")} $s ${L10n.tr("秒")}' : 
        m > 0 ? '$m ${L10n.tr("分")} $s ${L10n.tr("秒")}' : 
        '$s ${L10n.tr("秒")}';
    return Text(text,
        style: const TextStyle(fontSize: 12.5, color: AppTheme.text2));
  }
}

/// Key 实时监控仪表盘（自刷新，每 3 秒更新数据，独立于父组件全局 rebuild）
class _KeyMonitorSectionWidget extends StatefulWidget {
  final Widget Function(BuildContext) builder;

  const _KeyMonitorSectionWidget({required this.builder});

  @override
  State<_KeyMonitorSectionWidget> createState() =>
      _KeyMonitorSectionWidgetState();
}

class _KeyMonitorSectionWidgetState extends State<_KeyMonitorSectionWidget> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
