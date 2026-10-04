import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/models/playback_state.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/audio_engine.dart';
import 'package:flick/core/utils/dev_log.dart';

typedef AndroidAudioSourceBuilder =
    Future<just_audio.AudioSource> Function(Song track);
typedef AndroidPlaylistProvider = List<Song> Function();
typedef AndroidPlayerProvider = Future<just_audio.AudioPlayer> Function();
typedef AndroidPlayerConfigurator =
    Future<void> Function(just_audio.AudioPlayer player);
typedef AndroidEngineDisposer = Future<void> Function();
typedef AndroidTrackSyncBlocker = bool Function();
typedef AndroidTrackIgnorePredicate = bool Function(Song track);
typedef AndroidFastStartPredicate = bool Function();
typedef AndroidCrossfadeConfigProvider = AndroidCrossfadeConfig Function();
typedef AndroidNextSongProvider = Song? Function();
typedef AndroidTrackAdvancedCallback = void Function(Song track);

/// Crossfade curve applied to the outgoing/incoming volume ramps.
enum AndroidCrossfadeCurve {
  equalPower,
  linear,
  squareRoot,
  sCurve,
}

/// Live snapshot of crossfade settings consumed by [AndroidAudioEngine].
class AndroidCrossfadeConfig {
  const AndroidCrossfadeConfig({
    required this.enabled,
    required this.durationSecs,
    required this.curve,
  });

  final bool enabled;
  final double durationSecs;
  final AndroidCrossfadeCurve curve;

  static const disabled = AndroidCrossfadeConfig(
    enabled: false,
    durationSecs: 3.0,
    curve: AndroidCrossfadeCurve.equalPower,
  );
}

/// Incoming-track volume fraction (0..1) at ramp progress [p] (0..1).
/// The outgoing fraction is [crossfadeInVolume] evaluated at `(1 - p)`, which
/// keeps every curve symmetric (equal-power satisfies `out^2 + in^2 == 1`).
@visibleForTesting
double crossfadeInVolume(AndroidCrossfadeCurve curve, double p) {
  final c = p.clamp(0.0, 1.0).toDouble();
  switch (curve) {
    case AndroidCrossfadeCurve.equalPower:
      return math.sin(c * math.pi / 2);
    case AndroidCrossfadeCurve.linear:
      return c;
    case AndroidCrossfadeCurve.squareRoot:
      return math.sqrt(c);
    case AndroidCrossfadeCurve.sCurve:
      return c * c * (3 - 2 * c);
  }
}

/// Pure trigger predicate: should a crossfade be armed given the current
/// playback position? Extracted so it can be unit-tested without a player.
@visibleForTesting
bool shouldArmCrossfade({
  required bool enabled,
  required Duration duration,
  required Duration position,
  required double fadeSecs,
}) {
  if (!enabled || fadeSecs <= 0) return false;
  if (duration.inMilliseconds <= 0) return false;
  final fadeMs = (fadeSecs * 1000).round();
  // A track shorter than (or equal to) the fade has no solo segment to fade
  // out of — let it end naturally.
  if (duration.inMilliseconds <= fadeMs) return false;
  final remaining = duration - position;
  return remaining.inMilliseconds <= fadeMs;
}

@visibleForTesting
bool shouldUseFastStartCurrentTrackOnly({
  required bool allowFastStart,
  required bool loadedSingleTrackOnly,
  required bool sequenceIsEmpty,
  required int playlistLength,
}) {
  return allowFastStart &&
      (loadedSingleTrackOnly || sequenceIsEmpty) &&
      playlistLength > AndroidAudioEngine.fastStartPlaylistThreshold;
}

@visibleForTesting
bool shouldExitSingleTrackMode({
  required bool loadedSingleTrackOnly,
  required int playerSequenceLength,
}) {
  return loadedSingleTrackOnly && playerSequenceLength > 1;
}

/// Playback failure details surfaced from just_audio's `errorStream`.
class AndroidPlaybackError {
  const AndroidPlaybackError({
    required this.code,
    required this.message,
    this.index,
  });

  final int code;
  final String message;
  final int? index;
}

class AndroidAudioEngine implements AudioEngine {
  AndroidAudioEngine({
    required AndroidPlayerProvider playerProvider,
    required AndroidAudioSourceBuilder sourceBuilder,
    required AndroidPlaylistProvider playlistProvider,
    required AndroidPlayerConfigurator configurePlayer,
    required AndroidEngineDisposer disposeEngine,
    required AndroidTrackSyncBlocker shouldSuppressTrackSync,
    required AndroidTrackIgnorePredicate shouldIgnoreTrack,
    required AndroidFastStartPredicate shouldFastStartCurrentTrackOnly,
    AndroidCrossfadeConfigProvider? crossfadeConfigProvider,
    AndroidNextSongProvider? onNextSong,
    AndroidTrackAdvancedCallback? onTrackAdvanced,
  }) : _playerProvider = playerProvider,
       _sourceBuilder = sourceBuilder,
       _playlistProvider = playlistProvider,
       _configurePlayer = configurePlayer,
       _disposeEngine = disposeEngine,
       _shouldSuppressTrackSync = shouldSuppressTrackSync,
       _shouldIgnoreTrack = shouldIgnoreTrack,
       _shouldFastStartCurrentTrackOnly = shouldFastStartCurrentTrackOnly,
       _crossfadeConfigProvider = crossfadeConfigProvider ??
           (() => AndroidCrossfadeConfig.disabled),
       _onNextSong = onNextSong,
       _onTrackAdvanced = onTrackAdvanced;

  final AndroidPlayerProvider _playerProvider;
  final AndroidAudioSourceBuilder _sourceBuilder;
  final AndroidPlaylistProvider _playlistProvider;
  final AndroidPlayerConfigurator _configurePlayer;
  final AndroidEngineDisposer _disposeEngine;
  final AndroidTrackSyncBlocker _shouldSuppressTrackSync;
  final AndroidTrackIgnorePredicate _shouldIgnoreTrack;
  final AndroidFastStartPredicate _shouldFastStartCurrentTrackOnly;
  final AndroidCrossfadeConfigProvider _crossfadeConfigProvider;
  final AndroidNextSongProvider? _onNextSong;
  final AndroidTrackAdvancedCallback? _onTrackAdvanced;

  final StreamController<PlaybackState> _controller =
      StreamController<PlaybackState>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  just_audio.AudioPlayer? _player;
  PlaybackState _state = PlaybackState.empty(AudioEngineType.normalAndroid);
  Song? _loadedTrack;
  List<String> _playlistSignature = const <String>[];
  bool _awaitingInitialSeek = false;
  bool _loadedSingleTrackOnly = false;
  // player sequence index -> playlist index (kept in sync by the
  // background fill so _resolveTrack maps player indices back to songs).
  List<int> _childPlaylistIndices = const [];
  bool _isBackgroundFilling = false;
  int _fillGeneration = 0;

  // Crossfade state. [_player] is always the currently-audible/active player;
  // [_secondary] is the idle slot reused as the incoming player on each fade.
  // On a crossfade the two swap roles (ping-pong), so both stay attached but
  // only the active one's stream emissions are forwarded.
  just_audio.AudioPlayer? _secondary;
  Timer? _crossfadeTimer;
  bool _crossfadeArmed = false;
  bool _sinkNeedsRearmOnPlay = false;
  Future<void>? _rearmInFlight;
  double _rampUserVolume = 1.0;
  Duration _rampElapsed = Duration.zero;
  Duration _rampTotal = Duration.zero;
  AndroidCrossfadeCurve _rampCurve = AndroidCrossfadeCurve.equalPower;

  VoidCallback? onTrackEnded;
  void Function(AndroidPlaybackError details)? onPlaybackError;

  static const int fastStartPlaylistThreshold = 24;
  static const Duration _rampTick = Duration(milliseconds: 20);

  @override
  Stream<PlaybackState> get playbackStateStream => _controller.stream;

  Future<just_audio.AudioPlayer> _ensurePlayer() async {
    final existing = _player;
    if (existing != null) return existing;
    final player = await _playerProvider();
    _player = player;
    _attachListeners(player);
    return player;
  }

  Future<just_audio.AudioPlayer> _ensureSecondary() async {
    final existing = _secondary;
    if (existing != null) return existing;
    final player = just_audio.AudioPlayer();
    _secondary = player;
    _attachListeners(player);
    await player.setVolume(0);
    await player.setLoopMode(just_audio.LoopMode.off);
    return player;
  }

  void _attachListeners(just_audio.AudioPlayer player) {
    _subscriptions.add(
      player.playerStateStream.listen((state) {
        if (!identical(player, _player)) return;
        _emit(_state.copyWith(isPlaying: state.playing));
      }),
    );

    _subscriptions.add(
      player.playbackEventStream.listen((event) {
        if (!identical(player, _player)) return;
        final nextDuration = event.duration ?? _state.duration;
        _emit(
          _state.copyWith(
            position: event.updatePosition,
            bufferedPosition: event.bufferedPosition,
            duration: nextDuration,
          ),
        );
        _syncTrackFromIndex(player.currentIndex);
      }),
    );

    _subscriptions.add(
      player.positionStream.listen((pos) {
        if (!identical(player, _player)) return;
        _emit(_state.copyWith(position: pos));
        _syncTrackFromIndex(player.currentIndex);
        _maybeArmCrossfade(player, pos);
      }),
    );

    _subscriptions.add(
      player.bufferedPositionStream.listen((pos) {
        if (!identical(player, _player)) return;
        _emit(_state.copyWith(bufferedPosition: pos));
      }),
    );

    _subscriptions.add(
      player.durationStream.listen((dur) {
        if (!identical(player, _player)) return;
        if (dur == null) return;
        _emit(_state.copyWith(duration: dur));
      }),
    );

    _subscriptions.add(
      player.sequenceStateStream.listen((sequenceState) {
        if (!identical(player, _player)) return;
        _syncTrackFromIndex(sequenceState.currentIndex);
      }),
    );

    _subscriptions.add(
      player.currentIndexStream.listen((index) {
        if (!identical(player, _player)) return;
        _syncTrackFromIndex(index);
      }),
    );

    _subscriptions.add(
      player.processingStateStream.listen((state) {
        if (!identical(player, _player)) return;
        if (state == just_audio.ProcessingState.completed) {
          onTrackEnded?.call();
        }
      }),
    );

    _subscriptions.add(
      player.errorStream.listen((error) {
        if (!identical(player, _player)) return;
        devLog(
          '[Playback] Android player error: '
          'code=${error.code} message=${error.message} index=${error.index} '
          'trackId=${_loadedTrack?.id} '
          'trackFileType=${_loadedTrack?.fileType} '
          'trackTitle=${_loadedTrack?.title}',
        );
        final message = error.message ?? 'Unknown playback error';
        _emit(_state.copyWith(errorMessage: message));
        onPlaybackError?.call(
          AndroidPlaybackError(
            code: error.code,
            message: message,
            index: error.index,
          ),
        );
      }),
    );
  }

  void _syncTrackFromIndex(int? index) {
    _syncPlaylistStateFromPlayer();
    if (_shouldSuppressTrackSync()) return;
    if (_awaitingInitialSeek) return;
    final nextTrack = _resolveTrack(index);
    if (nextTrack != null && _shouldIgnoreTrack(nextTrack)) {
      return;
    }
    if (nextTrack == _state.currentTrack) return;
    _loadedTrack = nextTrack ?? _loadedTrack;
    _emit(
      _state.copyWith(
        currentTrack: nextTrack,
        position: Duration.zero,
        bufferedPosition: Duration.zero,
        duration: nextTrack?.duration ?? Duration.zero,
      ),
    );
  }

  void _syncPlaylistStateFromPlayer() {
    final player = _player;
    if (player == null) return;

    if (shouldExitSingleTrackMode(
      loadedSingleTrackOnly: _loadedSingleTrackOnly,
      playerSequenceLength: player.sequence.length,
    )) {
      _loadedSingleTrackOnly = false;
      _playlistSignature = _playlistProvider()
          .map((song) => song.id)
          .toList(growable: false);
    } else if (player.sequence.isEmpty) {
      _playlistSignature = const <String>[];
    }
  }

  Song? _resolveTrack(int? index) {
    if (_loadedSingleTrackOnly) {
      return _loadedTrack;
    }
    if (index == null) return _loadedTrack;
    // During a background playlist fill, the player's sequence may hold only
    // the tapped track (index 0) plus whichever children have been inserted
    // so far; map the sequence index back to the playlist index.
    if (_childPlaylistIndices.isNotEmpty) {
      if (index < 0 || index >= _childPlaylistIndices.length) {
        return _loadedTrack;
      }
      final mapped = _childPlaylistIndices[index];
      final playlist = _playlistProvider();
      if (mapped < 0 || mapped >= playlist.length) {
        return _loadedTrack;
      }
      return playlist[mapped];
    }
    final playlist = _playlistProvider();
    if (index < 0 || index >= playlist.length) {
      return _loadedTrack;
    }
    return playlist[index];
  }

  Future<void> _fillPlaylistBackground(
    just_audio.ConcatenatingAudioSource concat,
    List<Song> playlist,
    int tappedIndex,
    int gen,
  ) async {
    try {
      for (var j = 0; j < playlist.length; j++) {
        if (j == tappedIndex) continue;
        if (gen != _fillGeneration) return;
        just_audio.AudioSource src;
        try {
          src = await _sourceBuilder(
            playlist[j],
          ).timeout(const Duration(seconds: 20));
        } catch (_) {
          // Index-preserving placeholder; the engine error path skips it if
          // reached.
          src = just_audio.AudioSource.uri(Uri.parse(''));
        }
        if (gen != _fillGeneration) return;
        try {
          await concat.insert(j, src);
        } catch (_) {
          // concat replaced by a newer load — abort quietly.
          return;
        }
        _childPlaylistIndices.insert(j, j);
      }
    } finally {
      if (gen == _fillGeneration) {
        _isBackgroundFilling = false;
      }
    }
  }

  void _emit(PlaybackState next) {
    if (next == _state) return;
    _state = next;
    _controller.add(next);
  }

  @override
  Future<void> load(Song track) async {
    _sinkNeedsRearmOnPlay = false;
    _emit(_state.copyWith(clearError: true));
    await _cancelCrossfade();
    final player = await _ensurePlayer();
    final playlist = _playlistProvider();
    var index = playlist.indexWhere((song) => song.id == track.id);
    if (index < 0) {
      index = 0;
    }

    final nextSignature = playlist
        .map((song) => song.id)
        .toList(growable: false);
    final canReusePlaylist =
        _playlistSignature.isNotEmpty &&
        listEquals(_playlistSignature, nextSignature) &&
        !_isBackgroundFilling;

    _loadedTrack = track;
    await _configurePlayer(player);

    final cfg = _crossfadeConfigProvider();
    if (cfg.enabled) {
      // Crossfade needs a single-track source so the engine can intercept the
      // tail; a ConcatenatingAudioSource would auto-advance with a hard cut.
      devLog(
        '[Playback] Android load(${track.id}) single-track (crossfade)',
      );
      _awaitingInitialSeek = true;
      try {
        final source = await _sourceBuilder(track);
        await player.setAudioSource(source, preload: true);
        await player.seek(Duration.zero);
      } finally {
        _awaitingInitialSeek = false;
      }
      _loadedSingleTrackOnly = true;
      _playlistSignature = const <String>[];
      _emit(
        _state.copyWith(
          currentTrack: track,
          isPlaying: player.playing,
          position: player.position,
          bufferedPosition: player.bufferedPosition,
          duration: player.duration ?? track.duration,
        ),
      );
      return;
    }

    final shouldFastStartCurrentTrackOnly = shouldUseFastStartCurrentTrackOnly(
      allowFastStart: _shouldFastStartCurrentTrackOnly(),
      loadedSingleTrackOnly: _loadedSingleTrackOnly,
      sequenceIsEmpty: player.sequence.isEmpty,
      playlistLength: playlist.length,
    );

    if (canReusePlaylist &&
        player.sequence.isNotEmpty &&
        !_loadedSingleTrackOnly) {
      devLog(
        '[Playback] Android load(${track.id}) using existing playlist',
      );
      await player.seek(Duration.zero, index: index);
    } else if (shouldFastStartCurrentTrackOnly) {
      devLog(
        '[Playback] Android load(${track.id}) fast-starting current track',
      );
      _awaitingInitialSeek = true;
      try {
        final source = await _sourceBuilder(track);
        await player.setAudioSource(source, preload: true);
        await player.seek(Duration.zero);
      } finally {
        _awaitingInitialSeek = false;
      }
      _loadedSingleTrackOnly = true;
      _playlistSignature = const <String>[];
    } else {
      // Two-phase load: phase 1 resolves ONLY the tapped track so playback
      // can start immediately (a hung track resolve no longer blocks the
      // tap); phase 2 fills the rest of the playlist in the background.
      devLog('[Playback] Android load(${track.id}) fast-starting tapped track');
      _awaitingInitialSeek = true;
      late final just_audio.ConcatenatingAudioSource concat;
      try {
        final currentSource = await _sourceBuilder(
          track,
        ).timeout(const Duration(seconds: 30));
        concat = just_audio.ConcatenatingAudioSource(children: [currentSource]);
        await player.setAudioSource(concat, preload: true);
        await player.seek(Duration.zero);
      } finally {
        _awaitingInitialSeek = false;
      }
      _childPlaylistIndices = <int>[index];
      _loadedSingleTrackOnly = false;
      _playlistSignature = nextSignature;
      final gen = ++_fillGeneration;
      _isBackgroundFilling = true;
      unawaited(_fillPlaylistBackground(concat, playlist, index, gen));
    }

    _emit(
      _state.copyWith(
        currentTrack: track,
        isPlaying: player.playing,
        position: player.position,
        bufferedPosition: player.bufferedPosition,
        duration: player.duration ?? track.duration,
      ),
    );
  }

  @override
  Future<void> play() async {
    if (_sinkNeedsRearmOnPlay) {
      await rearmSink(resumePlayback: true);
      return;
    }
    final player = await _ensurePlayer();
    await _playInternal(player);
  }

  Future<void> _playInternal(just_audio.AudioPlayer player) async {
    // just_audio keeps this future alive while playback is active, which would
    // block the PlayerService command queue until the track ends.
    try {
      final playback = player.play();
      unawaited(
        playback.catchError((Object error, StackTrace stackTrace) {
          devLog('[Playback] Android play() failed: $error');
          debugPrintStack(stackTrace: stackTrace);
        }),
      );
    } catch (error, stackTrace) {
      devLog('[Playback] Android play() failed immediately: $error');
      debugPrintStack(stackTrace: stackTrace);
      rethrow;
    }
    // Resume a crossfade ramp that was frozen by pause().
    if (_crossfadeArmed) {
      final outgoing = _secondary;
      if (outgoing != null) {
        try {
          await outgoing.play();
        } catch (_) {}
        _startRampTimer(outgoing, player);
      }
    }
  }

  @override
  Future<void> pause() async {
    _sinkNeedsRearmOnPlay = true;
    final player = await _ensurePlayer();
    await player.pause();
    if (_crossfadeArmed) {
      // Freeze the ramp where it is; play() resumes from [_rampElapsed].
      _crossfadeTimer?.cancel();
      _crossfadeTimer = null;
      final outgoing = _secondary;
      if (outgoing != null) {
        try {
          await outgoing.pause();
        } catch (_) {}
      }
    }
  }

  @override
  Future<void> stop() async {
    _sinkNeedsRearmOnPlay = false;
    await _cancelCrossfade();
    final player = await _ensurePlayer();
    await player.stop();
    _emit(
      _state.copyWith(
        isPlaying: player.playing,
        position: player.position,
        bufferedPosition: player.bufferedPosition,
        duration: player.duration ?? _state.duration,
      ),
    );
  }

  /// Re-arms the Android audio sink by tearing down and reallocating the
  /// underlying AudioTrack in ExoPlayer.
  ///
  /// Used when the hardware ALSA sink stalls (e.g. concurrent system sounds
  /// wedging the MediaTek speaker amplifier) or after unpausing.
  Future<void> rearmSink({
    Duration? targetPosition,
    bool? resumePlayback,
  }) async {
    final inFlight = _rearmInFlight;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    final future = _doRearmSink(
      targetPosition: targetPosition,
      resumePlayback: resumePlayback,
    );
    _rearmInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_rearmInFlight, future)) {
        _rearmInFlight = null;
      }
    }
  }

  Future<void> _doRearmSink({
    Duration? targetPosition,
    bool? resumePlayback,
  }) async {
    _sinkNeedsRearmOnPlay = false;
    final track = _loadedTrack ?? _state.currentTrack;
    if (track == null) {
      return;
    }
    final player = await _ensurePlayer();
    final pos = targetPosition ?? player.position;
    final shouldPlay = resumePlayback ?? (player.playing || _state.isPlaying);

    devLog(
      '[Playback] Android rearmSink: track=${track.id} pos=${pos.inSeconds}s shouldPlay=$shouldPlay',
    );

    await _cancelCrossfade();
    _playlistSignature = const <String>[];
    _isBackgroundFilling = false;
    _fillGeneration++;

    try {
      await player.stop();
    } catch (e) {
      devLog('[Playback] Android rearmSink stop error: $e');
    }

    await load(track);

    if (pos > Duration.zero) {
      try {
        await player.seek(pos);
      } catch (e) {
        devLog('[Playback] Android rearmSink seek error: $e');
      }
    }

    if (shouldPlay) {
      await _playInternal(player);
    }
  }

  @override
  Future<void> seek(Duration position) async {
    final player = await _ensurePlayer();
    if (_crossfadeArmed) {
      // Aborting the in-flight fade: silence the outgoing tail and snap the
      // active player back to full volume before seeking.
      await _cancelCrossfade();
      try {
        await player.setVolume(_rampUserVolume);
      } catch (_) {}
    }
    await player.seek(position);
  }

  @override
  void updateTrack(Song track) {}

  void _maybeArmCrossfade(just_audio.AudioPlayer player, Duration pos) {
    if (_crossfadeArmed) return;
    final cfg = _crossfadeConfigProvider();
    final duration = player.duration;
    if (!shouldArmCrossfade(
      enabled: cfg.enabled,
      duration: duration ?? Duration.zero,
      position: pos,
      fadeSecs: cfg.durationSecs,
    )) {
      return;
    }
    _armCrossfade(cfg, (cfg.durationSecs * 1000).round());
  }

  void _armCrossfade(AndroidCrossfadeConfig cfg, int fadeMs) {
    // Set synchronously so the next position tick can't re-enter.
    _crossfadeArmed = true;
    unawaited(() async {
      final outgoing = _player;
      if (outgoing == null) {
        _crossfadeArmed = false;
        return;
      }
      final next = _onNextSong?.call();
      if (next == null || next.id == _loadedTrack?.id) {
        // Nothing to crossfade into (end of list / loop-one): let the track
        // end naturally so onTrackEnded handles it.
        _crossfadeArmed = false;
        return;
      }
      try {
        final incoming = await _ensureSecondary();
        final source = await _sourceBuilder(next);
        _rampUserVolume = outgoing.volume <= 0 ? 1.0 : outgoing.volume;
        await incoming.setAudioSource(source, preload: true);
        await incoming.seek(Duration.zero);
        await incoming.setVolume(0);
        await incoming.setSpeed(outgoing.speed);
        await incoming.setLoopMode(just_audio.LoopMode.off);
        unawaited(
          incoming.play().catchError((Object error, StackTrace stackTrace) {
            devLog('[crossfade] incoming play() failed: $error');
            debugPrintStack(stackTrace: stackTrace);
          }),
        );
        _loadedTrack = next;
        _loadedSingleTrackOnly = true;
        _playlistSignature = const <String>[];
        _rampTotal = Duration(milliseconds: fadeMs);
        _rampElapsed = Duration.zero;
        _rampCurve = cfg.curve;
        // Swap roles: incoming becomes the active player, outgoing becomes the
        // idle slot and is faded out by the ramp.
        _player = incoming;
        _secondary = outgoing;
        _startRampTimer(outgoing, incoming);
        // The emitted state drives PlayerService's track-change bookkeeping
        // (index sync, notification, replay tracking, position save).
        _emit(
          _state.copyWith(
            currentTrack: next,
            position: Duration.zero,
            bufferedPosition: Duration.zero,
            duration: incoming.duration ?? next.duration,
          ),
        );
        // Queue-entry consumption + priority anchor are not covered by the
        // playback-state subscription, so the service does them here.
        _onTrackAdvanced?.call(next);
      } catch (error, stackTrace) {
        devLog('[crossfade] arm failed: $error');
        debugPrintStack(stackTrace: stackTrace);
        _crossfadeArmed = false;
        final active = _player;
        if (active != null) {
          try {
            await active.setVolume(_rampUserVolume);
          } catch (_) {}
        }
      }
    }());
  }

  void _startRampTimer(
    just_audio.AudioPlayer outgoing,
    just_audio.AudioPlayer incoming,
  ) {
    _crossfadeTimer?.cancel();
    _crossfadeTimer = Timer.periodic(_rampTick, (timer) {
      // Hold the ramp while paused; play() restarts it from [_rampElapsed].
      if (!incoming.playing) return;
      _rampElapsed += _rampTick;
      final p = _rampTotal.inMilliseconds <= 0
          ? 1.0
          : (_rampElapsed.inMilliseconds / _rampTotal.inMilliseconds)
              .clamp(0.0, 1.0)
              .toDouble();
      final inVol = _rampUserVolume * crossfadeInVolume(_rampCurve, p);
      final outVol = _rampUserVolume * crossfadeInVolume(_rampCurve, 1 - p);
      incoming.setVolume(inVol);
      outgoing.setVolume(outVol);
      if (p >= 1.0) {
        timer.cancel();
        _crossfadeTimer = null;
        unawaited(_finishCrossfade(outgoing));
      }
    });
  }

  Future<void> _finishCrossfade(just_audio.AudioPlayer outgoing) async {
    try {
      await outgoing.stop();
    } catch (_) {}
    try {
      await outgoing.setVolume(_rampUserVolume);
    } catch (_) {}
    try {
      await outgoing.seek(Duration.zero);
    } catch (_) {}
    _crossfadeArmed = false;
  }

  Future<void> _cancelCrossfade() async {
    _crossfadeTimer?.cancel();
    _crossfadeTimer = null;
    final wasArmed = _crossfadeArmed;
    _crossfadeArmed = false;
    final secondary = _secondary;
    if (secondary != null) {
      try {
        await secondary.stop();
      } catch (_) {}
      try {
        await secondary.setVolume(_rampUserVolume);
      } catch (_) {}
      try {
        await secondary.seek(Duration.zero);
      } catch (_) {}
    }
    // If we were mid-fade, the active player's volume was being ramped down;
    // restore it so the user doesn't get a silently-seeking track.
    if (wasArmed) {
      final active = _player;
      if (active != null) {
        try {
          await active.setVolume(_rampUserVolume);
        } catch (_) {}
      }
    }
  }

  @override
  Future<void> dispose() async {
    _crossfadeTimer?.cancel();
    _crossfadeTimer = null;
    _crossfadeArmed = false;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    final secondary = _secondary;
    _secondary = null;
    _player = null;
    _playlistSignature = const <String>[];
    _loadedSingleTrackOnly = false;
    // Cancel any in-flight background playlist fill so it can't touch a
    // dead engine.
    _fillGeneration++;
    _isBackgroundFilling = false;
    try {
      await secondary?.dispose();
    } catch (_) {}
    await _disposeEngine();
    await _controller.close();
  }
}
