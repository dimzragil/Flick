import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/android_audio_device_service.dart';
import 'package:flick/services/player_service.dart';

/// USB DAC unplug handling: pause and stay paused, never auto-play.
///
/// These tests pin the three pure decision helpers behind the
/// "manually paused, unplug the DAC, music starts by itself" fix:
/// - `isUsbAudioDeviceInfo`: recognize an active USB audio route.
/// - `isUsbDacUnplugTransition`: detect the USB-audio -> non-USB route
///   transition that means the DAC was unplugged (and nothing else:
///   plugging in headphones or switching to Bluetooth is not an unplug).
/// - `shouldAutoResumeAfterUsbEngineFallback`: never let the direct-USB
///   engine fallback start playback for a session the user paused. While the
///   unplug window is open, the play/pause state captured at unplug time is
///   authoritative over any later failure state.
void main() {
  AndroidPlaybackDeviceInfo device({
    bool hasUsbDac = false,
    bool hasAttachedUac2Device = false,
    String? routeType,
    String? routeLabel,
  }) {
    return AndroidPlaybackDeviceInfo(
      hasUsbDac: hasUsbDac,
      hasAttachedUac2Device: hasAttachedUac2Device,
      manufacturer: 'Test',
      model: 'Device',
      routeType: routeType,
      routeLabel: routeLabel,
    );
  }

  AndroidPlaybackDeviceInfo speaker() =>
      device(routeType: 'internal', routeLabel: 'Speaker');

  AndroidPlaybackDeviceInfo wiredHeadphones() =>
      device(routeType: 'wired', routeLabel: 'Wired headphones');

  AndroidPlaybackDeviceInfo bluetooth() =>
      device(routeType: 'bluetooth', routeLabel: 'WH-1000XM5');

  group('isUsbAudioDeviceInfo', () {
    test('true when the media route itself is USB', () {
      expect(
        isUsbAudioDeviceInfo(device(routeType: 'usb', routeLabel: 'FiiO KA11')),
        isTrue,
      );
    });

    test('true when UsbManager sees a DAC even without a USB route type', () {
      expect(isUsbAudioDeviceInfo(device(hasUsbDac: true)), isTrue);
    });

    test('true when the UAC2 probe found an attached device', () {
      expect(isUsbAudioDeviceInfo(device(hasAttachedUac2Device: true)), isTrue);
    });

    test('true when the route label merely looks like USB audio', () {
      expect(
        isUsbAudioDeviceInfo(
          device(routeType: 'wired', routeLabel: 'USB Audio Device'),
        ),
        isTrue,
      );
      expect(
        isUsbAudioDeviceInfo(
          device(routeType: 'unknown', routeLabel: 'Topping DAC'),
        ),
        isTrue,
      );
    });

    test('false for the internal speaker', () {
      expect(isUsbAudioDeviceInfo(speaker()), isFalse);
    });

    test('false for wired headphones', () {
      expect(isUsbAudioDeviceInfo(wiredHeadphones()), isFalse);
    });

    test('false for Bluetooth', () {
      expect(isUsbAudioDeviceInfo(bluetooth()), isFalse);
    });
  });

  group('isUsbDacUnplugTransition', () {
    test('true on USB -> speaker (a real DAC unplug)', () {
      expect(
        isUsbDacUnplugTransition(
          previous: device(routeType: 'usb', routeLabel: 'FiiO KA11'),
          current: speaker(),
        ),
        isTrue,
      );
    });

    test('true on USB -> wired headphones', () {
      expect(
        isUsbDacUnplugTransition(
          previous: device(hasUsbDac: true),
          current: wiredHeadphones(),
        ),
        isTrue,
      );
    });

    test('true on USB -> Bluetooth', () {
      expect(
        isUsbDacUnplugTransition(
          previous: device(hasAttachedUac2Device: true),
          current: bluetooth(),
        ),
        isTrue,
      );
    });

    test('true when previous was only a USB-looking label', () {
      expect(
        isUsbDacUnplugTransition(
          previous: device(routeType: 'wired', routeLabel: 'Topping DAC'),
          current: speaker(),
        ),
        isTrue,
      );
    });

    test('false on speaker -> wired headphones (plugging in headphones '
        'must not pause)', () {
      expect(
        isUsbDacUnplugTransition(
          previous: speaker(),
          current: wiredHeadphones(),
        ),
        isFalse,
      );
    });

    test('false on speaker -> Bluetooth', () {
      expect(
        isUsbDacUnplugTransition(previous: speaker(), current: bluetooth()),
        isFalse,
      );
    });

    test('false when no previous observation exists (first sample)', () {
      expect(
        isUsbDacUnplugTransition(previous: null, current: speaker()),
        isFalse,
      );
    });

    test('false on speaker -> USB (plugging a DAC in is not an unplug)', () {
      expect(
        isUsbDacUnplugTransition(
          previous: speaker(),
          current: device(routeType: 'usb', routeLabel: 'FiiO KA11'),
        ),
        isFalse,
      );
    });

    test('false on USB -> USB (still on USB audio)', () {
      expect(
        isUsbDacUnplugTransition(
          previous: device(routeType: 'usb', routeLabel: 'FiiO KA11'),
          current: device(hasUsbDac: true, routeLabel: 'Topping DAC'),
        ),
        isFalse,
      );
    });
  });

  group('shouldAutoResumeAfterUsbEngineFallback', () {
    test('false when the session was already paused at failure time', () {
      expect(
        shouldAutoResumeAfterUsbEngineFallback(
          wasPlayingAtFailure: false,
          wasPlayingAtUnplug: false,
          usbDacUnplugActive: false,
          pauseOnDisconnect: true,
          dacStillAttached: false,
        ),
        isFalse,
      );
    });

    test('false when the session was paused at unplug while the unplug '
        'window is open, even if a stale failure claims it was playing', () {
      expect(
        shouldAutoResumeAfterUsbEngineFallback(
          wasPlayingAtFailure: true,
          wasPlayingAtUnplug: false,
          usbDacUnplugActive: true,
          pauseOnDisconnect: false,
          dacStillAttached: true,
        ),
        isFalse,
      );
    });

    test('false when playing + pref on + DAC provably gone (stay paused)', () {
      expect(
        shouldAutoResumeAfterUsbEngineFallback(
          wasPlayingAtFailure: true,
          wasPlayingAtUnplug: true,
          usbDacUnplugActive: false,
          pauseOnDisconnect: true,
          dacStillAttached: false,
        ),
        isFalse,
      );
    });

    test('true when playing + pref on + DAC still attached (transient USB '
        'suspension, not an unplug)', () {
      expect(
        shouldAutoResumeAfterUsbEngineFallback(
          wasPlayingAtFailure: true,
          wasPlayingAtUnplug: true,
          usbDacUnplugActive: false,
          pauseOnDisconnect: true,
          dacStillAttached: true,
        ),
        isTrue,
      );
    });

    test('true when playing + pref off (user asked to continue on the new '
        'route)', () {
      expect(
        shouldAutoResumeAfterUsbEngineFallback(
          wasPlayingAtFailure: true,
          wasPlayingAtUnplug: true,
          usbDacUnplugActive: false,
          pauseOnDisconnect: false,
          dacStillAttached: false,
        ),
        isTrue,
      );
    });

    test('window open: playing at unplug is authoritative and pref off '
        'still resumes', () {
      expect(
        shouldAutoResumeAfterUsbEngineFallback(
          wasPlayingAtFailure: true,
          wasPlayingAtUnplug: true,
          usbDacUnplugActive: true,
          pauseOnDisconnect: false,
          dacStillAttached: false,
        ),
        isTrue,
      );
    });

    test(
      'window open: playing at unplug + pref on + DAC gone stays paused',
      () {
        expect(
          shouldAutoResumeAfterUsbEngineFallback(
            wasPlayingAtFailure: true,
            wasPlayingAtUnplug: true,
            usbDacUnplugActive: true,
            pauseOnDisconnect: true,
            dacStillAttached: false,
          ),
          isFalse,
        );
      },
    );

    test('window open: paused at unplug never resumes regardless of pref', () {
      for (final pauseOnDisconnect in [true, false]) {
        for (final dacStillAttached in [true, false]) {
          expect(
            shouldAutoResumeAfterUsbEngineFallback(
              wasPlayingAtFailure: true,
              wasPlayingAtUnplug: false,
              usbDacUnplugActive: true,
              pauseOnDisconnect: pauseOnDisconnect,
              dacStillAttached: dacStillAttached,
            ),
            isFalse,
            reason:
                'pauseOnDisconnect=$pauseOnDisconnect '
                'dacStillAttached=$dacStillAttached',
          );
        }
      }
    });
  });
}
