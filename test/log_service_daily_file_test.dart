import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:relaygo/models/request_log.dart';
import 'package:relaygo/services/log_service.dart';

int _seq2 = 0;

void main() {
  late Box box;
  late Directory tmpDir;

  setUpAll(() async {
    tmpDir = Directory.systemTemp.createTempSync('logfile_test');
    Hive.init(tmpDir.path);
    box = await Hive.openBox('logs_file_test');
  });

  setUp(() async {
    await box.clear();
    // 清理可能遗留的日志目录
  });

  tearDown(() async {});

  tearDownAll(() async {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  RequestLog makeLog({
    String provider = 'openai',
    int status = 200,
  }) =>
      RequestLog(
        id: 'fl_${_seq2++}',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        method: 'POST',
        path: '/v1/chat/completions',
        provider: provider,
        keyMasked: 'sk-****',
        statusCode: status,
        durationMs: 100,
      );

  test('logDirectory 为 null 时不写文件', () {
    final svc = LogService(box);
    expect(svc.logDirectory, isNull);
    svc.add(makeLog());
    // 即使 add 被调用，没有目录就不写文件
    expect(svc.listDailyFiles().isEmpty, true);
    svc.dispose();
  });

  test('设置 logDirectory 后 add 生成当天的 .log 文件', () {
    final svc = LogService(box);
    svc.logDirectory = Directory('${tmpDir.path}/relay-logs');
    svc.add(makeLog());
    svc.add(makeLog());

    final files = svc.listDailyFiles();
    expect(files.length, 1);

    final (name, size) = files.first;
    expect(name.endsWith('.log'), true);
    expect(size, greaterThan(0));
    expect(svc.todayFileDate, isNotNull);

    // 每行一条 JSON
    final content = File('${svc.logDirectory!.path}/$name').readAsStringSync();
    final lines = content.trim().split('\n');
    expect(lines.length, 2);
    // 验证每行是合法 JSON
    for (final line in lines) {
      final map = Map<String, dynamic>.from(
          jsonDecode(line) as Map);
      expect(map['id'], isNotNull);
      expect(map['status_code'], 200);
    }

    svc.dispose();
  });

  test('listDailyFiles 按文件名倒序（最新在前）', () {
    final svc = LogService(box);
    svc.logDirectory = Directory('${tmpDir.path}/multi-relay-logs');
    svc.add(makeLog());
    // 手动创建两个较早日期的文件
    final dir = svc.logDirectory!;
    dir.createSync(recursive: true);
    File('${dir.path}/2025-01-01.log').writeAsStringSync('{"id":"old"}');
    File('${dir.path}/2025-01-02.log').writeAsStringSync('{"id":"new"}');

    final files = svc.listDailyFiles();
    // 至少包含 3 个文件（today + 2 fake）
    expect(files.length, greaterThanOrEqualTo(3));
    // 确保 fake 文件之间相对顺序正确（2025-01-02 在 2025-01-01 之前）
    final idxJan2 = files.indexWhere((f) => f.$1 == '2025-01-02.log');
    final idxJan1 = files.indexWhere((f) => f.$1 == '2025-01-01.log');
    expect(idxJan2, lessThan(idxJan1));

    svc.dispose();
  });

  test('readDailyFile 返回指定文件内容', () async {
    final svc = LogService(box);
    svc.logDirectory = Directory('${tmpDir.path}/read-relay-logs');
    svc.logDirectory!.createSync(recursive: true);
    File('${svc.logDirectory!.path}/2025-01-15.log')
        .writeAsStringSync('{"test":"data"}');

    final content = await svc.readDailyFile('2025-01-15.log');
    expect(content, contains('test'));
    expect(content, contains('data'));

    // 不存在的文件返回空
    final empty = await svc.readDailyFile('nonexistent.log');
    expect(empty, '');

    svc.dispose();
  });

  test('dispose 关闭文件句柄并标记已清理', () {
    final svc = LogService(box);
    svc.logDirectory = Directory('${tmpDir.path}/dispose-relay-logs');
    svc.add(makeLog());
    expect(svc.todayFileDate, isNotNull);
    svc.dispose();
    // 再次 dispose 应无异常（幂等）
    svc.dispose();
  });
}