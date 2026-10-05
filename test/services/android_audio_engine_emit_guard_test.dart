import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as just_audio;

import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/models/playback_state.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/android_audio_engine.dart';

class _FakeAudioPlayer implements just_audio.AudioPlayer {
  @override
  Stream<just_audio.PlayerState> get playerStateStream =>
      const Stream<just_audio.PlayerState>.empty();

  @override
  Stream<just_audio.PlaybackEvent> get playbackEventStream =>
      const Stream<just_audio.PlaybackEvent>.empty();

  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();

  @override
  Stream<Duration?> get durationStream => const Stream<Duration?>.empty();

  @override
  Stream<Duration> get bufferedPositionStream => const Stream<Duration>.empty();

  @override
  Stream<int?> get currentIndexStream => const Stream<int?>.empty();

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
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('AndroidAudioEngine _emit disposed guard', () {
    test('emits state when active, and safely drops emit after dispose()', () async {
      final fakePlayer = _FakeAudioPlayer();
      var disposedCalls = 0;

      final engine = AndroidAudioEngine(
        playerProvider: () async => fakePlayer,
        sourceBuilder: (song) async =>
            just_audio.AudioSource.uri(Uri.parse('asset:///${song.id}')),
        playlistProvider: () => const <Song>[],
        configurePlayer: (_) async {},
        disposeEngine: () async {
          disposedCalls++;
        },
        shouldSuppressTrackSync: () => false,
        shouldIgnoreTrack: (_) => false,
        shouldFastStartCurrentTrackOnly: () => false,
        crossfadeConfigProvider: () => AndroidCrossfadeConfig.disabled,
      );

      final states = <PlaybackState>[];
      final sub = engine.playbackStateStream.listen(states.add);

      expect(engine.isDisposed, isFalse);

      final state1 = PlaybackState.empty(AudioEngineType.normalAndroid).copyWith(
        isPlaying: true,
      );
      engine.emitForTesting(state1);

      await pumpEventQueue();
      expect(states.length, 1);
      expect(states.first.isPlaying, isTrue);

      // Dispose engine
      await engine.dispose();
      expect(engine.isDisposed, isTrue);
      expect(disposedCalls, 1);

      // Subsequent emit on disposed engine must not throw BadState: Cannot add event after closing
      final state2 = state1.copyWith(isPlaying: false);
      expect(() => engine.emitForTesting(state2), returnsNormally);

      await pumpEventQueue();
      // No new state was emitted
      expect(states.length, 1);

      // Calling dispose again is a safe idempotent no-op
      await engine.dispose();
      expect(disposedCalls, 1);

      await sub.cancel();
    });
  });
}
