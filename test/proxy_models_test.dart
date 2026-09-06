// REQ-003：代理层 /v1/models 本地聚合接口（纯转发，返回真实模型明细）
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:relaygo/database/model_repository.dart';
import 'package:relaygo/models/model_info.dart';
import 'package:relaygo/models/user_settings.dart';
import 'package:relaygo/services/key_manager.dart';
import 'package:relaygo/services/load_balancer.dart';
import 'package:relaygo/services/log_service.dart';
import 'package:relaygo/services/proxy_server.dart';
import 'package:relaygo/services/quota_monitor.dart';
import 'package:relaygo/services/rule_engine.dart';
import 'package:relaygo/utils/encryption.dart';

void main() {
  late ModelRepository repo;
  late ProxyServer proxy;
  late UserSettings settings;

  setUpAll(() async {
    final tmp = Directory.systemTemp.createTempSync('proxy_models_test');
    Hive.init(tmp.path);
    await Hive.openBox('keys_pm_test');
    await Hive.openBox('logs_pm_test');
    await Hive.openBox('models_pm_test');
    EncryptionUtil.init(EncryptionUtil.generateMasterKeyBase64());
    repo = ModelRepository(Hive.box('models_pm_test'));
    settings = UserSettings(
      rulesEnabled: false,
      rateLimitEnabled: true, // 验证 /v1/models 不被入口限流拦截
      globalRpmLimit: 1,
      upstreamTimeoutSeconds: 5,
    );

    await repo.upsertAll([
      ModelInfo.unified(
        provider: 'openai',
        name: 'gpt-4o',
        ownedBy: 'openai',
        capabilities: const ['chat', 'vision'],
        createdAt: 1700000000000,
        lastSynced: 1700000001000,
      ),
      ModelInfo.unified(
        provider: 'openai',
        name: 'text-embedding-3-small',
        capabilities: const ['embedding'],
        lastSynced: 1700000001000,
      ),
      ModelInfo.unified(
        provider: 'openai',
        name: 'gpt-4-old',
        capabilities: const ['chat'],
        status: 'deprecated',
        isEnabled: false,
        lastSynced: 1700000001000,
      ),
      ModelInfo.unified(
        provider: 'anthropic',
        name: 'claude-3-5-sonnet-20241022',
        capabilities: const ['chat'],
        lastSynced: 1700000001000,
      ),
      ModelInfo.unified(
        provider: 'google',
        name: 'gemini-1.5-pro',
        capabilities: const ['chat'],
        isEnabled: false, // 用户手动停用
        lastSynced: 1700000001000,
      ),
      ModelInfo.unified(
        provider: 'custom',
        name: 'my-custom-chat-model',
        capabilities: const ['chat', 'function_calling'],
        lastSynced: 1700000001000,
      ),
    ]);

    proxy = ProxyServer(
      keyManager: KeyManager(Hive.box('keys_pm_test')),
      loadBalancer: LoadBalancer(),
      logService: LogService(Hive.box('logs_pm_test')),
      ruleEngine: RuleEngine(),
      quotaMonitor: QuotaMonitor(settings: settings),
      settings: settings,
      modelRepository: repo,
      port: 0,
    );
    await proxy.start();
  });

  tearDownAll(() async => proxy.stop());

  Future<Map<String, dynamic>> getModels([String query = '']) async {
    final client = HttpClient();
    final req = await client
        .getUrl(Uri.parse('http://127.0.0.1:${proxy.port}/v1/models$query'));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    client.close();
    expect(resp.statusCode, 200);
    return jsonDecode(body) as Map<String, dynamic>;
  }

  test('默认返回已启用真实模型明细（纯转发）', () async {
    final json = await getModels();
    expect(json['object'], 'list');
    final ids = (json['data'] as List)
        .map((e) => (e as Map)['id'] as String)
        .toSet();
    // 返回真实模型名，而非收敛后的虚拟档位
    expect(ids, contains('gpt-4o'));
    expect(ids, contains('text-embedding-3-small'));
    expect(ids, contains('claude-3-5-sonnet-20241022'));
    expect(ids, contains('my-custom-chat-model'));
    // 被停用的模型不出现
    expect(ids, isNot(contains('gpt-4-old')));
    expect(ids, isNot(contains('gemini-1.5-pro')));
    // 每条模型应包含扩展字段
    final gpt4o = (json['data'] as List)
        .firstWhere((e) => (e as Map)['id'] == 'gpt-4o') as Map;
    expect(gpt4o['object'], 'model');
    expect(gpt4o['provider'], 'openai');
    expect(gpt4o['owned_by'], 'openai');
    expect(gpt4o['capabilities'], ['chat', 'vision']);
  });

  test('按 provider 过滤', () async {
    final json = await getModels('?provider=anthropic');
    final data = json['data'] as List;
    expect(data.length, 1);
    expect((data.first as Map)['id'], 'claude-3-5-sonnet-20241022');
  });

  test('按 capability 过滤', () async {
    final json = await getModels('?capability=embedding');
    final data = json['data'] as List;
    expect(data.length, 1);
    expect((data.first as Map)['id'], 'text-embedding-3-small');
  });

  test('enabled=false 时包含被停用的模型', () async {
    final json = await getModels('?enabled=false');
    final ids =
        (json['data'] as List).map((e) => (e as Map)['id'] as String).toSet();
    expect(ids, contains('gemini-1.5-pro'));
    expect(ids, contains('gpt-4-old'));
    expect(ids.length, 6);
  });

  test('status=deprecated 可单独查询已下线模型', () async {
    final json = await getModels('?status=deprecated&enabled=false');
    final data = json['data'] as List;
    expect(data.length, 1);
    expect((data.first as Map)['id'], 'gpt-4-old');
    expect((data.first as Map)['status'], 'deprecated');
  });

  test('status=all 等价于不按状态过滤', () async {
    final json = await getModels('?status=all&enabled=false');
    expect((json['data'] as List).length, 6);
  });

  test('模型查询不消耗入口限流额度（连续多次均 200）', () async {
    // globalRpmLimit = 1，但 /v1/models 在限流前被拦截处理
    for (var i = 0; i < 4; i++) {
      final json = await getModels();
      expect((json['data'] as List).isNotEmpty, isTrue);
    }
  });

  test('expand=1 参数被忽略，行为与默认一致（纯转发）', () async {
    final json = await getModels('?expand=1');
    final ids = (json['data'] as List)
        .map((e) => (e as Map)['id'] as String)
        .toSet();
    // 始终返回真实模型明细，不做收敛
    expect(ids, contains('gpt-4o'));
    expect(ids, contains('text-embedding-3-small'));
    expect(ids, isNot(contains('chat-premium')));
  });
}