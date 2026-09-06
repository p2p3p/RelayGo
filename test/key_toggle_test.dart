import 'package:flutter_test/flutter_test.dart';
import 'package:relaygo/models/api_key.dart';

void main() {
  group('KeyStatus.toggledStatus（点击卡片的启用/禁用切换语义）', () {
    test('active 点击 → 禁用 inactive', () {
      expect(KeyStatus.active.toggledStatus(), KeyStatus.inactive);
    });

    test('inactive 点击 → 启用 active（二态互切）', () {
      expect(KeyStatus.inactive.toggledStatus(), KeyStatus.active);
    });

    test('error（无效冷却中）点击 → 禁用 inactive，而不是被切回 active', () {
      // 修复的 bug：过去 error 状态点击会被切成 active（启用），导致禁用不生效
      expect(KeyStatus.error.toggledStatus(), KeyStatus.inactive);
    });

    test('exhausted（额度用尽）点击 → 禁用 inactive', () {
      // 同 error，用了一段时间变成用尽后仍能一键禁用
      expect(KeyStatus.exhausted.toggledStatus(), KeyStatus.inactive);
    });

    test('从 error 一次点击进入 inactive 后再点才恢复 active（稳定的二态）', () {
      expect(KeyStatus.error.toggledStatus().toggledStatus(),
          KeyStatus.active);
    });
  });
}
