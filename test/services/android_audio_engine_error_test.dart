import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as just_audio;

import 'package:flick/models/playback_state.dart';
import 'package:flick/services/android_audio_engine.dart';

/// Minimal just_audio.AudioPlayer stand-in for the error path.
///
/// Only the members [AndroidAudioEngine] touches on the `play()` path are
/// implemented (the nine listened streams plus `play()`); everything else
/// falls through to [noSuchMethod] and is never called. A real AudioPlayer
/// cannot be constructed in unit tests (its constructor hits the platform
/// channel via AudioSession), and just_audio offers no public way to inject
/// a [just_audio.PlayerException] into `errorStream`, so this fake drives the
/// engine's private errorStream listener directly — the exact code path that
/// runs on-device when ExoPlayer reports a playback failure.
class _FakeAudioPlayer implements just_audio.AudioPlayer {
  final StreamController<just_audio.PlayerException> errorController =
      StreamController<just_audio.PlayerException>.broadcast();

  @override
  Stream<just_audio.PlayerException> get errorStream => errorController.stream;

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
  Future<void> play() => Future<void>.value();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('AndroidAudioEngine playback error forwarding', () {
    late _FakeAudioPlayer fakePlayer;
    late AndroidAudioEngine engine;

    setUp(() {
      fakePlayer = _FakeAudioPlayer();
      engine = AndroidAudioEngine(
        playerProvider: () async => fakePlayer,
        sourceBuilder: (_, {bool deferPump = false}) =>
            throw UnimplementedError(),
        playlistProvider: () => const [],
        configurePlayer: (_) async {},
        disposeEngine: () async {},
        shouldSuppressTrackSync: () => false,
        shouldIgnoreTrack: (_) => false,
        shouldFastStartCurrentTrackOnly: () => false,
      );
    });

    tearDown(() async {
      await engine.dispose();
      await fakePlayer.errorController.close();
    });

    test('errorStream event forwards code/message/index to onPlaybackError '
        'and sets PlaybackState.errorMessage', () async {
      // play() runs _ensurePlayer(), which attaches the errorStream listener.
      await engine.play();

      AndroidPlaybackError? received;
      engine.onPlaybackError = (details) => received = details;

      final states = <PlaybackState>[];
      final sub = engine.playbackStateStream.listen(states.add);

      fakePlayer.errorController.add(
        just_audio.PlayerException(1001, 'Source error', 2),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(received, isNotNull);
      expect(received!.code, 1001);
      expect(received!.message, 'Source error');
      expect(received!.index, 2);
      expect(states, isNotEmpty);
      expect(states.last.errorMessage, 'Source error');
      await sub.cancel();
    });

    test('null just_audio message falls back to a generic message', () async {
      await engine.play();

      AndroidPlaybackError? received;
      engine.onPlaybackError = (details) => received = details;
      final states = <PlaybackState>[];
      final sub = engine.playbackStateStream.listen(states.add);

      fakePlayer.errorController.add(just_audio.PlayerException(7, null, null));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(received, isNotNull);
      expect(received!.code, 7);
      expect(received!.message, 'Unknown playback error');
      expect(received!.index, isNull);
      expect(states, isNotEmpty);
      expect(states.last.errorMessage, 'Unknown playback error');
      await sub.cancel();
    });

    test(
      'no callback set: error still updates state without throwing',
      () async {
        await engine.play();

        final states = <PlaybackState>[];
        final sub = engine.playbackStateStream.listen(states.add);

        fakePlayer.errorController.add(
          just_audio.PlayerException(5, 'x', null),
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(states, isNotEmpty);
        expect(states.last.errorMessage, 'x');
        await sub.cancel();
      },
    );
  });
}
