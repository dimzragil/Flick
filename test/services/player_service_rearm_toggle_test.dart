import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/player_service.dart';

void main() {
  group('shouldExecuteTogglePlayPause', () {
    test('executes when user wants to play and currently paused', () {
      expect(
        shouldExecuteTogglePlayPause(
          isPlaying: false,
          targetShouldPlay: true,
        ),
        isTrue,
      );
    });

    test('executes when user wants to pause and currently playing', () {
      expect(
        shouldExecuteTogglePlayPause(
          isPlaying: true,
          targetShouldPlay: false,
        ),
        isTrue,
      );
    });

    test('skips execution when playback already matches desired play intent (prevents inversion)', () {
      expect(
        shouldExecuteTogglePlayPause(
          isPlaying: true,
          targetShouldPlay: true,
        ),
        isFalse,
      );
    });

    test('skips execution when playback already matches desired pause intent', () {
      expect(
        shouldExecuteTogglePlayPause(
          isPlaying: false,
          targetShouldPlay: false,
        ),
        isFalse,
      );
    });
  });

  group('shouldThrottleSpeakerSinkRearm', () {
    final t0 = DateTime(2026, 10, 4, 12, 0, 0);

    test('allows initial rearm when not queued and no prior rearm', () {
      expect(
        shouldThrottleSpeakerSinkRearm(
          isQueued: false,
          lastRearmTime: null,
          now: t0,
        ),
        isFalse,
      );
    });

    test('throttles when a rearm is already queued in-flight', () {
      expect(
        shouldThrottleSpeakerSinkRearm(
          isQueued: true,
          lastRearmTime: null,
          now: t0,
        ),
        isTrue,
      );
    });

    test('throttles when secondary event fires 12ms after first (screen unlock coalescing)', () {
      final t1 = t0.add(const Duration(milliseconds: 12));
      expect(
        shouldThrottleSpeakerSinkRearm(
          isQueued: false,
          lastRearmTime: t0,
          now: t1,
        ),
        isTrue,
      );
    });

    test('throttles within 2-second cooldown window', () {
      final tAlmostTwoSec = t0.add(const Duration(milliseconds: 1950));
      expect(
        shouldThrottleSpeakerSinkRearm(
          isQueued: false,
          lastRearmTime: t0,
          now: tAlmostTwoSec,
        ),
        isTrue,
      );
    });

    test('allows new rearm after cooldown window expires', () {
      final tAfterCooldown = t0.add(const Duration(milliseconds: 2100));
      expect(
        shouldThrottleSpeakerSinkRearm(
          isQueued: false,
          lastRearmTime: t0,
          now: tAfterCooldown,
        ),
        isFalse,
      );
    });

    test('respects custom cooldown duration', () {
      const customCooldown = Duration(seconds: 5);
      final tThreeSec = t0.add(const Duration(seconds: 3));
      final tSixSec = t0.add(const Duration(seconds: 6));

      expect(
        shouldThrottleSpeakerSinkRearm(
          isQueued: false,
          lastRearmTime: t0,
          now: tThreeSec,
          cooldown: customCooldown,
        ),
        isTrue,
      );

      expect(
        shouldThrottleSpeakerSinkRearm(
          isQueued: false,
          lastRearmTime: t0,
          now: tSixSec,
          cooldown: customCooldown,
        ),
        isFalse,
      );
    });
  });
}
