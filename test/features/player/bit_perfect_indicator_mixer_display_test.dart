import 'package:flick/features/player/widgets/bit_perfect_indicator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mixerOutputRateLabel', () {
    test('shows the real device native rate when available', () {
      expect(BitPerfectIndicator.mixerOutputRateLabel(44100), '44.1 kHz');
      expect(BitPerfectIndicator.mixerOutputRateLabel(48000), '48.0 kHz');
      expect(BitPerfectIndicator.mixerOutputRateLabel(192000), '192.0 kHz');
    });

    test('labels the 48 kHz fallback as assumed when unavailable', () {
      expect(
        BitPerfectIndicator.mixerOutputRateLabel(null),
        '48.0 kHz (assumed)',
      );
      expect(BitPerfectIndicator.mixerOutputRateLabel(0), '48.0 kHz (assumed)');
    });
  });

  group('mixerBitDepthLabel', () {
    test('24-bit is inferred preserved when hiResInternal is advertised', () {
      expect(
        BitPerfectIndicator.mixerBitDepthLabel(24, preservesHiRes: true),
        '24-bit → 24-bit',
      );
    });

    test('24-bit is inferred truncated without hiResInternal', () {
      expect(
        BitPerfectIndicator.mixerBitDepthLabel(24, preservesHiRes: false),
        '24-bit → 16-bit',
      );
    });

    test('non-24-bit depths pass through unchanged', () {
      expect(
        BitPerfectIndicator.mixerBitDepthLabel(16, preservesHiRes: false),
        '16-bit',
      );
      expect(
        BitPerfectIndicator.mixerBitDepthLabel(32, preservesHiRes: true),
        '32-bit',
      );
    });
  });
}
