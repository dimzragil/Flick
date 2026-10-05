import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/services/sources/tidal_service.dart';

NetworkServerEntity _server({
  int id = 42,
  required String refreshToken,
  int? expiresAtMs,
}) {
  final tokenJson = jsonEncode({
    'access_token': 'expired_access_token',
    'refresh_token': refreshToken,
    'user_id': 'user_123',
    'country_code': 'US',
    'expires_at_ms': expiresAtMs ?? (DateTime.now().millisecondsSinceEpoch - 10000),
  });

  return NetworkServerEntity()
    ..id = id
    ..label = 'Tidal Test'
    ..protocol = 'tidal'
    ..baseUrl = TidalService.tidalBaseUrl
    ..token = tokenJson;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    FlutterSecureStorage.setMockInitialValues({});
  });
  group('TidalService single-flight token refresh', () {
    test(
      'concurrent ensureValidToken calls trigger only one refresh request and share result',
      () async {
        var refreshPostCount = 0;
        final refreshCompleter = Completer<http.Response>();

        final client = MockClient((request) async {
          if (request.url.path.contains('/oauth2/token')) {
            refreshPostCount++;
            return refreshCompleter.future;
          }
          return http.Response('Not Found', 404);
        });

        final tidal = TidalService.create(client: client);
        final server = _server(refreshToken: 'test_refresh_token');

        // Launch two concurrent calls to ensureValidToken
        final call1 = tidal.ensureValidTokenForTesting(server);
        final call2 = tidal.ensureValidTokenForTesting(server);

        expect(tidal.refreshInFlightForTesting.containsKey(server.id), isTrue);

        // Allow HTTP request microtask to reach MockClient
        await pumpEventQueue();

        // Only one refresh request should be sent to the auth server
        expect(refreshPostCount, 1);

        // Complete the refresh response
        refreshCompleter.complete(
          http.Response(
            jsonEncode({
              'access_token': 'brand_new_access_token',
              'refresh_token': 'rotated_refresh_token',
              'expires_in': 3600,
            }),
            200,
            headers: {'content-type': 'application/json'},
          ),
        );

        final creds1 = await call1;
        final creds2 = await call2;

        expect(creds1.accessToken, 'brand_new_access_token');
        expect(creds2.accessToken, 'brand_new_access_token');
        expect(creds1.refreshToken, 'rotated_refresh_token');
        expect(creds2.refreshToken, 'rotated_refresh_token');

        // Map must be cleared in finally
        expect(tidal.refreshInFlightForTesting.containsKey(server.id), isFalse);

        // Subsequent call does not trigger refresh because token is now fresh
        final call3 = await tidal.ensureValidTokenForTesting(server);
        expect(call3.accessToken, 'brand_new_access_token');
        expect(refreshPostCount, 1);
      },
    );

    test('refresh failure clears in-flight map and does not permanently poison cache', () async {
      var refreshPostCount = 0;
      final refreshCompleter = Completer<http.Response>();

      final client = MockClient((request) async {
        if (request.url.path.contains('/oauth2/token')) {
          refreshPostCount++;
          return refreshCompleter.future;
        }
        return http.Response('Not Found', 404);
      });

      final tidal = TidalService.create(client: client);
      final server = _server(refreshToken: 'test_refresh_token');

      final call1 = tidal.ensureValidTokenForTesting(server);
      expect(tidal.refreshInFlightForTesting.containsKey(server.id), isTrue);
      await pumpEventQueue();
      expect(refreshPostCount, 1);

      refreshCompleter.complete(
        http.Response(
          jsonEncode({'error': 'server_error'}),
          500,
          headers: {'content-type': 'application/json'},
        ),
      );

      await expectLater(call1, throwsA(isA<TidalException>()));

      // In-flight tracker must be cleaned up despite the failure
      expect(tidal.refreshInFlightForTesting.containsKey(server.id), isFalse);

      // Retry should be able to fire a new refresh request
      final retryClient = MockClient((request) async {
        if (request.url.path.contains('/oauth2/token')) {
          refreshPostCount++;
          return http.Response(
            jsonEncode({
              'access_token': 'retried_access_token',
              'refresh_token': 'retried_refresh_token',
              'expires_in': 3600,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('Not Found', 404);
      });

      final retriedTidal = TidalService.create(client: retryClient);
      final retryCreds = await retriedTidal.ensureValidTokenForTesting(server);
      expect(retryCreds.accessToken, 'retried_access_token');
      expect(refreshPostCount, 2);
    });

    test('different server IDs have independent in-flight tracking', () async {
      final completer1 = Completer<http.Response>();
      final completer2 = Completer<http.Response>();

      final client = MockClient((request) async {
        if (request.url.path.contains('/oauth2/token')) {
          final body = request.body;
          if (body.contains('refresh_1')) {
            return completer1.future;
          }
          if (body.contains('refresh_2')) {
            return completer2.future;
          }
        }
        return http.Response('Not Found', 404);
      });

      final tidal = TidalService.create(client: client);
      final server1 = _server(id: 1, refreshToken: 'refresh_1');
      final server2 = _server(id: 2, refreshToken: 'refresh_2');

      final call1 = tidal.ensureValidTokenForTesting(server1);
      final call2 = tidal.ensureValidTokenForTesting(server2);

      expect(tidal.refreshInFlightForTesting.containsKey(1), isTrue);
      expect(tidal.refreshInFlightForTesting.containsKey(2), isTrue);

      completer1.complete(
        http.Response(
          jsonEncode({
            'access_token': 'token_server_1',
            'refresh_token': 'refresh_server_1',
            'expires_in': 3600,
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );

      final creds1 = await call1;
      expect(creds1.accessToken, 'token_server_1');
      expect(tidal.refreshInFlightForTesting.containsKey(1), isFalse);
      expect(tidal.refreshInFlightForTesting.containsKey(2), isTrue);

      completer2.complete(
        http.Response(
          jsonEncode({
            'access_token': 'token_server_2',
            'refresh_token': 'refresh_server_2',
            'expires_in': 3600,
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );

      final creds2 = await call2;
      expect(creds2.accessToken, 'token_server_2');
      expect(tidal.refreshInFlightForTesting.containsKey(2), isFalse);
    });
  });
}
