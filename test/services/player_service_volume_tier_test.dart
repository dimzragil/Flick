import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/uac2_service.dart';

VolumeTier tier({
  bool bitPerfectPath = true,
  Uac2VolumeMode? mode,
  bool hwFailed = false,
  bool dop = false,
  bool autoSwitch = false,
  bool passthrough = true,
  bool rust = true,
}) => determineVolumeTier(
  isBitPerfectVolumePath: bitPerfectPath,
  volumeMode: mode,
  hwVolumeFailed: hwFailed,
  isDoP: dop,
  autoSwitchDsdForVolume: autoSwitch,
  isPassthrough: passthrough,
  usingRustBackend: rust,
);

void main() {
  group('determineVolumeTier', () {
    test('non-bit-perfect path maps Rust to software, else system', () {
      expect(tier(bitPerfectPath: false, rust: true), VolumeTier.software);
      expect(tier(bitPerfectPath: false, rust: false), VolumeTier.system);
    });

    test('hardware mode is trusted unless the lie-detector fired', () {
      expect(tier(mode: Uac2VolumeMode.hardware), VolumeTier.hardware);
      expect(
        tier(mode: Uac2VolumeMode.hardware, hwFailed: true),
        VolumeTier.unavailable,
      );
    });

    test('no DAC hardware volume: DSP path keeps software gain', () {
      expect(
        tier(mode: Uac2VolumeMode.software, passthrough: false),
        VolumeTier.software,
      );
      expect(
        tier(mode: Uac2VolumeMode.unavailable, passthrough: false),
        VolumeTier.software,
      );
    });

    test('bit-perfect passthrough with no hardware volume is unavailable', () {
      expect(tier(mode: Uac2VolumeMode.software), VolumeTier.unavailable);
      expect(tier(mode: Uac2VolumeMode.unavailable), VolumeTier.unavailable);
      expect(tier(mode: null), VolumeTier.unavailable);
    });

    test('DoP requires hardware volume or the PCM auto-switch', () {
      expect(
        tier(dop: true, mode: Uac2VolumeMode.hardware),
        VolumeTier.hardware,
      );
      expect(
        tier(dop: true, mode: Uac2VolumeMode.software),
        VolumeTier.unavailable,
      );
      expect(
        tier(dop: true, mode: Uac2VolumeMode.software, autoSwitch: true),
        VolumeTier.software,
      );
    });
  });

  group('shouldSkipDucking', () {
    bool skip({
      VolumeTier tier = VolumeTier.system,
      bool dop = false,
      bool directUsb = false,
    }) => shouldSkipDucking(
      activeTier: tier,
      isCurrentTrackDoP: dop,
      isDirectUsbPath: directUsb,
    );

    test('skips DoP over direct USB (legacy guard preserved)', () {
      expect(skip(dop: true, directUsb: true), isTrue);
      // DoP without direct USB still ducks (not the exclusive path).
      expect(skip(dop: true, directUsb: false), isFalse);
    });

    test('skips hardware tier: DAC knob is the volume authority', () {
      expect(skip(tier: VolumeTier.hardware), isTrue);
    });

    test('skips unavailable tier: passthrough must never be scaled', () {
      expect(skip(tier: VolumeTier.unavailable), isTrue);
    });

    test('software and system tiers still duck normally', () {
      expect(skip(tier: VolumeTier.software), isFalse);
      expect(skip(tier: VolumeTier.system), isFalse);
    });
  });
}
