import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as just_audio;

import 'package:flick/models/song.dart';
import 'package:flick/services/android_audio_engine.dart';

class _FakeAudioPlayer implements just_audio.AudioPlayer {
  just_audio.AudioSource? _source;
  bool _playing = false;
  Duration _position = Duration.zero;

  final List<String> callLog = [];
  final List<Duration> seekPositions = [];

  /// The `initialPosition` values seen by `setAudioSource`, in call order.
  /// Rearm now resumes atomically through this parameter instead of issuing
  /// a separate seek after load.
  final List<Duration?> setAudioSourceInitialPositions = [];

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
    callLog.add('setAudioSource');
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
    callLog.add('seek:${pos.inMilliseconds}');
    seekPositions.add(pos);
    _position = pos;
  }

  @override
  Future<void> play() async {
    callLog.add('play');
    _playing = true;
  }

  @override
  Future<void> pause() async {
    callLog.add('pause');
    _playing = false;
  }

  @override
  Future<void> stop() async {
    callLog.add('stop');
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
  group('AndroidAudioEngine sink rearm', () {
    late _FakeAudioPlayer fakePlayer;
    late AndroidAudioEngine engine;
    late List<Song> playlist;

    setUp(() {
      fakePlayer = _FakeAudioPlayer();
      playlist = [_song('s1'), _song('s2')];
      engine = AndroidAudioEngine(
        playerProvider: () async => fakePlayer,
        sourceBuilder: (song, {bool deferPump = false}) async =>
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
      'rearmSink() stops player, reloads track source at the saved position atomically and resumes play',
      () async {
        await engine.load(playlist[0]);
        await engine.play();
        await engine.seek(const Duration(seconds: 45));

        fakePlayer.callLog.clear();
        fakePlayer.seekPositions.clear();
        fakePlayer.setAudioSourceInitialPositions.clear();

        await engine.rearmSink();

        // Verify sequence: stop -> setAudioSource(initialPosition: 45s) -> play.
        // The resume position goes through setAudioSource atomically; no
        // separate seek may be issued after the load.
        expect(fakePlayer.callLog, contains('stop'));
        expect(fakePlayer.callLog, contains('setAudioSource'));
        expect(fakePlayer.callLog, contains('play'));
        expect(fakePlayer.seekPositions, isEmpty);

        final stopIndex = fakePlayer.callLog.indexOf('stop');
        final setSourceIndex = fakePlayer.callLog.lastIndexOf('setAudioSource');
        final playIndex = fakePlayer.callLog.lastIndexOf('play');

        expect(stopIndex, lessThan(setSourceIndex));
        expect(setSourceIndex, lessThan(playIndex));
        expect(fakePlayer.playing, isTrue);
        expect(fakePlayer.setAudioSourceInitialPositions, [
          const Duration(seconds: 45),
        ]);
      },
    );

    test(
      'standard pause() followed by play() does fast resume without rearm',
      () async {
        await engine.load(playlist[0]);
        await engine.play();
        await engine.seek(const Duration(seconds: 30));

        await engine.pause();
        expect(fakePlayer.callLog, contains('pause'));

        fakePlayer.callLog.clear();

        // Standard unpause should resume immediately without expensive rearm
        await engine.play();

        expect(fakePlayer.callLog, isNot(contains('stop')));
        expect(fakePlayer.callLog, isNot(contains('setAudioSource')));
        expect(fakePlayer.callLog, contains('play'));
        expect(fakePlayer.playing, isTrue);
      },
    );

    test('markSinkNeedsRearm() followed by play() triggers sink rearm', () async {
      await engine.load(playlist[0]);
      await engine.play();
      await engine.seek(const Duration(seconds: 30));

      await engine.pause();
      engine.markSinkNeedsRearm();

      fakePlayer.callLog.clear();
      fakePlayer.seekPositions.clear();
      fakePlayer.setAudioSourceInitialPositions.clear();

      // Now resume with play()
      await engine.play();

      // play() should have invoked rearmSink() because _sinkNeedsRearmOnPlay was true
      expect(fakePlayer.callLog, contains('stop'));
      expect(fakePlayer.callLog, contains('setAudioSource'));
      expect(fakePlayer.callLog, contains('play'));
      // Atomic resume: no separate seek after the load; the position went
      // through setAudioSource initialPosition.
      expect(fakePlayer.seekPositions, isEmpty);
      expect(fakePlayer.setAudioSourceInitialPositions, [
        const Duration(seconds: 30),
      ]);
      expect(fakePlayer.playing, isTrue);
    });

    test('subsequent play() without pause does not rearm sink', () async {
      await engine.load(playlist[0]);
      await engine.play();

      fakePlayer.callLog.clear();

      // Calling play again while already playing does not rearm
      await engine.play();

      expect(fakePlayer.callLog, isNot(contains('stop')));
      expect(fakePlayer.callLog, isNot(contains('setAudioSource')));
      expect(fakePlayer.callLog, contains('play'));
    });
  });
}
