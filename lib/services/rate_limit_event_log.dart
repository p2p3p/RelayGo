import 'dart:async';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:relaygo/config/constants.dart';
import 'package:relaygo/models/rate_limit_event.dart';

/// 限流切换 Key 事件日志服务
///
/// - 内存保留最近若干条并提供实时流，UI 可即时刷新；
/// - 事件同步写入 Hive（量级远小于请求日志，无需批量合并）；
/// - 超过容量上限时丢弃最旧记录。
class RateLimitEventLog {
  final Box box;
  final int cap;

  final StreamController<RateLimitEvent> _controller =
      StreamController<RateLimitEvent>.broadcast();
  final List<RateLimitEvent> _memory = []; // 最新在前

  RateLimitEventLog(this.box, {this.cap = Constants.rateLimitEventCap}) {
    final loaded = all();
    _memory.addAll(loaded.take(cap));
  }

  Stream<RateLimitEvent> get stream => _controller.stream;

  List<RateLimitEvent> get recent => List.unmodifiable(_memory);

  int get count => _memory.length;

  /// 记录一条限流切换事件（入内存 + 持久化 + 广播）
  void add(RateLimitEvent event) {
    _memory.insert(0, event);
    if (_memory.length > cap) _memory.removeLast();
    if (!_controller.isClosed) _controller.add(event);
    unawaited(_persist(event));
  }

  Future<void> _persist(RateLimitEvent event) async {
    // 超出上限时先删除最旧一条，保证容量稳定
    if (box.length >= cap) {
      final oldest = box.keys.first;
      await box.delete(oldest);
    }
    await box.put(event.id, event.toJson());
  }

  /// 全部事件（最新在前）
  List<RateLimitEvent> all() {
    final list = box.values
        .whereType<Map>()
        .map((m) => RateLimitEvent.fromJson(Map<String, dynamic>.from(m)))
        .toList();
    list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return list;
  }

  /// 清空全部事件
  Future<void> clear() async {
    _memory.clear();
    await box.clear();
  }

  void dispose() {
    _controller.close();
  }
}