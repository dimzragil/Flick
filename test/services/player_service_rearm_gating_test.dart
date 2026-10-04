import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/player_service.dart';

/// Gating decisions for the speaker-sink rearm in `_rearmSpeakerSinkIfNeeded`.
///
/// These tests pin the two pure decision helpers:
/// - `shouldSkipSpeakerSinkRearmForSpuriousRoute`: skip rearm when an
///   'audio route changed' notification fires but the route identity is
///   unchanged since the last evaluation.
/// - `shouldSkipSpeakerSinkRearmForTrivialBackground`: skip rearm on 'app
///   resumed' when the app was backgrounded for less than ~10s
///   (notification-shade peeks must not nuke playback).
///
/// Conservative contract (BALANCE): when in doubt the helpers return false
/// and the rearm still fires — a brief gap beats permanent HAL-wedge silence.
void main() {
  group('shouldSkipSpeakerSinkRearmForSpuriousRoute', () {
    test(
      'skips rearm when route identity is unchanged (spurious notification)',
      () {
        // Log evidence: repeated 'audio route changed' events with
        // route=23053RN02A while mode stayed NORMAL_ANDROID.
        expect(
          shouldSkipSpeakerSinkRearmForSpuriousRoute(
            previousRouteSignature: '23053RN02A',
            currentRouteSignature: '23053RN02A',
          ),
          isTrue,
        );
      },
    );

    test('rearm fires on a real route change (speaker -> USB DAC)', () {
      expect(
        shouldSkipSpeakerSinkRearmForSpuriousRoute(
          previousRouteSignature: '23053RN02A',
          currentRouteSignature: 'usb',
        ),
        isFalse,
      );
    });

    test('rearm fires on a real route change (speaker -> bluetooth)', () {
      expect(
        shouldSkipSpeakerSinkRearmForSpuriousRoute(
          previousRouteSignature: '23053RN02A',
          currentRouteSignature: 'bluetooth',
        ),
        isFalse,
      );
    });

    test(
      'rearm fires when no previous signature was ever evaluated (cannot prove spurious)',
      () {
        expect(
          shouldSkipSpeakerSinkRearmForSpuriousRoute(
            previousRouteSignature: null,
            currentRouteSignature: '23053RN02A',
          ),
          isFalse,
        );
      },
    );

    test(
      'rearm fires when the route label changed within the same route type',
      () {
        expect(
          shouldSkipSpeakerSinkRearmForSpuriousRoute(
            previousRouteSignature: 'Speaker',
            currentRouteSignature: 'Wired headphones',
          ),
          isFalse,
        );
      },
    );
  });

  group('shouldSkipSpeakerSinkRearmForTrivialBackground', () {
    final t0 = DateTime(2026, 10, 4, 23, 0, 0);
    const threshold = Duration(seconds: 10);

    test('skips rearm on a 2s notification-shade peek', () {
      expect(
        shouldSkipSpeakerSinkRearmForTrivialBackground(
          backgroundedAt: t0,
          now: t0.add(const Duration(seconds: 2)),
          threshold: threshold,
        ),
        isTrue,
      );
    });

    test('skips rearm just under the 10s threshold', () {
      expect(
        shouldSkipSpeakerSinkRearmForTrivialBackground(
          backgroundedAt: t0,
          now: t0.add(const Duration(milliseconds: 9999)),
          threshold: threshold,
        ),
        isTrue,
      );
    });

    test('rearm DOES fire after genuine 15s backgrounding', () {
      expect(
        shouldSkipSpeakerSinkRearmForTrivialBackground(
          backgroundedAt: t0,
          now: t0.add(const Duration(seconds: 15)),
          threshold: threshold,
        ),
        isFalse,
      );
    });

    test(
      'rearm DOES fire at exactly the 10s threshold (boundary: >= fires)',
      () {
        expect(
          shouldSkipSpeakerSinkRearmForTrivialBackground(
            backgroundedAt: t0,
            now: t0.add(const Duration(seconds: 10)),
            threshold: threshold,
          ),
          isFalse,
        );
      },
    );

    test('rearm DOES fire after minutes of backgrounding', () {
      expect(
        shouldSkipSpeakerSinkRearmForTrivialBackground(
          backgroundedAt: t0,
          now: t0.add(const Duration(minutes: 5)),
          threshold: threshold,
        ),
        isFalse,
      );
    });

    test(
      'rearm DOES fire when background timestamp is unknown (cannot prove trivial)',
      () {
        expect(
          shouldSkipSpeakerSinkRearmForTrivialBackground(
            backgroundedAt: null,
            now: t0,
            threshold: threshold,
          ),
          isFalse,
        );
      },
    );

    test('uses the default 10s threshold when not specified', () {
      expect(
        shouldSkipSpeakerSinkRearmForTrivialBackground(
          backgroundedAt: t0,
          now: t0.add(const Duration(seconds: 5)),
        ),
        isTrue,
      );
      expect(
        shouldSkipSpeakerSinkRearmForTrivialBackground(
          backgroundedAt: t0,
          now: t0.add(const Duration(seconds: 30)),
        ),
        isFalse,
      );
    });
  });
}
