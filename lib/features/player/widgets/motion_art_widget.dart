import 'dart:async';
import 'dart:io';

import 'package:flick/core/utils/app_log.dart';
import 'package:flick/core/utils/dev_log.dart';
import 'package:flick/services/motion_art/animated_artwork_service.dart';
import 'package:flick/services/player_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Renders Apple Music Motion Art for an album while falling back to [fallback]
/// (typically the Ken Burns [AnimatedAlbumArt] or a static artwork widget).
///
/// Controllers are always created with [VideoPlayerOptions.mixWithOthers] so
/// ExoPlayer never requests audio focus and playback of the actual music via
/// just_audio is not interrupted.
///
/// Suppressed while [PlayerService.motionArtSuppressedNotifier] is set
/// (direct/exclusive bit-perfect output): a second output stream can preempt
/// the native stream on some DAPs. [fallback] renders instead.
class MotionArtView extends StatefulWidget {
  const MotionArtView({
    super.key,
    required this.title,
    required this.artist,
    required this.fallback,
    this.album,
    this.duration,
    this.enabled = true,
    this.albumMode = false,
    this.representativeSongTitle,
    this.preferVertical = false,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.suppressionOverride,
    this.serviceOverride,
    this.loadingFallback,
  });

  /// Song title, or the album name when [albumMode] is true.
  final String title;
  final String artist;
  final String? album;
  final Duration? duration;

  /// Always rendered when no video is available or [enabled] is false.
  final Widget fallback;

  /// Rendered while the first lookup is still in flight, so a static cover can
  /// wait for the motion art without visibly swapping widgets. Settles to
  /// [fallback] once the lookup concludes there is no motion art.
  final Widget? loadingFallback;

  final bool enabled;

  /// Resolve by album (edition-aware) rather than by song.
  final bool albumMode;
  final String? representativeSongTitle;

  /// Prefer the portrait motion-art variant (full-bleed backgrounds).
  final bool preferVertical;

  final BoxFit fit;
  final BorderRadius? borderRadius;

  /// Test hook: replaces [PlayerService.motionArtSuppressedNotifier].
  @visibleForTesting
  final ValueListenable<bool>? suppressionOverride;

  /// Test hook: replaces the shared [AnimatedArtworkService] instance.
  @visibleForTesting
  final AnimatedArtworkService? serviceOverride;

  @override
  State<MotionArtView> createState() => _MotionArtViewState();
}

class _MotionArtViewState extends State<MotionArtView> {
  static const Duration _debounce = Duration(milliseconds: 120);
  static const Duration _retryDelay = Duration(seconds: 35);
  static const int _maxAttempts = 4;

  static final Set<VideoPlayerController> _liveControllers = {};

  VideoPlayerController? _controller;
  bool _hasVideo = false;
  bool _settledWithoutMotion = false;
  bool _suppressed = false;
  bool _routeIsCurrent = true;
  bool _listeningToSuppression = false;
  Timer? _timer;
  Timer? _retryTimer;
  int _generation = 0;
  int _attempt = 0;

  static String _rssLabel() {
    try {
      final mb = ProcessInfo.currentRss ~/ (1024 * 1024);
      return 'rss=${mb}MB';
    } catch (_) {
      return 'rss=?';
    }
  }

  static void _logLifecycle(String message) {
    AppLog.instance.add('[MotionArt] $message', source: LogSource.dart);
  }

  ValueListenable<bool> get _suppression =>
      widget.suppressionOverride ?? PlayerService().motionArtSuppressedNotifier;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) {
      _listenToSuppression();
    }
    AnimatedArtworkService.instance.revision.addListener(_onRevisionChanged);
    _restart();
  }

  void _onRevisionChanged() {
    if (!mounted) return;
    _restart();
    setState(() {});
  }

  void _listenToSuppression() {
    if (_listeningToSuppression) return;
    _listeningToSuppression = true;
    _suppressed = _suppression.value;
    _suppression.addListener(_onSuppressionChanged);
  }

  void _stopListeningToSuppression() {
    if (!_listeningToSuppression) return;
    _listeningToSuppression = false;
    _suppression.removeListener(_onSuppressionChanged);
    _suppressed = false;
  }

  void _onSuppressionChanged() {
    final suppressed = _suppression.value;
    if (suppressed == _suppressed) return;
    _suppressed = suppressed;
    _restart();
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    if (isCurrent == _routeIsCurrent) return;
    _routeIsCurrent = isCurrent;
    _restart();
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant MotionArtView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      if (widget.enabled) {
        _listenToSuppression();
      } else {
        _stopListeningToSuppression();
      }
    }
    final changed =
        oldWidget.title != widget.title ||
        oldWidget.artist != widget.artist ||
        oldWidget.album != widget.album ||
        oldWidget.albumMode != widget.albumMode ||
        oldWidget.representativeSongTitle != widget.representativeSongTitle ||
        oldWidget.preferVertical != widget.preferVertical ||
        oldWidget.enabled != widget.enabled;
    if (changed) _restart();
  }

  @override
  void dispose() {
    AnimatedArtworkService.instance.revision.removeListener(_onRevisionChanged);
    _stopListeningToSuppression();
    _teardown();
    super.dispose();
  }

  void _teardown() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _hasVideo = false;
    _settledWithoutMotion = false;
    final controller = _controller;
    _controller = null;
    unawaited(_disposeVideo(controller));
  }

  Future<void> _disposeVideo(VideoPlayerController? controller) async {
    if (controller == null) return;
    if (_liveControllers.remove(controller)) {
      _logLifecycle('stopped active=${_liveControllers.length}');
    }
    await controller.dispose();
  }

  void _restart() {
    _teardown();
    _attempt = 0;
    _beginLoad();
  }

  void _beginLoad() {
    if (!widget.enabled || _suppressed || !_routeIsCurrent) return;
    final generation = _generation;
    _timer = Timer(_debounce, () => _loadOnce(generation));
  }

  void _scheduleRetry() {
    if (!widget.enabled || _suppressed || !_routeIsCurrent) return;
    if (_attempt >= _maxAttempts) {
      _logLifecycle('gave up after $_attempt attempt(s)');
      _settle();
      return;
    }
    _attempt++;
    _retryTimer?.cancel();
    _retryTimer = Timer(_retryDelay, () {
      if (!mounted) return;
      _beginLoad();
    });
  }

  /// Marks the lookup as concluded with no motion art, so the regular
  /// [MotionArtView.fallback] replaces [MotionArtView.loadingFallback].
  void _settle() {
    if (_settledWithoutMotion) return;
    _settledWithoutMotion = true;
    if (mounted) setState(() {});
  }

  void _logFailureOnce(String stage, Object error) {
    if (_attempt == 0) {
      _logLifecycle('$stage failed: $error');
    }
  }

  Future<void> _loadOnce(int generation) async {
    MotionArtLookup? lookup;
    try {
      final service =
          widget.serviceOverride ?? AnimatedArtworkService.instance;
      if (widget.albumMode) {
        lookup = await service.lookupAnimatedArtworkForAlbum(
          albumName: widget.album ?? widget.title,
          artist: widget.artist,
          representativeSongTitle: widget.representativeSongTitle,
        );
      } else {
        lookup = await service.lookupAnimatedArtwork(
          songTitle: widget.title,
          artist: widget.artist,
          albumName: widget.album,
          duration: widget.duration,
        );
      }
    } catch (error) {
      _logFailureOnce('lookup', error);
      devLog('[MotionArt] lookup failed: $error');
    }

    if (!mounted || generation != _generation) return;
    final artwork = lookup?.artwork;
    final url = widget.preferVertical
        ? artwork?.verticalPlaybackUrl
        : artwork?.playbackUrl;
    if (url == null) {
      if (lookup?.transient ?? true) {
        // Network hiccup, 429/503, timeout: a later attempt may still find
        // motion art, so keep showing the loading fallback and retry.
        _scheduleRetry();
      } else {
        // Definitive "no motion art": settle immediately instead of keeping a
        // static cover in the loading state through pointless retries.
        _settle();
      }
      return;
    }

    VideoPlayerController? controller;
    try {
      final uri = Uri.parse(url);
      controller = VideoPlayerController.networkUrl(
        uri,
        // boidu's `animated` field is an Apple HLS playlist; hinting the format
        // is more robust than relying on ExoPlayer's URI-extension sniffing.
        formatHint: uri.path.toLowerCase().endsWith('.m3u8')
            ? VideoFormat.hls
            : null,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      await controller.initialize();
      await controller.setLooping(true);
      await controller.setVolume(0);
      if (!mounted || generation != _generation) {
        await _disposeVideo(controller);
        return;
      }
      await controller.play();
    } catch (error) {
      _logFailureOnce('video init', error);
      devLog('[MotionArt] video init failed: $error');
      await _disposeVideo(controller);
      _scheduleRetry();
      return;
    }

    if (!mounted || generation != _generation) {
      await _disposeVideo(controller);
      return;
    }

    final previous = _controller;
    _liveControllers.add(controller);
    _logLifecycle(
      'started active=${_liveControllers.length} ${_rssLabel()} '
      '${widget.albumMode ? 'album="${widget.album ?? widget.title}"' : 'song="${widget.title}"'}',
    );
    setState(() {
      _controller = controller;
      _hasVideo = true;
    });
    _attempt = 0;
    await _disposeVideo(previous);
  }

  @override
  Widget build(BuildContext context) {
    if (_suppressed || !widget.enabled) return widget.fallback;
    final controller = _controller;
    if (!_hasVideo || controller == null || !controller.value.isInitialized) {
      final loading = widget.loadingFallback;
      if (_settledWithoutMotion || loading == null) return widget.fallback;
      return loading;
    }

    final size = controller.value.size;
    if (size.width <= 0 || size.height <= 0) return widget.fallback;

    Widget video = SizedBox.expand(
      child: FittedBox(
        fit: widget.fit,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: VideoPlayer(controller),
        ),
      ),
    );
    final radius = widget.borderRadius;
    if (radius != null) {
      video = ClipRRect(borderRadius: radius, child: video);
    }
    return video;
  }
}
