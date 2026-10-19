import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as just_audio;

import 'package:flick/models/playback_state.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/android_audio_engine.dart';

/// Controllable just_audio.AudioPlayer used to suspend the crossfade arm at a
/// specific await point and then observe whether it still starts audio.
class _FakeAudioPlayer implements just_audio.AudioPlayer {
  @override
  final Duration duration = const Duration(minutes: 3);

  just_audio.AudioSource? _source;
  just_audio.AudioSource? lastSource;
  bool _playing = false;
  double _volume = 1.0;
  double _speed = 1.0;
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();

  int playCalls = 0;
  int pauseCalls = 0;
  int stopCalls = 0;
  final List<String> calls = [];
  final Map<String, int> _callCounts = {};
  final List<_CallHook> _hooks = [];

  /// Registers [callback] to run during the [occurrence]-th call to [call]
  /// (1-based). The hook fires while the engine is awaiting that method, so a
  /// pause()/load() from inside it exercises cancellation mid-await.
  void hookOnce(
    String call,
    Future<void> Function() callback, {
    int occurrence = 1,
  }) {
    _hooks.add(_CallHook(call, occurrence, callback));
  }

  Future<void> _runHook(String call) async {
    calls.add(call);
    final occurrence = (_callCounts[call] ?? 0) + 1;
    _callCounts[call] = occurrence;
    for (final hook in List<_CallHook>.of(_hooks)) {
      if (hook.call == call && hook.occurrence == occurrence) {
        _hooks.remove(hook);
        await hook.callback();
        return;
      }
    }
  }

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
    await _runHook('setAudioSource');
    _source = audioSource;
    lastSource = audioSource;
    return duration;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    await _runHook('seek');
  }

  void emitPosition(Duration position) {
    _positionController.add(position);
  }

  Future<void> close() => _positionController.close();

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  bool get playing => _playing;

  @override
  Duration get position => Duration.zero;

  @override
  Duration get bufferedPosition => Duration.zero;

  @override
  double get volume => _volume;

  @override
  double get speed => _speed;

  @override
  Future<void> play() async {
    playCalls++;
    _playing = true;
    await _runHook('play');
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    _playing = false;
    await _runHook('pause');
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _playing = false;
    await _runHook('stop');
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
    await _runHook('setVolume');
  }

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    await _runHook('setSpeed');
  }

  @override
  Future<void> setLoopMode(just_audio.LoopMode loopMode) async {
    await _runHook('setLoopMode');
  }

  @override
  Future<void> dispose() async {
    await _runHook('dispose');
  }

  @override
  Stream<just_audio.PlayerState> get playerStateStream =>
      const Stream<just_audio.PlayerState>.empty();

  @override
  Stream<just_audio.PlaybackEvent> get playbackEventStream =>
      const Stream<just_audio.PlaybackEvent>.empty();

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
  int? get currentIndex => 0;

  @override
  just_audio.ProcessingState get processingState =>
      just_audio.ProcessingState.ready;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CallHook {
  _CallHook(this.call, this.occurrence, this.callback);

  final String call;
  final int occurrence;
  final Future<void> Function() callback;
}

Song _song(String id) => Song(
  id: id,
  title: 'Title $id',
  artist: 'Artist',
  duration: const Duration(minutes: 3),
  fileType: 'FLAC',
);

/// Pumps the event loop until [condition] holds (or [timeout] elapses).
Future<void> _pumpUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _Harness {
  _Harness() : playlist = [_song('s0'), _song('s1'), _song('s2')] {
    primary = _FakeAudioPlayer();
    secondary = _FakeAudioPlayer();
    engine = AndroidAudioEngine(
      playerProvider: () async => primary,
      secondaryPlayerProvider: () => secondary,
      sourceBuilder: (song, {bool deferPump = false}) {
        sourceRequests.add(song.id);
        final source = sourceFor(song);
        final gate = sourceGates.remove(song.id);
        if (gate != null) return gate.future.then((_) => source);
        return Future.value(source);
      },
      playlistProvider: () => playlist,
      configurePlayer: (_) async {},
      disposeEngine: () async {},
      shouldSuppressTrackSync: () => false,
      shouldIgnoreTrack: (_) => false,
      shouldFastStartCurrentTrackOnly: () => false,
      crossfadeConfigProvider: () => const AndroidCrossfadeConfig(
        enabled: true,
        // Short fade keeps the normal-crossfade test fast; cancellation tests
        // never reach the ramp.
        durationSecs: 0.05,
        curve: AndroidCrossfadeCurve.equalPower,
      ),
      onNextSong: () => playlist[1],
    );
  }

  final List<Song> playlist;
  late final _FakeAudioPlayer primary;
  late final _FakeAudioPlayer secondary;
  late final AndroidAudioEngine engine;
  final List<PlaybackState> states = [];
  final List<String> sourceRequests = [];
  final Map<String, Completer<void>> sourceGates = {};
  final Map<String, just_audio.AudioSource> _sources = {};
  StreamSubscription<PlaybackState>? _subscription;

  just_audio.AudioSource sourceFor(Song song) => _sources.putIfAbsent(
    song.id,
    () => just_audio.AudioSource.uri(Uri.parse('test:///track/${song.id}')),
  );

  Future<void> setUp() async {
    _subscription = engine.playbackStateStream.listen(states.add);
    await engine.load(playlist[0]);
  }

  /// Emits a position inside the crossfade window, arming the fade into s1.
  void armCrossfade() {
    primary.emitPosition(
      const Duration(minutes: 2, seconds: 59, milliseconds: 970),
    );
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    await engine.dispose();
    await primary.close();
    await secondary.close();
  }
}

void main() {
  group('AndroidAudioEngine crossfade arm cancellation', () {
    late _Harness harness;

    setUp(() async {
      harness = _Harness();
      await harness.setUp();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test(
      'pause() during slow source resolution starts no phantom audio',
      () async {
        final gate = Completer<void>();
        harness.sourceGates['s1'] = gate;

        harness.armCrossfade();
        await _pumpUntil(() => harness.sourceRequests.contains('s1'));

        await harness.engine.pause();
        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(harness.secondary.playCalls, 0);
        expect(harness.primary.pauseCalls, 1);
        expect(harness.states.last.currentTrack?.id, 's0');
      },
    );

    test(
      'stop() during slow source resolution starts no phantom audio',
      () async {
        final gate = Completer<void>();
        harness.sourceGates['s1'] = gate;

        harness.armCrossfade();
        await _pumpUntil(() => harness.sourceRequests.contains('s1'));

        await harness.engine.stop();
        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(harness.secondary.playCalls, 0);
        expect(harness.states.last.currentTrack?.id, 's0');
      },
    );

    test(
      'load() during slow source resolution does not overwrite the new track',
      () async {
        final gate = Completer<void>();
        harness.sourceGates['s1'] = gate;

        harness.armCrossfade();
        await _pumpUntil(() => harness.sourceRequests.contains('s1'));

        await harness.engine.load(harness.playlist[2]);
        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(harness.secondary.playCalls, 0);
        expect(harness.states.last.currentTrack?.id, 's2');
        expect(
          identical(
            harness.primary.lastSource,
            harness.sourceFor(harness.playlist[2]),
          ),
          isTrue,
        );
      },
    );

    test(
      'pause() aborts the arm while awaiting the secondary player',
      () async {
        harness.secondary.hookOnce('setVolume', harness.engine.pause);

        harness.armCrossfade();
        await _pumpUntil(() => harness.secondary.calls.contains('setVolume'));
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(harness.secondary.playCalls, 0);
        expect(harness.states.last.currentTrack?.id, 's0');
      },
    );

    test('pause() aborts the arm while awaiting setAudioSource', () async {
      harness.secondary.hookOnce('setAudioSource', harness.engine.pause);

      harness.armCrossfade();
      await _pumpUntil(
        () => harness.secondary.calls.contains('setAudioSource'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(harness.secondary.playCalls, 0);
      expect(harness.states.last.currentTrack?.id, 's0');
    });

    test('pause() aborts the arm while awaiting incoming volume', () async {
      // _ensureSecondary() sets the volume first; the arm's own setVolume(0)
      // is the second call.
      harness.secondary.hookOnce(
        'setVolume',
        harness.engine.pause,
        occurrence: 2,
      );

      harness.armCrossfade();
      await _pumpUntil(
        () => (harness.secondary._callCounts['setVolume'] ?? 0) >= 2,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(harness.secondary.playCalls, 0);
      expect(harness.states.last.currentTrack?.id, 's0');
    });

    test('pause() aborts the arm while awaiting seek', () async {
      harness.secondary.hookOnce('seek', harness.engine.pause);

      harness.armCrossfade();
      await _pumpUntil(() => harness.secondary.calls.contains('seek'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(harness.secondary.playCalls, 0);
      expect(harness.states.last.currentTrack?.id, 's0');
    });

    test('pause() aborts the arm while awaiting setSpeed', () async {
      harness.secondary.hookOnce('setSpeed', harness.engine.pause);

      harness.armCrossfade();
      await _pumpUntil(() => harness.secondary.calls.contains('setSpeed'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(harness.secondary.playCalls, 0);
      expect(harness.states.last.currentTrack?.id, 's0');
    });

    test('pause() aborts the arm while awaiting setLoopMode', () async {
      // _ensureSecondary() calls setLoopMode first; the arm's own call is the
      // second one.
      harness.secondary.hookOnce(
        'setLoopMode',
        harness.engine.pause,
        occurrence: 2,
      );

      harness.armCrossfade();
      await _pumpUntil(
        () => (harness.secondary._callCounts['setLoopMode'] ?? 0) >= 2,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(harness.secondary.playCalls, 0);
      expect(harness.states.last.currentTrack?.id, 's0');
    });

    test('uninterrupted crossfade still starts the incoming track', () async {
      harness.armCrossfade();

      await _pumpUntil(
        () =>
            harness.secondary.playCalls == 1 &&
            harness.states.last.currentTrack?.id == 's1',
      );

      // The short fade completes: the outgoing player is stopped and the
      // incoming player is now the audible one.
      await _pumpUntil(() => harness.primary.stopCalls == 1);
      expect(harness.secondary.playing, isTrue);
      expect(harness.states.last.currentTrack?.id, 's1');
    });
  });
}
