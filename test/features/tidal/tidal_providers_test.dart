import 'dart:convert';

import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/features/tidal/providers/tidal_providers.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/sources/tidal_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

NetworkServerEntity _testServer({String? token}) {
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
  group('tidalAuthStateProvider', () {
    test('returns false when server is null', () async {
      final container = ProviderContainer(
        overrides: [
          tidalServerProvider.overrideWith(
            () => _MockTidalServerNotifier(null),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(tidalServerProvider.future);
      expect(container.read(tidalAuthStateProvider), isFalse);
    });

    test('returns false when server token is empty', () async {
      final container = ProviderContainer(
        overrides: [
          tidalServerProvider.overrideWith(
            () => _MockTidalServerNotifier(_testServer(token: '')),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(tidalServerProvider.future);
      expect(container.read(tidalAuthStateProvider), isFalse);
    });

    test('returns true when server has non-empty token', () async {
      final container = ProviderContainer(
        overrides: [
          tidalServerProvider.overrideWith(
            () => _MockTidalServerNotifier(_testServer(token: _validToken())),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(tidalServerProvider.future);
      expect(container.read(tidalAuthStateProvider), isTrue);
    });
  });

  group('TidalSearchResults', () {
    test('empty state returns true for isEmpty', () {
      const results = TidalSearchResults.empty;
      expect(results.isEmpty, isTrue);
      expect(results.tracks, isEmpty);
      expect(results.albums, isEmpty);
      expect(results.artists, isEmpty);
      expect(results.playlists, isEmpty);
    });

    test('copyWith updates properties properly', () {
      const initial = TidalSearchResults(query: 'test');
      final updated = initial.copyWith(
        isLoading: true,
        query: 'new query',
        albums: [
          {'id': 1},
        ],
      );
      expect(updated.isLoading, isTrue);
      expect(updated.query, 'new query');
      expect(updated.albums.length, 1);
      expect(updated.isEmpty, isFalse);
    });
  });

  group('TidalSearchNotifier', () {
    test('clears results when query is empty', () {
      final container = ProviderContainer(
        overrides: [
          tidalServerProvider.overrideWith(
            () => _MockTidalServerNotifier(_testServer(token: _validToken())),
          ),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(tidalSearchProvider.notifier);
      notifier.search('');

      final state = container.read(tidalSearchProvider);
      expect(state.isEmpty, isTrue);
      expect(state.isLoading, isFalse);
    });

    test('sets error when searching without signed-in server', () async {
      final container = ProviderContainer(
        overrides: [
          tidalServerProvider.overrideWith(
            () => _MockTidalServerNotifier(null),
          ),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(tidalSearchProvider.notifier);
      await notifier.performSearch('Daft Punk');

      final state = container.read(tidalSearchProvider);
      expect(state.error, 'Tidal is not signed in');
      expect(state.isLoading, isFalse);
    });

    test(
      'parses search results into ephemeral Song models and catalog lists',
      () async {
        final client = MockClient((request) async {
          if (request.url.path.endsWith('/search')) {
            return http.Response(
              jsonEncode({
                'tracks': {
                  'items': [
                    {
                      'id': 101,
                      'title': 'Around the World',
                      'duration': 420,
                      'audioQuality': 'LOSSLESS',
                      'artists': [
                        {'name': 'Daft Punk'},
                      ],
                    },
                  ],
                },
                'albums': {
                  'items': [
                    {'id': 201, 'title': 'Homework'},
                  ],
                },
                'artists': {
                  'items': [
                    {'id': 301, 'name': 'Daft Punk'},
                  ],
                },
                'playlists': {
                  'items': [
                    {'uuid': 'p-1', 'title': 'French Touch'},
                  ],
                },
              }),
              200,
            );
          }
          return http.Response('', 404);
        });

        final mockService = TidalService.create(client: client);
        final container = ProviderContainer(
          overrides: [
            tidalServiceProvider.overrideWithValue(mockService),
            tidalServerProvider.overrideWith(
              () => _MockTidalServerNotifier(_testServer(token: _validToken())),
            ),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(tidalSearchProvider.notifier);
        await notifier.performSearch('Daft Punk');

        final state = container.read(tidalSearchProvider);
        expect(state.isLoading, isFalse);
        expect(state.error, isNull);
        expect(state.query, 'Daft Punk');
        expect(state.tracks.length, 1);
        expect(state.tracks.first, isA<Song>());
        expect(state.tracks.first.title, 'Around the World');
        expect(state.tracks.first.artist, 'Daft Punk');
        expect(state.tracks.first.fileType, 'flac');
        expect(state.albums.length, 1);
        expect(state.albums.first['title'], 'Homework');
        expect(state.artists.length, 1);
        expect(state.artists.first['name'], 'Daft Punk');
        expect(state.playlists.length, 1);
        expect(state.playlists.first['title'], 'French Touch');
      },
    );

    test('clear() resets state to empty', () async {
      final container = ProviderContainer(
        overrides: [
          tidalServerProvider.overrideWith(
            () => _MockTidalServerNotifier(_testServer(token: _validToken())),
          ),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(tidalSearchProvider.notifier);
      notifier.clear();

      final state = container.read(tidalSearchProvider);
      expect(state.isEmpty, isTrue);
    });
  });

  group('tidalUserPlaylistsProvider', () {
    test('returns empty list when not signed in', () async {
      final container = ProviderContainer(
        overrides: [
          tidalServerProvider.overrideWith(
            () => _MockTidalServerNotifier(null),
          ),
        ],
      );
      addTearDown(container.dispose);

      final playlists = await container.read(tidalUserPlaylistsProvider.future);
      expect(playlists, isEmpty);
    });

    test('fetches user playlists when signed in', () async {
      final client = MockClient((request) async {
        if (request.url.path.contains('/users/user-1/playlists')) {
          return http.Response(
            jsonEncode({
              'items': [
                {'uuid': 'pl-user-1', 'title': 'Chill Vibes'},
              ],
            }),
            200,
          );
        }
        return http.Response('', 404);
      });

      final mockService = TidalService.create(client: client);
      final container = ProviderContainer(
        overrides: [
          tidalServiceProvider.overrideWithValue(mockService),
          tidalServerProvider.overrideWith(
            () => _MockTidalServerNotifier(_testServer(token: _validToken())),
          ),
        ],
      );
      addTearDown(container.dispose);

      final playlists = await container.read(tidalUserPlaylistsProvider.future);
      expect(playlists.length, 1);
      expect(playlists.first['title'], 'Chill Vibes');
    });

  });
}

class _MockTidalServerNotifier extends TidalServerNotifier {
  final NetworkServerEntity? _server;
  _MockTidalServerNotifier(this._server);

  @override
  Future<NetworkServerEntity?> build() async {
    return _server;
  }
}
