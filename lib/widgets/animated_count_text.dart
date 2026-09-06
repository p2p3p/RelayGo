import 'package:flutter/material.dart';

/// 秒表式数字滚动组件（Count-Up Animation）
///
/// 数值从 [value] 变化时，从旧值平滑滚动递增到新值，
/// 模拟秒表计数的效果。支持自定义格式化函数（如 1.2K / 3.4M）。
class AnimatedCountText extends StatefulWidget {
  const AnimatedCountText({
    Key? key,
    required this.value,
    this.style,
    this.duration = const Duration(milliseconds: 650),
    this.curve = Curves.easeOut,
    this.formatter,
  }) : super(key: key);

  /// 目标数值
  final int value;

  /// 文本样式
  final TextStyle? style;

  /// 滚动动画时长
  final Duration duration;

  /// 缓动曲线
  final Curve curve;

  /// 格式化函数（默认原样显示整数）
  final String Function(int value)? formatter;

  @override
  State<AnimatedCountText> createState() => _AnimatedCountTextState();
}

class _AnimatedCountTextState extends State<AnimatedCountText>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  late int _from;
  late int _to;

  @override
  void initState() {
    super.initState();
    _from = widget.value;
    _to = widget.value;
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    )..addListener(() => setState(() {}));
    _animation = _buildTween();
  }

  @override
  void didUpdateWidget(covariant AnimatedCountText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _from = _displayedValue();
      _to = widget.value;
      _controller.duration = widget.duration;
      _animation = _buildTween();
      // 从当前显示值滚动到新值
      _controller.forward(from: 0);
    }
  }

  Animation<double> _buildTween() {
    return CurvedAnimation(
      parent: _controller,
      curve: widget.curve,
    ).drive(Tween<double>(begin: _from.toDouble(), end: _to.toDouble()));
  }

  int _displayedValue() {
    // 控制器未运行（首次）或已结束：返回目标值
    if (!_controller.isAnimating) return _to;
    return _animation.value.round();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _controller.isAnimating
        ? _animation.value.round()
        : _to;
    final text =
        widget.formatter?.call(shown) ?? '$shown';
    return Text(
      text,
      style: widget.style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.right,
    );
  }
}
