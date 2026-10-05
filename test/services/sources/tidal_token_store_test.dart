import 'dart:convert';

import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/services/sources/tidal_service.dart';
import 'package:flick/services/sources/tidal_token_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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

NetworkServerEntity _server({int id = 5, String? token}) {
  return NetworkServerEntity()
    ..id = id
    ..label = 'Tidal'
    ..protocol = 'tidal'
    ..baseUrl = TidalService.tidalBaseUrl
    ..username = null
    ..token = token;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('TidalTokenStore with FlutterSecureStorage mock', () {
    test('read, write, delete round-trip', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final store = TidalTokenStore();

      expect(await store.read(42), isNull);

      await store.write(42, 'test-refresh-token');
      expect(await store.read(42), 'test-refresh-token');

      await store.delete(42);
      expect(await store.read(42), isNull);
    });
  });

  group('TidalService token migration & secure storage', () {
    test('migrates legacy plaintext refresh_token to secure storage on ensureValidToken',
        () async {
      final store = _FakeTokenStore();
      final persisted = <String>[];
      final legacyToken = jsonEncode({
        'access_token': 'acc-123',
        'refresh_token': 'legacy-refresh-token',
        'user_id': 'user-1',
        'country_code': 'US',
        'expires_at_ms': DateTime.now()
            .add(const Duration(hours: 2))
            .millisecondsSinceEpoch,
      });
      final server = _server(id: 7, token: legacyToken);

      final service = TidalService.create(
        tokenStore: store,
        persistToken: (s, token) async {
          persisted.add(token);
        },
      );

      final creds = await service.ensureValidTokenForTesting(server);

      // Verify token store now holds the refresh token
      expect(await store.read(7), 'legacy-refresh-token');
      expect(creds.refreshToken, 'legacy-refresh-token');

      // Verify server.token is stripped of refresh_token
      expect(server.token, isNotNull);
      final inMemoryJson = jsonDecode(server.token!) as Map<String, dynamic>;
      expect(inMemoryJson.containsKey('refresh_token'), isFalse);
      expect(inMemoryJson['access_token'], 'acc-123');

      // Verify database write stripped refresh_token
      expect(persisted, isNotEmpty);
      final persistedJson = jsonDecode(persisted.last) as Map<String, dynamic>;
      expect(persistedJson.containsKey('refresh_token'), isFalse);
      expect(persistedJson['access_token'], 'acc-123');
    });

    test('authenticates seamlessly from secure storage after app restart',
        () async {
      // Secure storage has the token from previous session
      final store = _FakeTokenStore({7: 'stored-secure-refresh'});
      // Database has sanitized token with no refresh_token
      final strippedToken = jsonEncode({
        'access_token': 'acc-123',
        'user_id': 'user-1',
        'country_code': 'US',
        'expires_at_ms': DateTime.now()
            .add(const Duration(hours: 2))
            .millisecondsSinceEpoch,
      });
      final server = _server(id: 7, token: strippedToken);

      final service = TidalService.create(tokenStore: store);
      final creds = await service.ensureValidTokenForTesting(server);

      // Refresh token was successfully populated from secure storage
      expect(creds.refreshToken, 'stored-secure-refresh');
      expect(creds.accessToken, 'acc-123');

      // server.token remains stripped
      final parsed = jsonDecode(server.token!) as Map<String, dynamic>;
      expect(parsed.containsKey('refresh_token'), isFalse);
    });

    test('refresh rotates token in secure storage and does not write refresh_token to DB',
        () async {
      final store = _FakeTokenStore({7: 'old-refresh'});
      final persisted = <String>[];
      final expiredToken = jsonEncode({
        'access_token': 'acc-expired',
        'user_id': 'user-1',
        'country_code': 'US',
        'expires_at_ms': DateTime.now()
            .subtract(const Duration(minutes: 5))
            .millisecondsSinceEpoch,
      });
      final server = _server(id: 7, token: expiredToken);

      final client = MockClient((request) async {
        if (request.url.path.contains('/oauth2/token')) {
          expect(request.bodyFields['grant_type'], 'refresh_token');
          expect(request.bodyFields['refresh_token'], 'old-refresh');
          return http.Response(
            jsonEncode({
              'access_token': 'acc-refreshed',
              'refresh_token': 'new-rotated-refresh',
              'expires_in': 3600,
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });

      final service = TidalService.create(
        client: client,
        tokenStore: store,
        persistToken: (s, token) async {
          persisted.add(token);
        },
      );

      final creds = await service.ensureValidTokenForTesting(server);

      // Creds and store have new rotated refresh token
      expect(creds.accessToken, 'acc-refreshed');
      expect(creds.refreshToken, 'new-rotated-refresh');
      expect(await store.read(7), 'new-rotated-refresh');

      // Database write MUST NOT contain the refresh token
      expect(persisted, isNotEmpty);
      final persistedJson = jsonDecode(persisted.last) as Map<String, dynamic>;
      expect(persistedJson.containsKey('refresh_token'), isFalse);
      expect(persistedJson['access_token'], 'acc-refreshed');
    });

    test('migrateServerToken strips plaintext from entity and persists to store',
        () async {
      final store = _FakeTokenStore();
      final persisted = <String>[];
      final legacy = jsonEncode({
        'access_token': 'tok-abc',
        'refresh_token': 'ref-secret',
        'user_id': 'u1',
        'country_code': 'US',
        'expires_at_ms': 1000000,
      });
      final server = _server(id: 11, token: legacy);

      final service = TidalService.create(
        tokenStore: store,
        persistToken: (s, token) async => persisted.add(token),
      );

      await service.migrateServerToken(server);

      expect(await store.read(11), 'ref-secret');
      final stripped = jsonDecode(server.token!) as Map<String, dynamic>;
      expect(stripped.containsKey('refresh_token'), isFalse);
      expect(persisted.isNotEmpty, isTrue);
      final dbJson = jsonDecode(persisted.last) as Map<String, dynamic>;
      expect(dbJson.containsKey('refresh_token'), isFalse);
    });

    test('forgetToken clears refresh token from store', () async {
      final store = _FakeTokenStore({15: 'token-to-delete'});
      final service = TidalService.create(tokenStore: store);

      expect(await store.read(15), 'token-to-delete');
      await service.forgetToken(15);
      expect(await store.read(15), isNull);
    });
  });
}
