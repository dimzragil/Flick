import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:flick/features/player/widgets/motion_art_widget.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';

/// Apple Music-style hero art: slow Ken Burns pan/zoom with a soft
/// pulsing glow derived from the art's dominant color.
///
/// When [albumName] and [artistName] are supplied (album detail heroes), real
/// Apple Music Motion Art is played instead, falling back to the Ken Burns
/// effect whenever no motion art exists for the album.
///
/// Perf (2026-10-19): the Ken Burns loop rebuilds a full-screen
/// [Transform.scale] plus a per-frame-dynamic radial gradient every frame, so
/// it only runs while it is actually visible **and** audio is playing:
/// - app lifecycle is not resumed (backgrounded) — controller stops,
/// - another route covers this one ([ModalRoute.isCurrent] — e.g. the
///   non-opaque full player route above a detail hero) — controller stops,
/// - audio is paused — controller stops (static frame, no per-frame work),
/// - reduced-motion is enabled — never animates.
/// Every pause freezes the controller in place and every resume repeats
/// (reverse) from the frozen value, so the animation looks identical when it
/// runs — it just stops running when hidden. Gate changes are applied
/// synchronously (never via post-frame callbacks, which starve when no other
/// frame source exists), and the animated content sits in a
/// [RepaintBoundary] so per-frame repaints stay on the hero's own layer
/// instead of recompositing whatever is behind it. Route gating follows
/// [MotionArtView]'s `isCurrent` pattern so both halves of the hero pause
/// under the same conditions.
class AnimatedAlbumArt extends StatefulWidget {
  final String? imagePath;
  final String? audioSourcePath;
  final Color? dominantColor;
  final Widget? placeholder;
  final Widget? errorWidget;

  /// Album metadata enabling the edition-aware Motion Art lookup.
  final String? albumName;
  final String? artistName;
  final String? representativeSongTitle;

  /// Prefer the portrait motion-art variant (full-bleed backgrounds).
  final bool preferVertical;

  /// When false, keeps the Ken Burns effect even if album metadata is present.
  final bool motionEnabled;

  /// Test hook: replaces [PlayerService.isPlayingNotifier] as the playing
  /// signal so widget tests can drive the gate without instantiating the
  /// audio stack (same pattern as [MotionArtView]'s suppressionOverride).
  @visibleForTesting
  final ValueListenable<bool>? playingOverride;

  const AnimatedAlbumArt({
    super.key,
    this.imagePath,
    this.audioSourcePath,
    this.dominantColor,
    this.placeholder,
    this.errorWidget,
    this.albumName,
    this.artistName,
    this.representativeSongTitle,
    this.preferVertical = false,
    this.motionEnabled = true,
    this.playingOverride,
  });

  @override
  State<AnimatedAlbumArt> createState() => _AnimatedAlbumArtState();
}

class _AnimatedAlbumArtState extends State<AnimatedAlbumArt>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;

  /// False whenever the app is not resumed (backgrounded/hidden/inactive).
  bool _lifecycleActive = true;

  /// False whenever another route covers this widget's route.
  bool _routeIsCurrent = true;

  /// Latest seen system reduced-motion flag; change-detector in
  /// [didChangeDependencies] (MediaQuery changes re-run didChangeDependencies).
  bool _reducedMotion = false;

  /// Mirror of the playing signal; the gate only reacts to real changes.
  bool _lastPlaying = false;
  ValueListenable<bool>? _boundPlaying;
  bool _listeningToPlaying = false;

  /// Whether the first frame-end gate decision has run (see initState).
  bool _didInitialSync = false;

  ValueListenable<bool> get _playing =>
      widget.playingOverride ?? PlayerService().isPlayingNotifier;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 18),
    );
    // The first decision is deferred (same pattern as the pre-existing
    // implementation) because the reduced-motion flag is unavailable in
    // initState. Every later gate change applies synchronously so a stopped
    // controller is never starved behind a pending frame callback.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _lastPlaying = _playing.value;
      _updateAnimation();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _listenToPlaying();

    // Follow MotionArtView: cover/uncover via a pushed route pauses/resumes
    // through the ModalScopeStatus inherited dependency. MediaQuery changes
    // (e.g. the system reduced-motion flag) also re-run this hook.
    final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    final reducedMotion = MediaQuery.of(context).disableAnimations;
    final routeChanged = isCurrent != _routeIsCurrent;
    final motionChanged = reducedMotion != _reducedMotion;
    if (routeChanged) _routeIsCurrent = isCurrent;
    if (motionChanged) _reducedMotion = reducedMotion;
    if ((routeChanged || motionChanged) && _didInitialSync) {
      _updateAnimation();
    }
  }

  @override
  void didUpdateWidget(covariant AnimatedAlbumArt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playingOverride != widget.playingOverride) {
      _stopListeningToPlaying();
      _listenToPlaying();
      _updateAnimation();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (active == _lifecycleActive) return;
    _lifecycleActive = active;
    _updateAnimation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopListeningToPlaying();
    _controller.dispose();
    super.dispose();
  }

  void _listenToPlaying() {
    if (_listeningToPlaying) return;
    _listeningToPlaying = true;
    _boundPlaying = _playing;
    _boundPlaying!.addListener(_onPlayingChanged);
  }

  void _stopListeningToPlaying() {
    if (!_listeningToPlaying) return;
    _listeningToPlaying = false;
    _boundPlaying?.removeListener(_onPlayingChanged);
    _boundPlaying = null;
  }

  void _onPlayingChanged() {
    if (!mounted) return;
    final playing = _playing.value;
    if (playing == _lastPlaying) return;
    _lastPlaying = playing;
    _updateAnimation();
  }

  /// Applies the pause/resume decision synchronously so the controller is
  /// never left animating (or stuck stopped) waiting for a frame callback
  /// that nothing else will trigger.
  void _updateAnimation() {
    if (!mounted) return;
    _didInitialSync = true;
    final reducedMotion = MediaQuery.of(context).disableAnimations;
    final shouldAnimate =
        !reducedMotion && _lifecycleActive && _routeIsCurrent && _lastPlaying;
    if (shouldAnimate) {
      if (!_controller.isAnimating) _controller.repeat(reverse: true);
    } else {
      if (_controller.isAnimating) _controller.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = CachedImageWidget(
      imagePath: widget.imagePath,
      audioSourcePath: widget.audioSourcePath,
      fit: BoxFit.cover,
      placeholder: widget.placeholder,
      errorWidget: widget.errorWidget,
    );
    final kenBurns = ClipRect(
      // Perf (2026-10-19): every frame recomposes the scale + radial glow;
      // keep those repaints on their own layer so they don't force the
      // surrounding stack (ambient background, detail header, mini player)
      // to recomposite.
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final t = Curves.easeInOut.transform(_controller.value);
            final glow = widget.dominantColor;
            return Stack(
              fit: StackFit.expand,
              children: [
                Transform.scale(scale: 1.0 + 0.12 * t, child: child),
                if (glow != null)
                  IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          radius: 1.2,
                          colors: [
                            glow.withValues(alpha: 0.0),
                            glow.withValues(alpha: 0.12 + 0.18 * t),
                          ],
                          stops: const [0.55, 1.0],
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
          child: image,
        ),
      ),
    );

    final album = widget.albumName?.trim() ?? '';
    final artist = widget.artistName?.trim() ?? '';
    if (album.isEmpty || artist.isEmpty || !widget.motionEnabled) {
      return kenBurns;
    }

    return MotionArtView(
      title: album,
      album: album,
      artist: artist,
      albumMode: true,
      representativeSongTitle: widget.representativeSongTitle,
      preferVertical: widget.preferVertical,
      enabled: !MediaQuery.of(context).disableAnimations,
      fallback: kenBurns,
    );
  }
}
