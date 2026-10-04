import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as just_audio;

import 'package:flick/models/song.dart';
import 'package:flick/services/android_audio_engine.dart';

/// Fake player that records `setAudioSource` args and `seek` calls so tests
/// can assert the atomic rearm contract: the resume position goes through
/// `setAudioSource(initialPosition:)` and no separate `seek` is issued.
///
/// Unlike a naive stub, it mirrors just_audio/ExoPlayer by starting AT the
/// initial position given to `setAudioSource`.
class _RearmAudioPlayer implements just_audio.AudioPlayer {
  Duration _position = Duration.zero;
  just_audio.AudioSource? _source;
  bool _playing = false;

  /// The `initialPosition` values seen by `setAudioSource`, in call order.
  final List<Duration?> setAudioSourceInitialPositions = [];

  /// The positions passed to `seek`, in call order.
  final List<Duration> seekPositions = [];

  /// Clears the recorded call history (e.g. between an initial `load` and
  /// the `rearmSink` under test).
  void resetCallLog() {
    setAudioSourceInitialPositions.clear();
    seekPositions.clear();
  }

  @override
  bool get playing => _playing;

  @override
  Duration get position => _position;

  @override
  Duration get bufferedPosition => _position;

  @override
  Duration? get duration => const Duration(minutes: 4);

  @override
  double get volume => 1.0;

  @override
  just_audio.ProcessingState get processingState =>
      just_audio.ProcessingState.ready;

  @override
  List<just_audio.IndexedAudioSource> get sequence {
    final source = _source;
    if (source == null) return const [];
    return source.sequence;
  }

  @override
  Future<Duration?> setAudioSource(
    just_audio.AudioSource audioSource, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    setAudioSourceInitialPositions.add(initialPosition);
    _source = audioSource;
    // Atomic start: the player begins at the initial position, with no
    // separate seek involved.
    _position = initialPosition ?? Duration.zero;
    return null;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    final pos = position ?? Duration.zero;
    seekPositions.add(pos);
    _position = pos;
  }

  @override
  Future<void> play() async {
    _playing = true;
  }

  @override
  Future<void> pause() async {
    _playing = false;
  }

  @override
  Future<void> stop() async {
    _playing = false;
    _source = null;
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setLoopMode(just_audio.LoopMode loopMode) async {}

  @override
  Future<void> dispose() async {}

  @override
  Stream<just_audio.PlayerState> get playerStateStream =>
      const Stream<just_audio.PlayerState>.empty();

  @override
  Stream<just_audio.PlaybackEvent> get playbackEventStream =>
      const Stream<just_audio.PlaybackEvent>.empty();

  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();

  @override
  Stream<Duration> get bufferedPositionStream => const Stream<Duration>.empty();

  @override
  Stream<Duration?> get durationStream => const Stream<Duration?>.empty();

  @override
  Stream<just_audio.SequenceState> get sequenceStateStream =>
      const Stream<just_audio.SequenceState>.empty();

  @override
  Stream<int?> get currentIndexStream => const Stream<int?>.empty();

  @override
  Stream<just_audio.ProcessingState> get processingStateStream =>
      const Stream<just_audio.ProcessingState>.empty();

  @override
  Stream<just_audio.PlayerException> get errorStream =>
      const Stream<just_audio.PlayerException>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Song _song(String id) => Song(
  id: id,
  title: 'Title $id',
  artist: 'Artist',
  duration: const Duration(minutes: 4),
  fileType: 'FLAC',
);

void main() {
  group('AndroidAudioEngine atomic rearm seek', () {
    late _RearmAudioPlayer fakePlayer;
    late AndroidAudioEngine engine;
    late List<Song> playlist;

    setUp(() {
      fakePlayer = _RearmAudioPlayer();
      playlist = [_song('s1'), _song('s2')];
      engine = AndroidAudioEngine(
        playerProvider: () async => fakePlayer,
        sourceBuilder: (song) async =>
            just_audio.AudioSource.uri(Uri.parse('asset:///${song.id}')),
        playlistProvider: () => playlist,
        configurePlayer: (_) async {},
        disposeEngine: () async {},
        shouldSuppressTrackSync: () => false,
        shouldIgnoreTrack: (_) => false,
        shouldFastStartCurrentTrackOnly: () => false,
        crossfadeConfigProvider: () => AndroidCrossfadeConfig.disabled,
      );
    });

    tearDown(() async {
      await engine.dispose();
    });

    test(
      'rearm passes the target position atomically via setAudioSource',
      () async {
        const target = Duration(seconds: 45);
        await engine.load(playlist[0]);
        fakePlayer.resetCallLog();

        await engine.rearmSink(targetPosition: target, resumePlayback: false);

        expect(fakePlayer.setAudioSourceInitialPositions, [
          target,
        ], reason: 'rearm must resume via setAudioSource initialPosition');
        expect(
          fakePlayer.seekPositions,
          isEmpty,
          reason: 'no separate seek may be issued after the atomic load',
        );
        expect(
          fakePlayer.position,
          target,
          reason: 'the player must start at the target, not at 0',
        );
      },
    );

    test('rearm with no target keeps the legacy seek-to-zero reset', () async {
      await engine.load(playlist[0]);
      fakePlayer.resetCallLog();

      await engine.rearmSink(resumePlayback: false);

      expect(fakePlayer.setAudioSourceInitialPositions, [
        isNull,
      ], reason: 'a zero target must not set initialPosition');
      expect(fakePlayer.seekPositions, [
        Duration.zero,
      ], reason: 'zero-position loads keep the seek(Duration.zero) reset');
    });

    test(
      'load(initialPosition:) passes it through and skips the zero seek',
      () async {
        const target = Duration(seconds: 12);

        await engine.load(playlist[0], initialPosition: target);

        expect(fakePlayer.setAudioSourceInitialPositions, [target]);
        expect(fakePlayer.seekPositions, isEmpty);
      },
    );

    test(
      'load() without initialPosition keeps the seek-to-zero reset',
      () async {
        await engine.load(playlist[0]);

        expect(fakePlayer.setAudioSourceInitialPositions, [isNull]);
        expect(fakePlayer.seekPositions, [Duration.zero]);
      },
    );
  });
}
