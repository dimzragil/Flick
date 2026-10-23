import 'package:flick/services/player_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('speaker direct-source headers', () {
    test('drops x-flick metadata and passes null, never an empty map', () {
      // A non-null (even empty) header map makes just_audio start its own
      // cleartext loopback proxy — a second local hop on a direct path.
      expect(
        PlayerService.speakerHeadersForPlayback({
          'x-flick-sample-rate': '96000',
          'x-flick-bit-depth': '24',
          'x-flick-extension-hint': 'flac',
        }),
        isNull,
      );
      expect(PlayerService.speakerHeadersForPlayback(const {}), isNull);
    });

    test('keeps protocol auth headers', () {
      expect(
        PlayerService.speakerHeadersForPlayback({
          'Authorization': 'Basic dXNlcjpwYXNz',
          'X-Flick-Sample-Rate': '44100',
        }),
        {'Authorization': 'Basic dXNlcjpwYXNz'},
      );
    });
  });
}
