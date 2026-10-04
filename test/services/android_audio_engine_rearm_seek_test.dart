import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as just_audio;

import 'package:flick/models/song.dart';
import 'package:flick/services/android_audio_engine.dart';

/// Fake player with switchable dropped-seek behavior: when [dropSeek] is
/// true, [seek] completes without throwing but never moves [position],
/// mimicking just_audio silently discarding a seek issued while the player
/// is still loading.
class _DropSeekAudioPlayer implements just_audio.AudioPlayer {
  /// When true, [seek] completes without throwing but never moves [position],
  /// mimicking just_audio silently discarding a seek issued while the player
  /// is still loading.
  bool dropSeek = false;
  Duration _position = Duration.zero;
  just_audio.AudioSource? _source;
  bool _playing = false;

  final List<String> callLog = [];
  final List<Duration> seekPositions = [];

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
    _source = audioSource;
    return null;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    final pos = position ?? Duration.zero;
    callLog.add('seek:${pos.inMilliseconds}');
    seekPositions.add(pos);
    if (!dropSeek) {
      _position = pos;
    }
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

/// Runs [body] while capturing everything routed through [print]
/// (devLog and debugPrintStack both end up there in tests) and returns the
/// captured lines.
Future<List<String>> _capturePrint(Future<void> Function() body) async {
  final lines = <String>[];
  await runZonedGuarded(
    () => body(),
    (Object error, StackTrace stack) {},
    zoneSpecification: ZoneSpecification(
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
        lines.add(line);
      },
    ),
  );
  return lines;
}

void main() {
  group('AndroidAudioEngine rearm seek verification', () {
    late _DropSeekAudioPlayer fakePlayer;
    late AndroidAudioEngine engine;
    late List<Song> playlist;

    setUp(() {
      fakePlayer = _DropSeekAudioPlayer();
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
      'rearm seek that sticks is not retried and logs nothing loud',
      () async {
        const target = Duration(seconds: 45);
        await engine.load(playlist[0]);

        final lines = await _capturePrint(
          () => engine.rearmSink(targetPosition: target),
        );

        final targetSeeks = fakePlayer.seekPositions
            .where((p) => p == target)
            .toList();
        expect(
          targetSeeks,
          hasLength(1),
          reason: 'a stuck seek must not be retried',
        );
        expect(
          lines.any((l) => l.contains('rearmSink seek FAILED')),
          isFalse,
          reason: 'no loud log on the happy path',
        );
        expect(
          lines.any((l) => l.contains('rearmSink seek discarded')),
          isFalse,
          reason: 'no retry log on the happy path',
        );
      },
    );

    test('dropped rearm seek is retried once then logged loudly', () async {
      const target = Duration(seconds: 45);
      fakePlayer.dropSeek = true;
      await engine.load(playlist[0]);

      final lines = await _capturePrint(
        () => engine.rearmSink(targetPosition: target),
      );

      final targetSeeks = fakePlayer.seekPositions
          .where((p) => p == target)
          .toList();
      expect(
        targetSeeks,
        hasLength(2),
        reason: 'a dropped seek must be retried exactly once',
      );
      expect(
        lines.any((l) => l.contains('rearmSink seek discarded')),
        isTrue,
        reason: 'the dropped first seek must be logged',
      );
      expect(
        lines.any((l) => l.contains('rearmSink seek FAILED to stick')),
        isTrue,
        reason: 'the loud log path must be hit when the retry also fails',
      );
      expect(
        lines.any((l) => l.contains('#0')),
        isTrue,
        reason: 'debugPrintStack must have emitted a stack trace',
      );
    });
  });
}
