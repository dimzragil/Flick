import 'package:flutter_test/flutter_test.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/player_service.dart';

Song _testSong(String id) => Song(
  id: id,
  title: 'Track $id',
  artist: 'Artist',
  duration: const Duration(minutes: 3, seconds: 45),
  filePath: '/storage/emulated/0/Music/$id.flac',
  fileType: 'FLAC',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('calculateResumePosition', () {
    test(
      'uses capturedPosition when outgoing position was captured before engine switch (even if current is zero)',
      () {
        final captured = const Duration(seconds: 42);
        final current = Duration.zero; // Reset by outgoing engine teardown
        var restoredProviderCalled = false;

        final result = calculateResumePosition(
          capturedPosition: captured,
          currentPosition: current,
          restoredPositionProvider: () {
            restoredProviderCalled = true;
            return Duration.zero;
          },
        );

        expect(result, const Duration(seconds: 42));
        expect(restoredProviderCalled, isFalse);
      },
    );

    test(
      'falls back to currentPosition if capturedPosition is zero',
      () {
        final captured = Duration.zero;
        final current = const Duration(seconds: 15);
        var restoredProviderCalled = false;

        final result = calculateResumePosition(
          capturedPosition: captured,
          currentPosition: current,
          restoredPositionProvider: () {
            restoredProviderCalled = true;
            return Duration.zero;
          },
        );

        expect(result, const Duration(seconds: 15));
        expect(restoredProviderCalled, isFalse);
      },
    );

    test(
      'falls back to restoredPosition on app cold start when both captured and current are zero',
      () {
        final captured = Duration.zero;
        final current = Duration.zero;
        var restoredProviderCalled = false;

        final result = calculateResumePosition(
          capturedPosition: captured,
          currentPosition: current,
          restoredPositionProvider: () {
            restoredProviderCalled = true;
            return const Duration(minutes: 1, seconds: 20);
          },
        );

        expect(result, const Duration(minutes: 1, seconds: 20));
        expect(restoredProviderCalled, isTrue);
      },
    );

    test(
      'returns Duration.zero for first-time playback when no position was captured and no restored context exists',
      () {
        final result = calculateResumePosition(
          capturedPosition: Duration.zero,
          currentPosition: Duration.zero,
          restoredPositionProvider: () => Duration.zero,
        );

        expect(result, Duration.zero);
      },
    );
  });

  group('PlaybackPositionTracker and Playback restart bug simulation', () {
    late PlaybackPositionTracker tracker;
    final song = _testSong('song_first_time');

    setUp(() {
      tracker = PlaybackPositionTracker();
    });

    test(
      'first-time playback: engine switch preserves captured position even after outgoing engine teardown resets positionNotifier to zero',
      () {
        // 1. Simulate first-time playback: song is playing and reaches 25s
        final simulatedPlaybackPosition = const Duration(seconds: 25);
        var positionNotifierValue = simulatedPlaybackPosition;

        // 2. Pre-switch capture: position is captured before engine teardown
        final captured = tracker.captureCurrentPosition(
          songId: song.id,
          candidates: [positionNotifierValue],
        );
        expect(captured, simulatedPlaybackPosition);

        // 3. Engine switch triggered: outgoing engine is disposed (e.g. player.stop() in _disposeAndroidEngine)
        // This causes positionNotifier to be wiped back to zero
        positionNotifierValue = Duration.zero;

        // 4. Teardown resilience: verify that captureCurrentPosition still recovers
        // the in-flight playback position for this song even after candidates are wiped to zero
        final recoveredPosition = tracker.captureCurrentPosition(
          songId: song.id,
          candidates: [positionNotifierValue],
        );
        expect(recoveredPosition, simulatedPlaybackPosition);

        // 5. Calculate resume position: verify it does NOT restart from zero
        // In the bug, resumePosition became 0s because canResumeDirectly failed and positionNotifier was 0s
        final resumePosition = calculateResumePosition(
          capturedPosition: recoveredPosition,
          currentPosition: positionNotifierValue,
          restoredPositionProvider: () => Duration.zero, // First-time song has no restored context
        );

        expect(
          resumePosition,
          simulatedPlaybackPosition,
          reason:
              'playTrack must be called with non-zero initialPosition (25s) instead of restarting at Duration.zero',
        );
      },
    );

    test(
      'different track does not inherit previous track captured position',
      () {
        final songA = _testSong('song_a');
        final songB = _testSong('song_b');

        // Play song A at 30s
        tracker.captureCurrentPosition(
          songId: songA.id,
          candidates: [const Duration(seconds: 30)],
        );

        // Now evaluate song B (a different track)
        final capturedForB = tracker.captureCurrentPosition(
          songId: songB.id,
          candidates: [Duration.zero],
        );
        expect(
          capturedForB,
          Duration.zero,
          reason: 'A new track should start from zero, not inherit previous song position',
        );
      },
    );

    test(
      'seeking updates the captured position so post-seek engine switch resumes at seek target',
      () {
        tracker.captureCurrentPosition(
          songId: song.id,
          candidates: [const Duration(seconds: 10)],
        );

        // User seeks to 1m 45s
        final seekTarget = const Duration(minutes: 1, seconds: 45);
        tracker.onSeek(songId: song.id, position: seekTarget);

        // Transient candidate reset to zero during engine teardown
        final capturedAfterSeek = tracker.captureCurrentPosition(
          songId: song.id,
          candidates: [Duration.zero],
        );
        expect(capturedAfterSeek, seekTarget);
      },
    );

    test(
      'song finish resets captured position to zero',
      () {
        tracker.captureCurrentPosition(
          songId: song.id,
          candidates: [const Duration(seconds: 100)],
        );
        tracker.onSongFinished();

        final captured = tracker.captureCurrentPosition(
          songId: song.id,
          candidates: [Duration.zero],
        );
        expect(captured, Duration.zero);
      },
    );

    test(
      'playTrack simulation: engine switch calls playTrack with non-zero initialPosition',
      () async {
        // Full simulation of _resumeInternal() logic on engine switch:
        final currentPosition = const Duration(seconds: 35);
        tracker.recordPosition(songId: song.id, position: currentPosition);

        // Outgoing position captured before engine switch:
        final outgoingPosition = tracker.captureCurrentPosition(
          songId: song.id,
          candidates: [currentPosition],
        );

        // Switch engine: active engine changes, outgoing player disposed -> positionNotifier reset to 0
        const positionAfterTeardown = Duration.zero;

        Duration? playedTrackPosition;
        Future<void> simulatePlayTrack(Song s, {required Duration initialPosition}) async {
          playedTrackPosition = initialPosition;
        }

        Future<void> simulateResume({
          required bool canResumeDirectly,
          required Duration outgoingPosition,
          required Duration currentPosition,
        }) async {
          if (canResumeDirectly) {
            playedTrackPosition = currentPosition;
          } else {
            final resumePosition = calculateResumePosition(
              capturedPosition: outgoingPosition,
              currentPosition: currentPosition,
              restoredPositionProvider: () => Duration.zero,
            );
            await simulatePlayTrack(song, initialPosition: resumePosition);
          }
        }

        await simulateResume(
          canResumeDirectly: false, // Engine switched
          outgoingPosition: outgoingPosition,
          currentPosition: positionAfterTeardown,
        );

        expect(playedTrackPosition, const Duration(seconds: 35));
      },
    );
  });
}
