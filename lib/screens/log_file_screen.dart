import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:relaygo/app.dart';
import 'package:relaygo/config/theme.dart';
import 'package:relaygo/l10n/app_strings.dart';
import 'package:path_provider/path_provider.dart';

/// 按天日志文件查看与导出页
///
/// 显示日期列表，可查看当日日志内容或导出为文件。
class LogFileScreen extends StatefulWidget {
  const LogFileScreen({Key? key}) : super(key: key);

  @override
  State<LogFileScreen> createState() => _LogFileScreenState();
}

class _LogFileScreenState extends State<LogFileScreen> {
  List<(String, int)> _files = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    setState(() => _loading = true);
    final app = Provider.of<AppState>(context, listen: false);
    // 确保文件日志目录已初始化
    if (app.logService.logDirectory == null) {
      try {
        final docs = await getApplicationDocumentsDirectory();
        app.logService.logDirectory = Directory('${docs.path}/relay-logs');
      } catch (_) {}
    }
    final files = app.logService.listDailyFiles();
    if (mounted) {
      setState(() {
        _files = files;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = Provider.of<AppState>(context);
    final today = app.logService.todayFileDate;

    return Scaffold(
      appBar: AppBar(
        title: Text(L10n.tr('日志文件')),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: L10n.tr('刷新'),
            onPressed: _loadFiles,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _files.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.description_outlined,
                          size: 48, color: Colors.grey),
                      const SizedBox(height: 12),
                      Text(L10n.tr('暂无日志文件'),
                          style:
                              const TextStyle(fontSize: 16, color: Colors.grey)),
                      const SizedBox(height: 8),
                      Text(
                        L10n.tr('启动代理服务器后自动按天生成'),
                        style: const TextStyle(
                            fontSize: 13, color: AppTheme.text3),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _files.length,
                  itemBuilder: (ctx, i) {
                    final (name, size) = _files[i];
                    final isToday = name == '$today.log';
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: Icon(
                          isToday ? Icons.today : Icons.calendar_today,
                          color: isToday ? AppTheme.brandGreen : null,
                        ),
                        title: Text(
                          name.replaceAll('.log', ''),
                          style: const TextStyle(
                              fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          isToday
                              ? '${L10n.tr("今天")} · ${_formatSize(size)}'
                              : _formatSize(size),
                          style: const TextStyle(
                              fontSize: 12, color: AppTheme.text3),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.visibility,
                                  size: 20),
                              tooltip: L10n.tr('查看'),
                              onPressed: () =>
                                  _viewFile(context, name),
                            ),
                            IconButton(
                              icon: const Icon(Icons.download,
                                  size: 20),
                              tooltip: L10n.tr('导出'),
                              onPressed: () =>
                                  _exportFile(context, app, name),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  Future<void> _viewFile(BuildContext context, String name) async {
    final app = Provider.of<AppState>(context, listen: false);
    final content = await app.logService.readDailyFile(name);
    if (!context.mounted) return;
    final lines = content.split('\n');
    final displayLines = lines.length > 200
        ? lines.sublist(lines.length - 200)
        : lines;
    final truncated = lines.length > 200;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _LogFileViewer(
          title: name.replaceAll('.log', ''),
          content: displayLines.join('\n'),
          truncated: truncated,
          totalLines: lines.length,
        ),
      ),
    );
  }

  Future<void> _exportFile(
      BuildContext context, AppState app, String name) async {
    final content = await app.logService.readDailyFile(name);
    if (!context.mounted) return;
    try {
      // 写入系统临时目录，SnackBar 提示路径（与 log_viewer_screen 风格一致）
      final outFile =
          File('${Directory.systemTemp.path}/relay_$name');
      await outFile.writeAsString(content);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.fmt('已导出到 {path}', {'path': outFile.path}))),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${L10n.tr("导出失败")}: $e')),
      );
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// 内嵌的文件内容查看页
class _LogFileViewer extends StatelessWidget {
  final String title;
  final String content;
  final bool truncated;
  final int totalLines;

  const _LogFileViewer({
    Key? key,
    required this.title,
    required this.content,
    this.truncated = false,
    this.totalLines = 0,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Column(
        children: [
          if (truncated)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: AppTheme.warning.withValues(alpha: 0.12),
              child: Text(
                L10n.fmt('文件 {n} 行，仅显示最近 200 行', {'n': '$totalLines'}),
                style:
                    const TextStyle(fontSize: 12, color: AppTheme.warning),
              ),
            ),
          Expanded(
            child: content.isEmpty
                ? Center(
                    child: Text(L10n.tr('文件夹为空'),
                        style: const TextStyle(color: Colors.grey)))
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      content,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        height: 1.5,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}