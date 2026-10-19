import 'dart:convert';

import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/services/sources/tidal_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

NetworkServerEntity _server({String? token}) {
  return NetworkServerEntity()
    ..id = 9
    ..label = 'Tidal'
    ..protocol = 'tidal'
    ..baseUrl = TidalService.tidalBaseUrl
    ..username = null
    ..token = token;
}

String _validToken() => jsonEncode({
  'access_token': 'acc-xyz',
  'refresh_token': 'ref-xyz',
  'user_id': 'user-1',
  'country_code': 'NO',
  'expires_at_ms': DateTime.now()
      .add(const Duration(hours: 1))
      .millisecondsSinceEpoch,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reportPlayback', () {
    test('respects the shared API throttle gap', () async {
      final requestTimes = <DateTime>[];
      final client = MockClient((request) async {
        requestTimes.add(DateTime.now());
        return http.Response('', 200);
      });
      final service = TidalService.create(client: client);
      final server = _server(token: _validToken());

      // Warm-up call: the first request pays one-off setup cost between the
      // throttle stamp and the mock client callback.
      await service.reportPlayback(
        server,
        trackId: '000',
        durationSeconds: 200,
      );
      await service.reportPlayback(
        server,
        trackId: '111',
        durationSeconds: 200,
      );
      await service.reportPlayback(
        server,
        trackId: '222',
        durationSeconds: 200,
      );

      expect(requestTimes, hasLength(3));
      expect(
        requestTimes[2].difference(requestTimes[1]).inMilliseconds,
        greaterThanOrEqualTo(80),
        reason: 'consecutive event POSTs must wait for the 100ms API gap',
      );
    });

    test('retries 429s and degrades gracefully', () async {
      var attempts = 0;
      final client = MockClient((request) async {
        expect(request.url.host, 'ec.tidal.com');
        expect(request.url.path, '/api/event-batch');
        attempts++;
        return http.Response('', 429, headers: {'retry-after': '0'});
      });
      final service = TidalService.create(client: client);
      final server = _server(token: _validToken());

      await expectLater(
        service.reportPlayback(server, trackId: '333', durationSeconds: 200),
        completes,
      );

      // 1 initial attempt + 3 retries inside _with429Retry. Exhausting them
      // must only log; telemetry can never break playback.
      expect(attempts, 4);
    });
  });
}
