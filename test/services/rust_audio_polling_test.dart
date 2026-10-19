import 'package:flutter_test/flutter_test.dart';

import 'package:flick/services/rust_audio_service.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Cadence decision statics
  // ---------------------------------------------------------------------------

  group('progressInterval', () {
    test('foreground playing stays at 50ms (UI smoothness contract)', () {
      expect(
        RustAudioService.progressInterval(
          playing: true,
          appInBackground: false,
        ),
        const Duration(milliseconds: 50),
      );
    });

    test('foreground paused relaxes to 250ms', () {
      expect(
        RustAudioService.progressInterval(
          playing: false,
          appInBackground: false,
        ),
        const Duration(milliseconds: 250),
      );
    });

    test('background always throttles to 1500ms (documented intent)', () {
      expect(
        RustAudioService.progressInterval(playing: true, appInBackground: true),
        const Duration(milliseconds: 1500),
      );
      expect(
        RustAudioService.progressInterval(
          playing: false,
          appInBackground: true,
        ),
        const Duration(milliseconds: 1500),
      );
    });
  });

  group('isTrackEndImminent', () {
    test('within the window of a known duration → true', () {
      expect(
        RustAudioService.isTrackEndImminent(
          position: const Duration(seconds: 28),
          duration: const Duration(seconds: 30),
          crossfading: false,
        ),
        isTrue,
      );
    });

    test('just outside the window → false', () {
      expect(
        RustAudioService.isTrackEndImminent(
          position: const Duration(seconds: 26, milliseconds: 900),
          duration: const Duration(seconds: 30),
          crossfading: false,
        ),
        isFalse,
      );
    });

    test('exactly at the window boundary → true', () {
      expect(
        RustAudioService.isTrackEndImminent(
          position: const Duration(seconds: 27),
          duration: const Duration(seconds: 30),
          crossfading: false,
        ),
        isTrue,
      );
    });

    test('zero/unknown duration never accelerates (HTTP streams)', () {
      expect(
        RustAudioService.isTrackEndImminent(
          position: const Duration(seconds: 120),
          duration: Duration.zero,
          crossfading: false,
        ),
        isFalse,
      );
    });

    test('seek past the end (negative remaining) → false', () {
      expect(
        RustAudioService.isTrackEndImminent(
          position: const Duration(seconds: 31),
          duration: const Duration(seconds: 30),
          crossfading: false,
        ),
        isFalse,
      );
    });

    test('crossfading always forces the fast cadence', () {
      expect(
        RustAudioService.isTrackEndImminent(
          position: const Duration(seconds: 1),
          duration: const Duration(seconds: 30),
          crossfading: true,
        ),
        isTrue,
      );
      expect(
        RustAudioService.isTrackEndImminent(
          position: Duration.zero,
          duration: Duration.zero,
          crossfading: true,
        ),
        isTrue,
      );
    });
  });

  group('eventInterval', () {
    test('foreground steady state drops to 250ms', () {
      expect(
        RustAudioService.eventInterval(
          appInBackground: false,
          trackEndImminent: false,
        ),
        const Duration(milliseconds: 250),
      );
    });

    test('approaching track end races to 50ms', () {
      expect(
        RustAudioService.eventInterval(
          appInBackground: false,
          trackEndImminent: true,
        ),
        const Duration(milliseconds: 50),
      );
    });

    test('background throttles to 500ms regardless of track end', () {
      expect(
        RustAudioService.eventInterval(
          appInBackground: true,
          trackEndImminent: true,
        ),
        const Duration(milliseconds: 500),
      );
      expect(
        RustAudioService.eventInterval(
          appInBackground: true,
          trackEndImminent: false,
        ),
        const Duration(milliseconds: 500),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Instance-level cadence wiring (no engine required; the timers created
  // here never fire inside these tests — the test ends before any interval
  // elapses — so no FFI call is ever made. debugCancelPollTimers releases
  // the timers without poisoning the singleton's notifiers for later tests.)
  // ---------------------------------------------------------------------------

  group('event poll cadence wiring', () {
    test('steady state syncs to 250ms', () {
      final service = RustAudioService();
      service.debugSyncEventPolling();
      expect(service.debugEventPollInterval, const Duration(milliseconds: 250));
      service.debugCancelPollTimers();
    });

    test(
      'accelerates within the track-end window and recovers after a switch',
      () {
        final service = RustAudioService();
        service.durationNotifier.value = const Duration(seconds: 30);
        service.positionNotifier.value = const Duration(seconds: 5);
        service.debugSyncEventPolling();
        expect(
          service.debugEventPollInterval,
          const Duration(milliseconds: 250),
        );

        service.positionNotifier.value = const Duration(seconds: 28);
        service.debugSyncEventPolling();
        expect(
          service.debugEventPollInterval,
          const Duration(milliseconds: 50),
          reason: '3s or less to the track boundary → fast cadence',
        );

        service.positionNotifier.value = const Duration(seconds: 2);
        service.debugSyncEventPolling();
        expect(
          service.debugEventPollInterval,
          const Duration(milliseconds: 250),
          reason: 'new track → relaxed cadence',
        );
        service.debugCancelPollTimers();
      },
    );

    test(
      'background throttles and restores the near-end cadence on resume',
      () {
        final service = RustAudioService();
        service.durationNotifier.value = const Duration(seconds: 30);
        service.positionNotifier.value = const Duration(seconds: 28);
        service.debugSyncEventPolling();
        expect(
          service.debugEventPollInterval,
          const Duration(milliseconds: 50),
        );

        service.setAppInBackground(true);
        service.debugSyncEventPolling();
        expect(
          service.debugEventPollInterval,
          const Duration(milliseconds: 500),
        );

        service.setAppInBackground(false);
        service.debugSyncEventPolling();
        expect(
          service.debugEventPollInterval,
          const Duration(milliseconds: 50),
          reason: 'still near the track end → cadence restored immediately',
        );
        service.debugCancelPollTimers();
      },
    );

    test('crossfading keeps the fast cadence, playing relaxes it', () {
      final service = RustAudioService();
      service.durationNotifier.value = const Duration(seconds: 30);
      service.positionNotifier.value = const Duration(seconds: 2);

      service.stateNotifier.value = RustPlaybackState.crossfading;
      service.debugSyncEventPolling();
      expect(
        service.debugEventPollInterval,
        const Duration(milliseconds: 50),
        reason: 'the crossfade bookend arrives via the event pump',
      );

      service.stateNotifier.value = RustPlaybackState.playing;
      service.debugSyncEventPolling();
      expect(service.debugEventPollInterval, const Duration(milliseconds: 250));
      service.debugCancelPollTimers();
    });
  });
}
