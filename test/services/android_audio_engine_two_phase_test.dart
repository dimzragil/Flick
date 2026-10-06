import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as just_audio;

import 'package:flick/models/playback_state.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/android_audio_engine.dart';

/// Controllable just_audio.AudioPlayer stand-in for the two-phase playlist
/// load path.
///
/// [AndroidAudioEngine] drives `load()` through [setAudioSource], [sequence],
/// [seek] and the listened streams; the background fill mutates the real
/// concatenating audio source directly via `insert`, so [sequence]
/// delegates to it and always reflects the fill's progress. A real
/// AudioPlayer cannot be constructed in unit tests (its constructor hits the
/// platform channel via AudioSession). Everything the engine never touches
/// on this path falls through to [noSuchMethod].
class _FakeAudioPlayer implements just_audio.AudioPlayer {
  just_audio.AudioSource? _source;
  int? _currentIndex;
  final StreamController<int?> _currentIndexController =
      StreamController<int?>.broadcast();

  /// Recorded `seek` calls (parallel lists).
  final List<Duration?> seekPositions = [];
  final List<int?> seekIndices = [];

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
    seekPositions.add(position);
    seekIndices.add(index);
    if (index != null) {
      _currentIndex = index;
      _currentIndexController.add(index);
    }
  }

  /// Test helper: drive the engine's `currentIndex` listener with [index].
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

/// Pumps the event loop until [condition] holds (or [timeout] elapses).
Future<void> _pumpUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Test harness: engine + fake player + a controllable per-track source
/// builder whose behavior can be swapped mid-test via [buildOverride].
class _Harness {
  _Harness({
    required int trackCount,
    Duration backgroundFillDelay = Duration.zero,
  }) : playlist = List.generate(trackCount, (i) => _song('s$i')) {
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
      backgroundFillDelay: backgroundFillDelay,
    );
  }

  final List<Song> playlist;
  late final _FakeAudioPlayer player;
  late final AndroidAudioEngine engine;

  /// Per-track sources created so far, keyed by song id.
  final Map<String, just_audio.AudioSource> sourcesById = {};

  /// Swappable source-builder behavior; null resolves immediately.
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
  group('AndroidAudioEngine two-phase playlist load', () {
    test(
      'phase 1 resolves only the tapped track: sequence has exactly 1 child',
      () async {
        final harness = _Harness(trackCount: 4);
        // Release the gate only after the engine is disposed, so a parked
        // fill aborts via its generation check instead of proceeding.
        final gate = Completer<void>();
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        addTearDown(harness.dispose);

        // Gate every non-tapped track so the background fill cannot move
        // past phase 1 while we assert on it.
        const tappedId = 's2';
        harness.buildOverride = (song) async {
          if (song.id != tappedId) await gate.future;
          return harness.immediateSource(song);
        };

        final tapped = harness.playlist[2];
        final states = <PlaybackState>[];
        final sub = harness.engine.playbackStateStream.listen(states.add);

        await harness.engine.load(tapped);

        // Phase-1 fast start: only the tapped track was resolved and the
        // player holds exactly that one child.
        expect(harness.sourcesById.keys, [tapped.id]);
        expect(harness.player.sequence, hasLength(1));
        expect(
          harness.player.sequence.first,
          same(harness.sourcesById[tapped.id]),
        );

        // The _resolveTrack-driven current track is the tapped song,
        // observed through the engine's public playbackStateStream.
        harness.player.emitCurrentIndex(0);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(states, isNotEmpty);
        expect(states.last.currentTrack?.id, tapped.id);

        await sub.cancel();
      },
    );

    test('background fill completes in playlist order with correct index '
        'mapping', () async {
      final harness = _Harness(trackCount: 5);
      addTearDown(harness.dispose);

      final tapped = harness.playlist[1];
      final states = <PlaybackState>[];
      final sub = harness.engine.playbackStateStream.listen(states.add);

      await harness.engine.load(tapped);

      // Wait for the background fill to settle.
      await _pumpUntil(
        () => harness.player.sequence.length == harness.playlist.length,
      );

      // Every sequence position holds that playlist index's own source.
      final sequence = harness.player.sequence;
      expect(sequence, hasLength(harness.playlist.length));
      for (var i = 0; i < harness.playlist.length; i++) {
        expect(
          sequence[i],
          same(harness.sourcesById[harness.playlist[i].id]),
          reason:
              'sequence[$i] should be the source for ${harness.playlist[i].id}',
        );
      }

      // _resolveTrack maps player indices back to playlist songs for
      // several indices, observed through playbackStateStream.
      states.clear();
      for (final index in [0, 3, 4]) {
        harness.player.emitCurrentIndex(index);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(states.map((s) => s.currentTrack?.id).toList(), [
        's0',
        's3',
        's4',
      ]);

      await sub.cancel();
    });

    test('a newer load() supersedes an in-flight background fill', () async {
      final harness = _Harness(trackCount: 4);
      final gateA = Completer<void>();
      addTearDown(() {
        if (!gateA.isCompleted) gateA.complete();
      });
      addTearDown(harness.dispose);

      // Load A's fill parks on its first non-tapped track; everything from
      // load B on resolves immediately.
      var tappedId = 's1';
      var gateOpen = false;
      harness.buildOverride = (song) async {
        if (!gateOpen && song.id != tappedId) await gateA.future;
        return harness.immediateSource(song);
      };

      await harness.engine.load(harness.playlist[1]);
      expect(harness.player.sequence, hasLength(1));

      tappedId = 's2';
      gateOpen = true;
      await harness.engine.load(harness.playlist[2]);

      // B's fill settles: the sequence is B's full playlist in order, with
      // no interleaved children from A's superseded fill.
      await _pumpUntil(() => harness.player.sequence.length == 4);
      for (var i = 0; i < 4; i++) {
        expect(
          harness.player.sequence[i],
          same(harness.sourcesById['s$i']),
          reason: 'sequence[$i] should be the source for s$i',
        );
      }

      // Releasing A's fill must not disturb B's sequence: the generation
      // check aborts it before any insert.
      gateA.complete();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(harness.player.sequence, hasLength(4));
      for (var i = 0; i < 4; i++) {
        expect(
          harness.player.sequence[i],
          same(harness.sourcesById['s$i']),
          reason: 'sequence[$i] should still be the source for s$i',
        );
      }
    });

    test(
      'a failing track resolve inserts an index-preserving placeholder',
      () async {
        final harness = _Harness(trackCount: 4);
        addTearDown(harness.dispose);

        harness.buildOverride = (song) async {
          if (song.id == 's2') throw StateError('simulated resolve failure');
          return harness.immediateSource(song);
        };

        await harness.engine.load(harness.playlist[1]);
        await _pumpUntil(() => harness.player.sequence.length == 4);

        // Indices of the surviving tracks are preserved; the failed track's
        // slot holds the placeholder, not a shifted neighbor.
        final sequence = harness.player.sequence;
        expect(sequence[0], same(harness.sourcesById['s0']));
        expect(sequence[1], same(harness.sourcesById['s1']));
        expect(sequence[3], same(harness.sourcesById['s3']));
        expect(harness.sourcesById.containsKey('s2'), isFalse);
        final placeholder = sequence[2];
        expect(placeholder, isA<just_audio.UriAudioSource>());
        expect(
          (placeholder as just_audio.UriAudioSource).uri.toString(),
          isEmpty,
        );

        // _resolveTrack still maps index 2 -> playlist[2] (s2).
        final states = <PlaybackState>[];
        final sub = harness.engine.playbackStateStream.listen(states.add);
        harness.player.emitCurrentIndex(2);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(states.last.currentTrack?.id, 's2');
        await sub.cancel();
      },
    );

    test('canReusePlaylist refuses the seek-reuse path while a fill is in '
        'flight', () async {
      final harness = _Harness(trackCount: 4);
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      addTearDown(harness.dispose);

      var tappedId = 's1';
      final blocked = <String>{'s2', 's3'};
      harness.buildOverride = (song) async {
        if (blocked.contains(song.id) && song.id != tappedId) {
          await gate.future;
        }
        return harness.immediateSource(song);
      };

      // First load taps s1; the fill inserts s0, then parks on s2.
      await harness.engine.load(harness.playlist[1]);
      await _pumpUntil(() => harness.player.sequence.length == 2);
      expect(harness.player.sequence[0], same(harness.sourcesById['s0']));
      expect(harness.player.sequence[1], same(harness.sourcesById['s1']));

      // Second load with the IDENTICAL playlist taps s2. The seek-reuse
      // path would seek index 2 on the partially-filled 2-child concat;
      // the in-flight fill must force a fresh phase-1 rebuild instead.
      tappedId = 's2';
      blocked
        ..clear()
        ..addAll({'s0', 's3'});
      await harness.engine.load(harness.playlist[2]);

      // Fresh rebuild: exactly one child (the newly tapped track), and
      // the indexed seek-reuse path was never taken.
      expect(harness.player.sequence, hasLength(1));
      expect(harness.player.sequence.first, same(harness.sourcesById['s2']));
      expect(harness.player.seekIndices, isNot(contains(2)));
    });

    test('backgroundFillDelay delays background track prebuffering', () async {
      final harness = _Harness(
        trackCount: 3,
        backgroundFillDelay: const Duration(milliseconds: 150),
      );
      addTearDown(harness.dispose);

      await harness.engine.load(harness.playlist[0]);

      // Phase 1 finished: only the tapped track is present.
      expect(harness.player.sequence, hasLength(1));

      // After 50ms (well within the 150ms delay window), background fill has not started.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(harness.player.sequence, hasLength(1));

      // After the delay elapses, background fill finishes and inserts the remaining tracks.
      await _pumpUntil(() => harness.player.sequence.length == 3);
      expect(harness.player.sequence, hasLength(3));
    });

    test('backgroundFillDelay cancels cleanly when superseded during delay window', () async {
      final harness = _Harness(
        trackCount: 3,
        backgroundFillDelay: const Duration(milliseconds: 150),
      );
      addTearDown(harness.dispose);

      await harness.engine.load(harness.playlist[0]);
      expect(harness.player.sequence, hasLength(1));

      // 40ms in, user taps track 2 before gen 1's delay finishes.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await harness.engine.load(harness.playlist[2]);

      // At this point gen 2 is active and waiting on its own 150ms delay.
      expect(harness.player.sequence, hasLength(1));
      expect(harness.player.sequence.first, same(harness.sourcesById['s2']));

      // Wait until gen 1's original 150ms would have fired (e.g. at 120ms from now).
      // Gen 1 must NOT insert s0/s1 into gen 2's player.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(harness.player.sequence, hasLength(1));
      expect(harness.player.sequence.first, same(harness.sourcesById['s2']));

      // Eventually gen 2's delay completes and fills all 3 tracks.
      await _pumpUntil(() => harness.player.sequence.length == 3);
      expect(harness.player.sequence, hasLength(3));
    });
  });
}
