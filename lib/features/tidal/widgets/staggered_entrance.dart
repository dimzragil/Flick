import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';

/// Plays a one-shot fade + slide entrance for a list child.
///
/// Wrap each child of a screen's main list with this widget, passing the
/// child's position as [index]. The child starts transparent, offset down by
/// [slideOffset], and eases into place after `index * delayPerIndex` (capped
/// at [maxDelay]) with a [duration]-long fade + slide.
///
/// Only children that mount while the surrounding [StaggeredEntranceWindow]
/// is open animate; children mounted later — e.g. lazy list rows that scroll
/// into view — render immediately, so the entrance is never replayed while
/// scrolling. Without a [StaggeredEntranceWindow] ancestor the entrance
/// always plays on mount.
class StaggeredEntrance extends StatefulWidget {
  const StaggeredEntrance({
    super.key,
    required this.index,
    required this.child,
    this.delayPerIndex = const Duration(milliseconds: 30),
    this.maxDelay = const Duration(milliseconds: 300),
    this.duration = const Duration(milliseconds: 200),
    this.curve = Curves.easeOut,
    this.slideOffset = const Offset(0, 0.15),
  });

  /// Position of this child in the list; drives the entrance delay.
  final int index;

  /// The list child to animate in.
  final Widget child;

  /// Delay added per [index] (`index * delayPerIndex`).
  final Duration delayPerIndex;

  /// Upper bound for the computed delay, so long lists stay snappy.
  final Duration maxDelay;

  /// Duration of the fade + slide entrance.
  final Duration duration;

  /// Curve for both the fade and the slide.
  final Curve curve;

  /// Fractional offset the child slides up from.
  final Offset slideOffset;

  @override
  State<StaggeredEntrance> createState() => _StaggeredEntranceState();
}

class _StaggeredEntranceState extends State<StaggeredEntrance> {
  bool _entranceStarted = false;
  bool _visible = false;
  Timer? _delayTimer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entranceStarted) return;
    _entranceStarted = true;

    // Skip the entrance when animations are disabled app-wide, and for
    // children that mount after the entrance window closed (scrolled into
    // view later) — they render statically instead of replaying the effect.
    if (AppConstants.animationNormal == Duration.zero ||
        !StaggeredEntranceWindow.isOpenOf(context)) {
      _visible = true;
      return;
    }

    var delay = widget.delayPerIndex * widget.index;
    if (delay > widget.maxDelay) delay = widget.maxDelay;
    _delayTimer = Timer(delay, () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedSlide(
        offset: _visible ? Offset.zero : widget.slideOffset,
        duration: widget.duration,
        curve: widget.curve,
        child: AnimatedOpacity(
          opacity: _visible ? 1.0 : 0.0,
          duration: widget.duration,
          curve: widget.curve,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Opens a one-shot entrance window for [StaggeredEntrance] descendants.
///
/// While the window is open every [StaggeredEntrance] that mounts plays its
/// entrance. Once it closes — shortly after the screen (or its content) first
/// built — children that mount later render statically, so scrolling never
/// replays the animation.
class StaggeredEntranceWindow extends StatefulWidget {
  const StaggeredEntranceWindow({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 650),
  });

  /// The screen content containing the staggered list(s).
  final Widget child;

  /// How long entrances are allowed after the first build.
  final Duration duration;

  /// Whether entrances may still play in this build context.
  ///
  /// Returns `true` when there is no [StaggeredEntranceWindow] ancestor.
  static bool isOpenOf(BuildContext context) {
    final marker = context
        .dependOnInheritedWidgetOfExactType<_StaggeredEntranceWindowMarker>();
    return marker?.open ?? true;
  }

  @override
  State<StaggeredEntranceWindow> createState() =>
      _StaggeredEntranceWindowState();
}

class _StaggeredEntranceWindowState extends State<StaggeredEntranceWindow> {
  bool _open = true;
  Timer? _closeTimer;

  @override
  void initState() {
    super.initState();
    _closeTimer = Timer(widget.duration, () {
      if (mounted && _open) setState(() => _open = false);
    });
  }

  @override
  void dispose() {
    _closeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _StaggeredEntranceWindowMarker(open: _open, child: widget.child);
  }
}

class _StaggeredEntranceWindowMarker extends InheritedWidget {
  const _StaggeredEntranceWindowMarker({
    required this.open,
    required super.child,
  });

  final bool open;

  @override
  bool updateShouldNotify(_StaggeredEntranceWindowMarker oldWidget) =>
      open != oldWidget.open;
}
