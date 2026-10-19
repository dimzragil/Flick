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

  group('429 retry deadline', () {
    test('gives up instead of honoring a 120s Retry-After', () async {
      var attempts = 0;
      final client = MockClient((request) async {
        attempts++;
        return http.Response('', 429, headers: {'retry-after': '120'});
      });
      final service = TidalService.create(
        client: client,
        retryDeadline: const Duration(seconds: 5),
      );
      final server = _server(token: _validToken());
      final stopwatch = Stopwatch()..start();

      await expectLater(
        service.getTrackDetail(server, '42'),
        throwsA(isA<TidalRateLimitedException>()),
      );
      stopwatch.stop();

      expect(attempts, 1, reason: 'the 120s backoff exceeds the deadline');
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 2)),
        reason: 'the caller must not wait for the Retry-After value',
      );
    });

    test('normal 429 retry then success still works', () async {
      var attempts = 0;
      final client = MockClient((request) async {
        attempts++;
        if (attempts == 1) {
          return http.Response('', 429, headers: {'retry-after': '0'});
        }
        return http.Response(jsonEncode({'id': 42, 'title': 'Retried'}), 200);
      });
      final service = TidalService.create(
        client: client,
        retryDeadline: const Duration(seconds: 10),
      );
      final server = _server(token: _validToken());

      final track = await service.getTrackDetail(server, '42');

      expect(attempts, 2);
      expect(track['title'], 'Retried');
    });
  });
}
