import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:relaygo/services/key_manager.dart';
import 'package:relaygo/services/rate_limiter.dart';
import 'package:relaygo/utils/encryption.dart';

void main() {
  late KeyManager keyManager;

  setUpAll(() async {
    final tmp = Directory.systemTemp.createTempSync('rl_test');
    Hive.init(tmp.path);
    await Hive.openBox('api_keys_rl');
    keyManager = KeyManager(Hive.box('api_keys_rl'));
    EncryptionUtil.init(EncryptionUtil.generateMasterKeyBase64());
  });

  group('入口限流（IP / 全局）', () {
    test('单 IP 超过阈值返回 429', () {
      final rl = RateLimiter(
        enabled: true,
        requestsPerMinutePerIp: 2,
        globalRequestsPerMinute: 0,
      );
      expect(rl.checkInbound('1.2.3.4').allowed, isTrue);
      rl.recordInbound('1.2.3.4');
      expect(rl.checkInbound('1.2.3.4').allowed, isTrue);
      rl.recordInbound('1.2.3.4');
      final third = rl.checkInbound('1.2.3.4');
      expect(third.allowed, isFalse);
      expect(third.dimension, 'ip');
    });

    test('全局速率超过阈值拒绝', () {
      final rl = RateLimiter(
        enabled: true,
        requestsPerMinutePerIp: 0,
        globalRequestsPerMinute: 1,
      );
      expect(rl.checkInbound('9.9.9.9').allowed, isTrue);
      rl.recordInbound('9.9.9.9');
      final r = rl.checkInbound('9.9.9.9');
      expect(r.allowed, isFalse);
      expect(r.dimension, 'global');
    });

    test('维度拒绝计数进入 denials', () {
      final rl = RateLimiter(
        enabled: true,
        requestsPerMinutePerIp: 1,
      );
      rl.recordInbound('1.1.1.1');
      rl.checkInbound('1.1.1.1');
      rl.recordInbound('1.1.1.1');
      rl.checkInbound('1.1.1.1');
      expect(rl.denials['ip'], greaterThan(0));
    });
  });

  group('key 级限流（RPM 令牌桶 / TPM 滑动窗口）', () {
    test('超过 key 的 RPM 被限流', () async {
      final key = await keyManager.createKey(
        provider: 'openai',
        plainKey: 'sk-rl',
        name: 'rl-key',
        maxRpm: 2,
      );
      final rl = RateLimiter(enabled: true, burstMultiplier: 1.0);
      // consumeKey 实际扣令牌（探测用 checkKey）
      expect(rl.checkKey(key).allowed, isTrue);
      rl.consumeKey(key);
      expect(rl.checkKey(key).allowed, isTrue);
      rl.consumeKey(key);
      // 已耗尽 2 个令牌（容量=2*1.0），第三次应拒绝
      final r = rl.checkKey(key);
      expect(r.allowed, isFalse);
      expect(r.dimension, 'key_rpm');
    });

    test('TPM 滑动窗口超限拒绝', () async {
      final key = await keyManager.createKey(
        provider: 'openai',
        plainKey: 'sk-tpm',
        name: 'tpm-key',
      );
      final rl = RateLimiter(enabled: true, tokensPerMinutePerKey: 10);
      rl.recordTokens(key, 6);
      expect(rl.checkKey(key).allowed, isTrue);
      rl.recordTokens(key, 6); // 累计 12 >= 10
      final r = rl.checkKey(key);
      expect(r.allowed, isFalse);
      expect(r.dimension, 'key_tpm');
    });

    test('不启用限流一律放行', () async {
      final key = await keyManager.createKey(
        provider: 'openai',
        plainKey: 'sk-off',
        name: 'off-key',
        maxRpm: 1,
      );
      final rl = RateLimiter(enabled: false);
      expect(rl.checkInbound('1.1.1.1').allowed, isTrue);
      expect(rl.checkKey(key).allowed, isTrue);
    });
  });

  group('自适应 TPM 挡板（消除上游 TPM 限流）', () {
    test('识别可恢复 TPM 限流：429 + 关键词', () {
      expect(
        RateLimiter.isRecoverableTpmLimit(
            429, '{"error":{"type":"tokens_per_minute exceeded"}}'),
        isTrue,
      );
      expect(
        RateLimiter.isRecoverableTpmLimit(
            429, '{"error":{"type":"inference_tpm limit reached"}}'),
        isTrue,
      );
      expect(
        RateLimiter.isRecoverableTpmLimit(429, '{"error":"some other thing"}'),
        isFalse, // 429 但无 TPM 关键词 → 视为不可恢复（配额/封禁类）
      );
      expect(RateLimiter.isRecoverableTpmLimit(503, 'tpm'), isFalse);
    });

    test('上游 429 反馈会下调学到的 TPM 上限并生效', () async {
      final key = await keyManager.createKey(
        provider: 'openai',
        plainKey: 'sk-ada',
        name: 'ada-key',
      );
      // 未配置硬限（tokensPerMinutePerKey=0），自适应挡板开启
      final rl = RateLimiter(enabled: true, adaptiveTpmEnabled: true, tokensPerMinutePerKey: 0);
      // 模拟：窗口用量 5000 token/分钟（真实 TPM 量级，须高于 minLearnedTpm 下限）
      rl.recordTokens(key, 5000, model: 'gpt-4o');
      rl.recordUpstreamTpmLimit(key, 'gpt-4o', 5000); // 乘性减：5000*0.85=4250
      // 现在窗口内累计 5000 已超过学习阈值 4250*0.95≈4037，应被挡板拒绝
      expect(rl.checkKey(key, model: 'gpt-4o').allowed, isFalse);
      // 换个模型不受影响（学习按 key+model 隔离）
      expect(rl.checkKey(key, model: 'claude-3').allowed, isTrue);
    });

    test('resetLearn 清除某个 key 的学习状态', () async {
      final key = await keyManager.createKey(
        provider: 'openai',
        plainKey: 'sk-reset',
        name: 'reset-key',
      );
      final rl = RateLimiter(enabled: true, adaptiveTpmEnabled: true, tokensPerMinutePerKey: 0);
      rl.recordTokens(key, 5000, model: 'gpt-4');
      rl.recordUpstreamTpmLimit(key, 'gpt-4', 5000);
      expect(rl.checkKey(key, model: 'gpt-4').allowed, isFalse);
      rl.resetLearn(key);
      expect(rl.checkKey(key, model: 'gpt-4').allowed, isTrue);
    });

    test('关闭自适应后可绕过挡板（不学习不拦截）', () async {
      final key = await keyManager.createKey(
        provider: 'openai',
        plainKey: 'sk-adapt-off',
        name: 'adapt-off',
      );
      // 关闭后不应学习、不应挡板
      final rl = RateLimiter(enabled: true, adaptiveTpmEnabled: false);
      rl.recordTokens(key, 1000, model: 'gpt-4');
      rl.recordUpstreamTpmLimit(key, 'gpt-4', 1000); // 未开启 → 不生效
      expect(rl.checkKey(key, model: 'gpt-4').allowed, isTrue);
    });
  });

  group('自适应 QPS/RPM 挡板（应对上游请求数限流）', () {
    test('识别可恢复 QPS/RPM 限流：429 + requests/rpm 关键词', () {
      expect(
        RateLimiter.isRecoverableQpsLimit(
            429, '{"error":{"code":"rate_limit_exceeded"}}'),
        isTrue,
      );
      expect(
        RateLimiter.isRecoverableQpsLimit(
            429, '{"error":"requests per minute limit exceeded"}'),
        isTrue,
      );
      expect(
        RateLimiter.isRecoverableQpsLimit(429, '{"error":"some other thing"}'),
        isFalse,
      );
      expect(RateLimiter.isRecoverableQpsLimit(503, 'rpm'), isFalse);
    });

    test('上游 QPS 429 学习下调后，未配置硬限的 key 也会被软挡板拦截', () async {
      final key = await keyManager.createKey(
        provider: 'openai',
        plainKey: 'sk-qps',
        name: 'qps-key',
      );
      final rl = RateLimiter(enabled: true, adaptiveQpsEnabled: true);
      // 默认 maxRpm=0（不限）：未学习前应放行
      expect(rl.effectiveRpm(key), 0);
      expect(rl.checkKey(key).allowed, isTrue);
      // 撞墙：首次学习起点 30 → ×0.7 = 21
      rl.recordUpstreamQpsLimit(key);
      expect(rl.learnedQpm(key), 21);
      // 生效上限 = floor(21 × 0.95) = 19
      expect(rl.effectiveRpm(key), 19);
      // 短时间内连续消耗：突发容量有限，最终必然触顶被拒
      var allowed = 0;
      for (var i = 0; i < 40; i++) {
        if (rl.consumeKey(key)) allowed++;
      }
      expect(allowed, greaterThan(0));
      expect(allowed, lessThan(40));
      expect(rl.checkKey(key).allowed, isFalse);
    });

    test('未撞过墙的 key 不会被凭空建立学习上限', () async {
      final key = await keyManager.createKey(
        provider: 'openai',
        plainKey: 'sk-qps-none',
        name: 'qps-none-key',
      );
      final rl = RateLimiter(enabled: true, adaptiveQpsEnabled: true);
      rl.noteQpsHealthy(key); // 无学习值 → 不建立挡板
      expect(rl.learnedQpm(key), isNull);
      expect(rl.effectiveRpm(key), 0);
      expect(rl.checkKey(key).allowed, isTrue);
    });

    test('关闭自适应 QPS 后不学习、不拦截', () async {
      final key = await keyManager.createKey(
        provider: 'openai',
        plainKey: 'sk-qps-off',
        name: 'qps-off-key',
      );
      final rl = RateLimiter(enabled: true, adaptiveQpsEnabled: false);
      rl.recordUpstreamQpsLimit(key); // 未开启 → 不学习
      expect(rl.learnedQpm(key), isNull);
      expect(rl.effectiveRpm(key), 0);
      expect(rl.checkKey(key).allowed, isTrue);
    });

    test('配置硬上限时学习值可进一步收紧生效速率', () async {
      final key = await keyManager.createKey(
        provider: 'openai',
        plainKey: 'sk-qps-cfg',
        name: 'qps-cfg-key',
        maxRpm: 100,
      );
      final rl = RateLimiter(enabled: true, adaptiveQpsEnabled: true);
      expect(rl.effectiveRpm(key), 100); // 未学习：以配置为准
      // 学习值需先大于配置才不收紧；连续撞墙把它压到配置以下
      for (var i = 0; i < 20; i++) {
        rl.recordUpstreamQpsLimit(key);
      }
      final learned = rl.learnedQpm(key)!;
      expect(learned, lessThan(100));
      // 收紧后生效速率 = floor(learned × 0.95)，严格低于配置
      expect(rl.effectiveRpm(key), (learned * 0.95).floor());
    });
  });

  test('snapshot 反映当前观测值', () async {
    final key = await keyManager.createKey(
      provider: 'openai',
      plainKey: 'sk-snap',
      name: 'snap-key',
      maxRpm: 5,
    );
    final rl = RateLimiter(
      enabled: true,
      requestsPerMinutePerIp: 3,
      globalRequestsPerMinute: 4,
      tokensPerMinutePerKey: 100,
    );
    rl.recordInbound('2.2.2.2');
    rl.consumeKey(key);
    final snap = rl.snapshot();
    expect(snap['enabled'], isTrue);
    expect(snap['tracked_ips'], 1);
    expect(snap['tracked_keys'], 1);
    expect(snap['limits']['requests_per_minute_per_ip'], 3);
  });
}
