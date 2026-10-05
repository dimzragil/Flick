import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/services/sources/tidal_service.dart';
import 'package:flick/services/sources/tidal_token_store.dart';

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

/// Server with an expired access token and NO refresh_token in the DB JSON
/// (post-migration shape) — forces the refresh path to read secure storage.
NetworkServerEntity _serverStripped({int id = 43}) {
  final tokenJson = jsonEncode({
    'access_token': 'expired_access_token',
    'user_id': 'user_123',
    'country_code': 'US',
    'expires_at_ms': DateTime.now().millisecondsSinceEpoch - 10000,
  });

  return NetworkServerEntity()
    ..id = id
    ..label = 'Tidal Test'
    ..protocol = 'tidal'
    ..baseUrl = TidalService.tidalBaseUrl
    ..token = tokenJson;
}

/// Simulates a wedged platform keystore: read() never completes.
class _HangingTokenStore extends TidalTokenStore {
  @override
  Future<String?> read(int serverId) => Completer<String?>().future;
}

/// In-memory fake token store.
class _FakeTokenStore extends TidalTokenStore {
  _FakeTokenStore([Map<int, String>? initial]) : _tokens = initial ?? {};

  final Map<int, String> _tokens;

  @override
  Future<String?> read(int serverId) async => _tokens[serverId];

  @override
  Future<void> write(int serverId, String refreshToken) async {
    _tokens[serverId] = refreshToken;
  }

  @override
  Future<void> delete(int serverId) async {
    _tokens.remove(serverId);
  }
}

/// Token store whose writes always fail.
class _FailingWriteTokenStore extends _FakeTokenStore {
  @override
  Future<void> write(int serverId, String refreshToken) async {
    throw StateError('keystore unavailable');
  }
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

    test('wedged secure storage read fails fast with TimeoutException and does not poison the in-flight map', () async {
      final client = MockClient(
        (request) async => http.Response('Not Found', 404),
      );
      final tidal = TidalService.create(
        client: client,
        tokenStore: _HangingTokenStore(),
      );
      final server = _serverStripped();

      // Must throw TimeoutException (~15s), NOT hang forever.
      final stopwatch = Stopwatch()..start();
      await expectLater(
        tidal.ensureValidTokenForTesting(server),
        throwsA(isA<TimeoutException>()),
      );
      stopwatch.stop();
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 25)));

      // In-flight map must be clean — no poisoning.
      expect(tidal.refreshInFlightForTesting.containsKey(server.id), isFalse);

      // Retry with a working store recovers (proves the map wasn't wedged).
      final workingStore = _FakeTokenStore({server.id: 'good_refresh_token'});
      final retryClient = MockClient((request) async {
        if (request.url.path.contains('/oauth2/token')) {
          return http.Response(
            jsonEncode({
              'access_token': 'recovered_access_token',
              'refresh_token': 'recovered_refresh_token',
              'expires_in': 3600,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('Not Found', 404);
      });
      final retryTidal = TidalService.create(
        client: retryClient,
        tokenStore: workingStore,
      );
      final creds = await retryTidal.ensureValidTokenForTesting(server);
      expect(creds.accessToken, 'recovered_access_token');
      expect(creds.refreshToken, 'recovered_refresh_token');
    });

    test('migration keeps the DB refresh token when secure storage write fails', () async {
      final client = MockClient(
        (request) async => http.Response('Not Found', 404),
      );
      final tidal = TidalService.create(client: client);
      final server = _server(refreshToken: 'legacy_refresh_token');

      await tidal.migrateServerToken(
        server,
        tokenStore: _FailingWriteTokenStore(),
      );

      // The DB token must NOT be stripped — the secure copy isn't confirmed.
      final tokenJson = jsonDecode(server.token!) as Map<String, dynamic>;
      expect(tokenJson['refresh_token'], 'legacy_refresh_token');
    });

    test('migration strips the DB refresh token after a confirmed secure write', () async {
      final client = MockClient(
        (request) async => http.Response('Not Found', 404),
      );
      final tidal = TidalService.create(client: client);
      final server = _server(refreshToken: 'legacy_refresh_token');
      final store = _FakeTokenStore();

      await tidal.migrateServerToken(server, tokenStore: store);

      final tokenJson = jsonDecode(server.token!) as Map<String, dynamic>;
      expect(tokenJson['refresh_token'], isNull);
      expect(await store.read(server.id), 'legacy_refresh_token');
    });
  });
}
