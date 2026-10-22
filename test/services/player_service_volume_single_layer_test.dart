import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/player_service.dart';

void main() {
  group('systemTierPlayerVolume', () {
    test('untagged track at full volume pins the player at unity', () {
      expect(
        PlayerService.systemTierPlayerVolume(
          replayGainLinear: 1.0,
          ducked: false,
        ),
        1.0,
      );
    });

    test('duck scales the pinned gain, not the user volume', () {
      expect(
        PlayerService.systemTierPlayerVolume(
          replayGainLinear: 1.0,
          ducked: true,
        ),
        0.2,
      );
      expect(
        PlayerService.systemTierPlayerVolume(
          replayGainLinear: 0.5,
          ducked: true,
        ),
        0.1,
      );
    });

    test('ReplayGain attenuation passes through, boost clamps', () {
      expect(
        PlayerService.systemTierPlayerVolume(
          replayGainLinear: 0.5,
          ducked: false,
        ),
        0.5,
      );
      expect(
        PlayerService.systemTierPlayerVolume(
          replayGainLinear: 2.0,
          ducked: false,
        ),
        1.0,
      );
    });
  });

  group('systemTierBoostResidual', () {
    test('no boost at or below unity', () {
      expect(
        PlayerService.systemTierBoostResidual(
          userVolume: 1.0,
          replayGainLinear: 1.0,
        ),
        1.0,
      );
      expect(
        PlayerService.systemTierBoostResidual(
          userVolume: 0.8,
          replayGainLinear: 1.0,
        ),
        1.0,
      );
      expect(
        PlayerService.systemTierBoostResidual(
          userVolume: 1.0,
          replayGainLinear: 0.5,
        ),
        1.0,
      );
    });

    test('extended volume above 100 % becomes boost', () {
      expect(
        PlayerService.systemTierBoostResidual(
          userVolume: 1.5,
          replayGainLinear: 1.0,
        ),
        1.5,
      );
    });

    test('positive ReplayGain beyond the clamped player becomes boost', () {
      expect(
        PlayerService.systemTierBoostResidual(
          userVolume: 1.0,
          replayGainLinear: 2.0,
        ),
        2.0,
      );
      // Quiet user volume with a boosted track: the enhancer makes up
      // exactly the part the system level and player cannot express.
      expect(
        PlayerService.systemTierBoostResidual(
          userVolume: 0.5,
          replayGainLinear: 2.0,
        ),
        2.0,
      );
    });

    test('mute never boosts', () {
      expect(
        PlayerService.systemTierBoostResidual(
          userVolume: 0.0,
          replayGainLinear: 2.0,
        ),
        1.0,
      );
    });
  });
}
