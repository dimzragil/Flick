import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as just_audio;

import 'package:flick/models/playback_state.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/android_audio_engine.dart';

class _FakeAudioPlayer implements just_audio.AudioPlayer {
  just_audio.AudioSource? _source;
  int? _currentIndex;
  final StreamController<int?> _currentIndexController =
      StreamController<int?>.broadcast();

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
    _source = audioSource;
    _currentIndex = initialIndex ?? 0;
    return null;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    if (index != null) {
      _currentIndex = index;
      _currentIndexController.add(index);
    }
  }

  void emitCurrentIndex(int? index) {
    _currentIndex = index;
    _currentIndexController.add(index);
  }

  @override
  int? get currentIndex => _currentIndex;

  @override
  Stream<int?> get currentIndexStream => _currentIndexController.stream;

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
  Stream<just_audio.ProcessingState> get processingStateStream =>
      const Stream<just_audio.ProcessingState>.empty();

  @override
  Stream<just_audio.PlayerException> get errorStream =>
      const Stream<just_audio.PlayerException>.empty();

  @override
  bool get playing => false;

  @override
  Duration get position => Duration.zero;

  @override
  Duration get bufferedPosition => Duration.zero;

  @override
  Duration? get duration => null;

  @override
  double get volume => 1.0;

  @override
  just_audio.ProcessingState get processingState =>
      just_audio.ProcessingState.idle;

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setLoopMode(just_audio.LoopMode loopMode) async {}

  @override
  Future<void> dispose() async {}

  Future<void> close() => _currentIndexController.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Song _song(String id) => Song(
      id: id,
      title: 'Title $id',
      artist: 'Artist',
      duration: const Duration(minutes: 3),
      fileType: 'FLAC',
    );

class _Harness {
  _Harness({required int trackCount})
      : playlist = List.generate(trackCount, (i) => _song('s$i')) {
    player = _FakeAudioPlayer();
    engine = AndroidAudioEngine(
      playerProvider: () async => player,
      sourceBuilder: (song) {
        final override = buildOverride;
        if (override != null) return override(song);
        return immediateSource(song);
      },
      playlistProvider: () => playlist,
      configurePlayer: (_) async {},
      disposeEngine: () async {},
      shouldSuppressTrackSync: () => false,
      shouldIgnoreTrack: (_) => false,
      shouldFastStartCurrentTrackOnly: () => false,
      crossfadeConfigProvider: () => AndroidCrossfadeConfig.disabled,
      backgroundFillDelay: Duration.zero,
    );
  }

  final List<Song> playlist;
  late final _FakeAudioPlayer player;
  late final AndroidAudioEngine engine;

  final Map<String, just_audio.AudioSource> sourcesById = {};
  Future<just_audio.AudioSource> Function(Song song)? buildOverride;

  Future<just_audio.AudioSource> immediateSource(Song song) async {
    return sourcesById.putIfAbsent(
      song.id,
      () => just_audio.AudioSource.uri(Uri.parse('test:///track/${song.id}')),
    );
  }

  Future<void> dispose() async {
    await engine.dispose();
    await player.close();
  }
}

void main() {
  group('AndroidAudioEngine playlist-fill race guard', () {
    test(
      'superseded fill returning from concat.insert does not corrupt child playlist indices',
      () async {
        final harness = _Harness(trackCount: 4);
        final gateLoad2 = Completer<void>();
        addTearDown(() {
          if (!gateLoad2.isCompleted) gateLoad2.complete();
        });
        addTearDown(harness.dispose);

        // When load(1) fills index 0 ('s0'), schedule load(2) on the microtask loop
        // so it arrives while concat.insert(0, src) is in flight.
        var load2Triggered = false;
        final gateGen2 = Completer<void>();
        addTearDown(() {
          if (!gateGen2.isCompleted) gateGen2.complete();
        });

        harness.buildOverride = (song) async {
          if (song.id == 's0' && !load2Triggered) {
            load2Triggered = true;
            scheduleMicrotask(() async {
              await harness.engine.load(harness.playlist[2]);
              gateLoad2.complete();
            });
            return harness.immediateSource(song);
          }
          if (load2Triggered && song.id != 's2') {
            await gateGen2.future;
          }
          return harness.immediateSource(song);
        };

        final states = <PlaybackState>[];
        final sub = harness.engine.playbackStateStream.listen(states.add);

        // Load 1 starts with s1
        await harness.engine.load(harness.playlist[1]);
        await gateLoad2.future;

        // At this point load 2 (tapped s2) has executed and set up generation 2.
        // Gen 2 background fill is gated, so player sequence has only 1 track (s2).
        // The post-insert generation check in gen 1 must prevent it from inserting
        // s0 into gen 2's _childPlaylistIndices.

        // Sequence holds only s2 at index 0.
        expect(harness.player.sequence, hasLength(1));

        // Current track from load(s2) is s2.
        expect(states.last.currentTrack?.id, 's2');

        // Emitting index 0 must NOT resolve to s0.
        // If gen 1 had inserted into _childPlaylistIndices, index 0 would resolve to s0
        // and emit a new PlaybackState.
        states.clear();
        harness.player.emitCurrentIndex(0);
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(states.where((s) => s.currentTrack?.id == 's0'), isEmpty);

        gateGen2.complete();
        await sub.cancel();
      },
    );
  });
}
