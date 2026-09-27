import 'dart:async';

import 'package:flutter/material.dart';

class RotatingWidget extends StatefulWidget {
  final Duration duration;
  final bool spinning;
  final bool reverse;
  final Widget child;

  const RotatingWidget({
    required this.duration,
    this.spinning = true,
    this.reverse = false,
    required this.child,
    super.key,
  });

  @override
  State<RotatingWidget> createState() => RotatingWidgetState();
}

class RotatingWidgetState extends State<RotatingWidget> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;
  bool _foreground = true;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled && !MediaQuery.disableAnimationsOf(context) && (ModalRoute.isCurrentOf(context) ?? true);
    _synchronize();
  }

  @override
  void didUpdateWidget(covariant RotatingWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.stop();
      _controller.duration = widget.duration;
    }
    _synchronize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _synchronize();
  }

  void _synchronize() {
    if (widget.spinning && _visible && _foreground) {
      if (!_controller.isAnimating) unawaited(_controller.repeat());
    } else {
      // Stop the ticker, not just painting; resuming continues from this angle.
      _controller.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: widget.reverse ? ReverseAnimation(_controller) : _controller,
      child: RepaintBoundary(child: widget.child),
    );
  }
}
