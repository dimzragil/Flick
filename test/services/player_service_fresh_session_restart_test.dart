import 'package:flutter_test/flutter_test.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/player_service.dart';

Song _testSong(String id) => Song(
  id: id,
  title: 'Track $id',
  artist: 'Tidal Artist',
  duration: const Duration(minutes: 3, seconds: 45),
  filePath: 'http://127.0.0.1:4040/stream/$id.flac',
  fileType: 'FLAC',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Fresh session playback restart protection', () {
    test(
      'initial route evaluation on fresh session skips speaker sink rearm',
      () {
        const baselineRoute = '23053RN02A';

        // On cold app launch, previous signature is null before evaluation.
        // It must NOT trigger a destructive rearm of the audio sink.
        final skipInitial = shouldSkipSpeakerSinkRearmForSpuriousRoute(
          previousRouteSignature: null,
          currentRouteSignature: baselineRoute,
        );
        expect(
          skipInitial,
          isTrue,
          reason: 'Initial baseline route must not trigger a destructive rearm',
        );

        // If previous signature was 'unknown' before Android service reported device info:
        final skipFromUnknown = shouldSkipSpeakerSinkRearmForSpuriousRoute(
          previousRouteSignature: 'unknown',
          currentRouteSignature: baselineRoute,
        );
        expect(
          skipFromUnknown,
          isTrue,
          reason: 'Transition from unknown placeholder must not trigger rearm',
        );

        // When user pulls notification shade or opens audio settings,
        // routeSummary is reported again as '23053RN02A':
        final skipDuplicate = shouldSkipSpeakerSinkRearmForSpuriousRoute(
          previousRouteSignature: baselineRoute,
          currentRouteSignature: baselineRoute,
        );
        expect(
          skipDuplicate,
          isTrue,
          reason: 'Spurious repeated route notification must skip rearm',
        );
      },
    );

    test(
      'real route change from external device to speaker still triggers rearm',
      () {
        const baselineRoute = '23053RN02A';

        // Disconnecting bluetooth or wired headset transitions back to internal speaker:
        final skipFromBt = shouldSkipSpeakerSinkRearmForSpuriousRoute(
          previousRouteSignature: 'bluetooth',
          currentRouteSignature: baselineRoute,
        );
        expect(
          skipFromBt,
          isFalse,
          reason: 'Genuine transition from bluetooth to speaker must allow rearm',
        );

        final skipFromWired = shouldSkipSpeakerSinkRearmForSpuriousRoute(
          previousRouteSignature: 'Wired headphones',
          currentRouteSignature: baselineRoute,
        );
        expect(
          skipFromWired,
          isFalse,
          reason: 'Genuine transition from wired to speaker must allow rearm',
        );
      },
    );

    test(
      'app resume with trivial backgrounding skips speaker sink rearm',
      () {
        final now = DateTime(2026, 10, 8, 12, 0, 5);
        final backgroundedAt = DateTime(2026, 10, 8, 12, 0, 0); // 5s ago

        final skip = shouldSkipSpeakerSinkRearmForTrivialBackground(
          backgroundedAt: backgroundedAt,
          now: now,
        );
        expect(
          skip,
          isTrue,
          reason: 'Notification shade peek (5s) must skip rearm',
        );
      },
    );

    test(
      'playback tracker preserves captured position across transient error retries',
      () {
        final tracker = PlaybackPositionTracker();
        final song = _testSong('tidal_stream_track');
        final currentPosition = const Duration(seconds: 18);

        // Record position while playing
        tracker.recordPosition(songId: song.id, position: currentPosition);

        // When a transient playback error occurs, capture position before retrying
        final captured = tracker.captureCurrentPosition(
          songId: song.id,
          candidates: [currentPosition],
        );
        expect(captured, const Duration(seconds: 18));

        // When retry starts with initialPosition, captureCurrentPosition seeds tracker
        final retryPosition = tracker.captureCurrentPosition(
          songId: song.id,
          candidates: [captured],
        );
        expect(
          retryPosition,
          const Duration(seconds: 18),
          reason: 'Retry must resume from captured position rather than resetting to 0',
        );
      },
    );
  });
}
