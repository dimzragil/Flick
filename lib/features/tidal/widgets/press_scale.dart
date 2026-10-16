import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';

/// Scales [child] down slightly while the user presses on it.
///
/// Transform-only press feedback (no layout) meant to wrap *outside* an
/// existing [InkWell] / [ListTile] so the ripple keeps working. The pressed
/// look starts on the raw touch-down — so even quick taps get feedback — and
/// is dropped on lift, pointer cancel, or as soon as the gesture turns into
/// a drag or long-press.
///
/// The animated transform sits inside a [RepaintBoundary], so pressing a
/// card never repaints its neighbours at 60/120fps.
class PressScale extends StatefulWidget {
  const PressScale({
    super.key,
    required this.child,
    this.pressedScale = 0.97,
    this.duration = const Duration(milliseconds: 100),
    this.curve = Curves.easeOut,
  });

  /// The tappable content, e.g. a [Material] + [InkWell] pair.
  final Widget child;

  /// Scale applied while the child is pressed.
  final double pressedScale;

  /// Duration of one leg of the scale animation.
  final Duration duration;

  /// Curve of the scale animation.
  final Curve curve;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _pressed = false;
  int? _pointer;
  Offset? _downPosition;

  Duration get _duration =>
      AppConstants.animationNormal == Duration.zero
      ? Duration.zero
      : widget.duration;

  void _press() {
    if (_pressed) return;
    setState(() => _pressed = true);
  }

  void _release() {
    _pointer = null;
    _downPosition = null;
    if (!_pressed) return;
    setState(() => _pressed = false);
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_pointer != null) return; // Only the first pointer drives the press.
    _pointer = event.pointer;
    _downPosition = event.position;
    _press();
  }

  void _onPointerMove(PointerMoveEvent event) {
    final start = _downPosition;
    if (event.pointer != _pointer || start == null) return;
    // The pointer travelled far enough to become a drag (e.g. a list scroll),
    // so the card is no longer pressed — drop the look immediately instead of
    // waiting for the gesture arena to resolve.
    if ((event.position - start).distance > kTouchSlop) {
      _release();
    }
  }

  void _onPointerEnd(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _release();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerEnd,
      onPointerCancel: _onPointerEnd,
      child: GestureDetector(
        // The inner InkWell still wins the tap, but when the tap loses the
        // arena (long-press, drag) there is no pointer-up to listen for, so
        // release here too.
        onTapCancel: _release,
        child: RepaintBoundary(
          child: AnimatedScale(
            scale: _pressed ? widget.pressedScale : 1.0,
            duration: _duration,
            curve: widget.curve,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
