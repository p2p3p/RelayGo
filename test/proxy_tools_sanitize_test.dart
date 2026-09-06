// 端到端测试：tools[0].function.name 非法字符清洗（网关中间件）
//
// 复现场景：Cline/Cursor 或 MCP Server 注入的 tools 名称含 '.' / 空格 / 中文
// 等非法字符，DeepSeek / 商汤日日新等上游会直接拒绝（HTTP 400：
// Invalid 'tools[0].function.name': string does not match pattern '^[a-zA-Z0-9_-]+$'）。
//
// 本测试验证：RelayGo 在转发前把 function.name 与 parameters.properties 键名
// 清洗为 ^[a-zA-Z0-9_-]+$，使「原本 400」的请求变为「200」。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:relaygo/models/user_settings.dart';
import 'package:relaygo/services/key_manager.dart';
import 'package:relaygo/services/load_balancer.dart';
import 'package:relaygo/services/log_service.dart';
import 'package:relaygo/services/quota_monitor.dart';
import 'package:relaygo/services/rule_engine.dart';
import 'package:relaygo/services/proxy_server.dart';
import 'package:relaygo/database/model_repository.dart';
import 'package:relaygo/utils/encryption.dart';

/// 简易 mock 上游：模拟 DeepSeek/商汤的 tools 名称校验
///
/// 收到 /chat/completions 时检查 tools[0].function.name 是否匹配
/// `^[a-zA-Z0-9_-]+$`：
///  - 合法 → 200 + 正常响应
///  - 非法 → 400 + 与真实上游一致的错误信息
class ToolMockUpstream {
  final HttpServer server;
  final int port;

  /// 上游实际收到的请求体（用于断言清洗结果）
  Map<String, dynamic>? lastBody;

  ToolMockUpstream(this.server, this.port);

  static Future<ToolMockUpstream> bind() async {
    final s = await HttpServer.bind('127.0.0.1', 0);
    final inst = ToolMockUpstream(s, s.port);
    s.listen((req) async {
      if (req.uri.path.endsWith('/chat/completions')) {
        final raw = await utf8.decoder.bind(req).join();
        final body = jsonDecode(raw) as Map<String, dynamic>;
        inst.lastBody = body;
        final tools = body['tools'] as List?;
        String? name;
        if (tools != null && tools.isNotEmpty) {
          final t = tools.first;
          if (t is Map && t['function'] is Map) {
            final fn = t['function'] as Map;
            name = fn['name'] as String?;
          }
        }
        final valid = name == null ||
            RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(name);
        req.response
          ..statusCode = valid ? 200 : 400
          ..headers.contentType = ContentType.json;
        if (valid) {
          req.response.write(jsonEncode({
            'model': 'sensechat',
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': 'tool call accepted',
                  'tool_calls': [
                    {
                      'id': 'call_1',
                      'type': 'function',
                      'function': {'name': name, 'arguments': '{}'},
                    }
                  ],
                }
              }
            ],
          }));
        } else {
          req.response.write(jsonEncode({
            'error': {
              'message':
                  "Invalid 'tools[0].function.name': string does not match "
                      "pattern. Expected a string that matches the pattern "
                      "'^[a-zA-Z0-9_-]+\$'."
            }
          }));
        }
        await req.response.close();
        return;
      }
      req.response
        ..statusCode = 404
        ..write('not found');
      await req.response.close();
    });
    return inst;
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  late ToolMockUpstream mock;
  late KeyManager keyManager;
  late ModelRepository modelRepository;
  late UserSettings settings;

  setUpAll(() async {
    final tmp = Directory.systemTemp.createTempSync('relay_tools_sanitize');
    Hive.init(tmp.path);
    await Hive.openBox('api_keys');
    await Hive.openBox('request_logs');
    await Hive.openBox('routing_rules');
    await Hive.openBox('models');
    keyManager = KeyManager(Hive.box('api_keys'));
    modelRepository = ModelRepository(Hive.box('models'));
    settings = UserSettings(
      rulesEnabled: false,
      rateLimitEnabled: false,
      maxRetryKeys: 3,
      upstreamTimeoutSeconds: 5,
    );
    EncryptionUtil.init(EncryptionUtil.generateMasterKeyBase64());
  });

  tearDown(() async {
    for (final k in keyManager.getAll()) {
      await keyManager.deleteKey(k.id);
    }
    await modelRepository.clear();
    await mock.close();
  });

  Future<ProxyServer> startProxy() async {
    final srv = ProxyServer(
      keyManager: keyManager,
      loadBalancer: LoadBalancer(),
      logService: LogService(Hive.box('request_logs')),
      ruleEngine: RuleEngine(),
      quotaMonitor: QuotaMonitor(settings: settings),
      settings: settings,
      modelRepository: modelRepository,
      port: 0,
    );
    await srv.start();
    return srv;
  }

  Future<void> addCustomKey() async {
    await keyManager.createKey(
      provider: 'custom',
      providerId: 'sensetime',
      plainKey: 'sk-sensetime',
      name: '商汤',
      baseUrl: 'http://127.0.0.1:${mock.port}/v1',
      metadata: {
        'api_path': '/chat/completions',
        'model_list_path': '/models',
        'auth_header': 'authorization',
        'auth_prefix': 'Bearer ',
      },
    );
  }

  Future<Resp> sendChat(Map<String, dynamic> payload, int port) async {
    final client = HttpClient();
    final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:$port/v1/chat/completions'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(payload));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    client.close();
    return Resp(response.statusCode, body);
  }

  test('非法 tools 名称（含 . 与空格）被清洗后上游返回 200', () async {
    mock = await ToolMockUpstream.bind();
    await addCustomKey();
    final srv = await startProxy();
    final resp = await sendChat({
      'model': 'SenseChat-5',
      'messages': [
        {'role': 'user', 'content': '读取 home.md 内容'}
      ],
      'tools': [
        {
          'type': 'function',
          'function': {
            'name': 'file.get_content', // ← 点号为违规字符
            'description': '读取文件内容',
            'parameters': {
              'type': 'object',
              'properties': {
                'file_path': {'type': 'string'}, // 合法键名原样保留
              },
            },
          },
        },
      ],
    }, srv.port);

    // 修复前：上游会返回 400；修复后：名称被清洗为 file_get_content → 200
    expect(resp.statusCode, 200,
        reason: '清洗后应 200，实际 ${resp.statusCode}: ${resp.body}');
    final name =
        ((mock.lastBody!['tools'] as List).first as Map)['function']['name'];
    expect(name, 'file_get_content',
        reason: 'tools[0].function.name 应被清洗为合法形式');
    await srv.stop();
  });

  test('多个工具逐一清洗：中文、@、/ 均替换为 _', () async {
    mock = await ToolMockUpstream.bind();
    await addCustomKey();
    final srv = await startProxy();
    final resp = await sendChat({
      'model': 'SenseChat-5',
      'messages': [
        {'role': 'user', 'content': 'hi'}
      ],
      'tools': [
        {
          'type': 'function',
          'function': {
            'name': '工具.查询@v1',
            'parameters': {'type': 'object', 'properties': {}},
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'mcp__sqlite/query',
            'parameters': {'type': 'object', 'properties': {}},
          },
        },
      ],
    }, srv.port);

    expect(resp.statusCode, 200,
        reason: '清洗后应 200，实际 ${resp.statusCode}: ${resp.body}');
    final tools = mock.lastBody!['tools'] as List;
    // 工具.查询@v1 → 每个非法字符(6个)替换为 _ ：______v1
    expect(((tools[0] as Map)['function'] as Map)['name'], '______v1',
        reason: '中文与点号应全部替换为下划线');
    expect(((tools[1] as Map)['function'] as Map)['name'], 'mcp__sqlite_query',
        reason: '斜杠应替换为下划线');
    await srv.stop();
  });

  test('parameters.properties 非法键名一并清洗且冲突键追加后缀', () async {
    mock = await ToolMockUpstream.bind();
    await addCustomKey();
    final srv = await startProxy();
    final resp = await sendChat({
      'model': 'SenseChat-5',
      'messages': [
        {'role': 'user', 'content': 'hi'}
      ],
      'tools': [
        {
          'type': 'function',
          'function': {
            'name': 'read_file',
            'parameters': {
              'type': 'object',
              'properties': {
                'file.path': {'type': 'string'}, // 点号违规
                'file_path': {'type': 'string'}, // 合法，与上面清洗后冲突
                '文件 路径': {'type': 'string'}, // 中文+空格违规
              },
            },
          },
        },
      ],
    }, srv.port);

    expect(resp.statusCode, 200,
        reason: '清洗后应 200，实际 ${resp.statusCode}: ${resp.body}');
    final fn =
        ((mock.lastBody!['tools'] as List).first as Map)['function'] as Map;
    final props = (fn['parameters'] as Map)['properties'] as Map;
    // file.path → file_path；file_path(合法) 冲突 → file_path2；'文件 路径'(5非法) → _____
    expect(props.keys, containsAll(['file_path', 'file_path2', '_____']),
        reason: '非法键应被清洗，冲突键应追加后缀');
    expect(props.keys.length, 3, reason: '键数量不变，避免丢字段');
    await srv.stop();
  });

  test('合法 tools 名称原样透传（清洗为幂等操作）', () async {
    mock = await ToolMockUpstream.bind();
    await addCustomKey();
    final srv = await startProxy();
    const legalName = 'get_weather';
    final resp = await sendChat({
      'model': 'SenseChat-5',
      'messages': [
        {'role': 'user', 'content': 'hi'}
      ],
      'tools': [
        {
          'type': 'function',
          'function': {
            'name': legalName,
            'parameters': {
              'type': 'object',
              'properties': {
                'city_name': {'type': 'string'},
              },
            },
          },
        },
      ],
    }, srv.port);

    expect(resp.statusCode, 200,
        reason: '合法名称应 200，实际 ${resp.statusCode}: ${resp.body}');
    final name =
        ((mock.lastBody!['tools'] as List).first as Map)['function']['name'];
    expect(name, legalName, reason: '合法名称不应被改动');
    await srv.stop();
  });

  test('无 tools 字段的普通请求不受影响（原样透传）', () async {
    mock = await ToolMockUpstream.bind();
    await addCustomKey();
    final srv = await startProxy();
    final resp = await sendChat({
      'model': 'SenseChat-5',
      'messages': [
        {'role': 'user', 'content': '你好'}
      ],
    }, srv.port);
    expect(resp.statusCode, 200,
        reason: '无 tools 请求应正常，实际 ${resp.statusCode}: ${resp.body}');
    expect(mock.lastBody!['tools'], isNull,
        reason: '清洗不应向请求中注入 tools 字段');
    await srv.stop();
  });

  test('清洗后请求体其余字段（model/messages）原样保留', () async {
    mock = await ToolMockUpstream.bind();
    await addCustomKey();
    final srv = await startProxy();
    final resp = await sendChat({
      'model': 'SenseChat-5',
      'messages': [
        {'role': 'user', 'content': '读取 home.md 内容'}
      ],
      'tools': [
        {
          'type': 'function',
          'function': {
            'name': 'file.get_content',
            'parameters': {'type': 'object', 'properties': {}},
          },
        },
      ],
    }, srv.port);
    expect(resp.statusCode, 200,
        reason: '清洗后应 200，实际 ${resp.statusCode}: ${resp.body}');
    // 清洗只作用于 tools 名称，model 与 messages 必须原样保留
    expect(mock.lastBody!['model'], 'SenseChat-5',
        reason: 'model 字段不应被清洗逻辑改动');
    final messages = mock.lastBody!['messages'] as List;
    expect((messages.first as Map)['content'], '读取 home.md 内容',
        reason: 'messages 字段不应被清洗逻辑改动');
    await srv.stop();
  });
}

class Resp {
  final int statusCode;
  final String body;
  Resp(this.statusCode, this.body);
}
