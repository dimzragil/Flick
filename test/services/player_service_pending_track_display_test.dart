import 'package:flutter/foundation.dart';
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

/// Replays engine playback-state emissions against
/// [PendingTrackRequestTracker] using the exact wiring of
/// `PlayerService._bindPlaybackState`:
///
/// 1. resolve the displayed song (suppressing stale reports while a request
///    is pending, preserving the song across null-track transitional states
///    when the playlist is populated),
/// 2. write [ValueNotifier] when it changed,
/// 3. confirm the pending request against the engine track,
/// 4. clear the tracker when playback is fully cleared.
class _TrackDisplayHarness {
  final ValueNotifier<Song?> notifier = ValueNotifier<Song?>(null);
  final PendingTrackRequestTracker tracker = PendingTrackRequestTracker();

  /// What the UI displayed after every step (tap or engine emission).
  final List<String?> observed = [];

  /// Mirrors the eager `currentSongNotifier.value = song;
  /// _pendingTrackRequest.mark(song);` pair from play(),
  /// _playSongAtCurrentIndex(), next() and previous().
  void tapTrack(Song song) {
    tracker.mark(song);
    notifier.value = song;
    observed.add(song.id);
  }

  void onEngineState(Song? engineTrack, {bool playlistIsNotEmpty = true}) {
    final incoming = tracker.resolve(
      engineTrack: engineTrack,
      uiSong: notifier.value,
      playlistIsNotEmpty: playlistIsNotEmpty,
    );
    if (notifier.value != incoming) {
      notifier.value = incoming;
    }
    tracker.confirm(engineTrack);
    if (notifier.value == null) {
      tracker.clear();
    }
    observed.add(notifier.value?.id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PendingTrackRequestTracker', () {
    late _TrackDisplayHarness harness;
    late Song songA;
    late Song songB;
    late Song songC;

    setUp(() {
      harness = _TrackDisplayHarness();
      songA = _testSong('a');
      songB = _testSong('b');
      songC = _testSong('c');
    });

    List<String?> displayedIdsAfterFirstTapOf(String id) {
      final firstIndex = harness.observed.indexOf(id);
      expect(firstIndex, isNot(-1), reason: 'track $id was never displayed');
      // Skip the single eager-tap entry; every engine emission after it must
      // keep showing the tapped song until the engine confirms it.
      return harness.observed.sublist(firstIndex + 1);
    }

    test(
      'track change never flashes back to the old song while the new one loads',
      () {
        // Song A is loaded and playing; the engine confirms it.
        harness.onEngineState(songA);

        // User taps uncached song B: UI updates immediately (0ms eager write).
        harness.tapTrack(songB);
        expect(harness.notifier.value?.id, 'b');

        // The bug window: play() pauses the engine and the new source takes
        // seconds to resolve. Every emission still reports song A, plus the
        // null-track transitional state when the engine reattaches.
        harness.onEngineState(songA);
        harness.onEngineState(songA);
        harness.onEngineState(null);
        harness.onEngineState(songA);

        // The full player must still show B — new -> old -> new must not happen.
        expect(harness.notifier.value?.id, 'b');

        // B finishes loading: engine confirms it.
        harness.onEngineState(songB);
        expect(harness.notifier.value?.id, 'b');

        // Nothing after the tap ever briefly held A.
        expect(displayedIdsAfterFirstTapOf('b'), everyElement('b'));
      },
    );

    test(
      'original failing sequence is reproduced without the pending marker',
      () {
        // Negative control proving the test above catches the reported bug:
        // with only the eager write (pre-fix behavior) the engine's stale
        // pause emission carrying A overwrites the notifier.
        harness.onEngineState(songA);
        harness.notifier.value = songB; // eager write only, no mark()
        harness.onEngineState(songA);

        expect(
          harness.notifier.value?.id,
          'a',
          reason: 'without the tracker the stale emission flips back to A',
        );
      },
    );

    test('the pending request clears once the engine confirms the track', () {
      harness.onEngineState(songA);
      harness.tapTrack(songB);
      expect(harness.tracker.isPending, isTrue);

      harness.onEngineState(songB);
      expect(harness.tracker.isPending, isFalse);

      // A later genuine engine change (e.g. gapless advance) is authoritative.
      harness.onEngineState(songC);
      expect(harness.notifier.value?.id, 'c');
    });

    test('a newer request supersedes the pending one (rapid taps)', () {
      harness.onEngineState(songA);
      harness.tapTrack(songB);
      harness.tapTrack(songC);

      // Stale emissions of both earlier tracks are suppressed.
      harness.onEngineState(songA);
      harness.onEngineState(songB);
      expect(harness.notifier.value?.id, 'c');

      harness.onEngineState(songC);
      expect(harness.tracker.isPending, isFalse);
      expect(harness.notifier.value?.id, 'c');
    });

    test('null-track transitional states keep the last song while queued', () {
      harness.onEngineState(songA);
      harness.tapTrack(songB);
      harness.onEngineState(songB);

      harness.onEngineState(null);
      expect(harness.notifier.value?.id, 'b');
      expect(harness.tracker.isPending, isFalse);
    });

    test('null-track state with an empty playlist truly clears playback', () {
      harness.onEngineState(songA);
      harness.tapTrack(songB);

      harness.onEngineState(null, playlistIsNotEmpty: false);
      expect(harness.notifier.value, isNull);
      expect(harness.tracker.isPending, isFalse);
    });

    test('fail() drops only the failed song request', () {
      harness.tracker.mark(songB);
      harness.tracker.fail(songC);
      expect(harness.tracker.isPending, isTrue);

      harness.tracker.fail(songB);
      expect(harness.tracker.isPending, isFalse);
    });

    test('clear() (forced sync) makes engine states authoritative again', () {
      harness.onEngineState(songA);
      harness.tapTrack(songB);

      harness.tracker.clear();
      harness.onEngineState(songA);
      expect(harness.notifier.value?.id, 'a');
    });

    test('same-song re-request keeps being displayed without flicker', () {
      harness.onEngineState(songA);
      harness.tapTrack(songB);
      harness.onEngineState(songB);

      // Replay the same track: eager write + mark again.
      harness.tapTrack(songB);
      // The engine (still on B) confirms immediately.
      harness.onEngineState(songB);
      expect(harness.tracker.isPending, isFalse);
      expect(harness.notifier.value?.id, 'b');
      expect(displayedIdsAfterFirstTapOf('b'), isNot(contains('a')));
    });
  });
}
