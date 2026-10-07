import 'dart:convert';

import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/features/tidal/providers/tidal_providers.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/favorites_provider.dart';
import 'package:flick/services/favorites_service.dart';
import 'package:flick/services/sources/network_source_service.dart';
import 'package:flick/services/sources/tidal_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

NetworkServerEntity _testServer({String? token}) {
  return NetworkServerEntity()
    ..id = 1
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

class _MockTidalServerNotifier extends TidalServerNotifier {
  final NetworkServerEntity? _server;
  _MockTidalServerNotifier(this._server);

  @override
  Future<NetworkServerEntity?> build() async => _server;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('TidalService Liked Songs & Favorites', () {
    test(
      'getFavoriteTracks sorts newest-first using created timestamp',
      () async {
        final client = MockClient((request) async {
          if (request.url.path.contains('/users/user-1/favorites/tracks')) {
            return http.Response(
              jsonEncode({
                'items': [
                  {
                    'created': '2023-01-01T10:00:00.000+0000',
                    'item': {'id': 101, 'title': 'Old Track', 'duration': 200},
                  },
                  {
                    'created': '2026-10-07T12:00:00.000+0000',
                    'item': {'id': 102, 'title': 'New Track', 'duration': 180},
                  },
                ],
              }),
              200,
            );
          }
          return http.Response('', 404);
        });

        final service = TidalService.create(client: client);
        final server = _testServer(token: _validToken());

        final songs = await service.getFavoriteTracks(server);
        expect(songs.length, 2);
        // Newest track should be at index 0
        expect(songs[0].title, 'New Track');
        expect(songs[0].remoteId, '102');
        expect(songs[1].title, 'Old Track');
        expect(songs[1].remoteId, '101');
      },
    );

    test('getFavoriteTrackIds paginates to retrieve all favorites', () async {
      var callCount = 0;
      final client = MockClient((request) async {
        if (request.url.path.contains('/users/user-1/favorites/tracks')) {
          final offset = int.parse(
            request.url.queryParameters['offset'] ?? '0',
          );
          callCount++;
          if (offset == 0) {
            // First page returns 100 items
            final items = List.generate(
              100,
              (i) => {
                'item': {'id': i + 1},
              },
            );
            return http.Response(jsonEncode({'items': items}), 200);
          } else if (offset == 100) {
            // Second page returns 5 items
            final items = List.generate(
              5,
              (i) => {
                'item': {'id': 100 + i + 1},
              },
            );
            return http.Response(jsonEncode({'items': items}), 200);
          }
        }
        return http.Response('', 404);
      });

      final service = TidalService.create(client: client);
      final server = _testServer(token: _validToken());

      final ids = await service.getFavoriteTrackIds(server);
      expect(ids.length, 105);
      expect(callCount, 2);
      expect(ids.contains('1'), isTrue);
      expect(ids.contains('105'), isTrue);
    });
  });

  group('TIDAL Liked Songs Optimistic Sync in Riverpod', () {
    test(
      'toggling favorite optimistically updates tidalLikedSongsProvider and isSongFavoriteProvider',
      () async {
        final addedTrackIds = <String>[];
        final client = MockClient((request) async {
          if (request.url.path.contains('/users/user-1/favorites/tracks') &&
              request.method == 'POST') {
            addedTrackIds.add(request.bodyFields['trackId'] ?? '');
            return http.Response('', 200);
          }
          if (request.url.path.contains('/users/user-1/favorites/tracks')) {
            return http.Response(jsonEncode({'items': []}), 200);
          }
          return http.Response('', 404);
        });

        final mockService = TidalService.create(client: client);
        final server = _testServer(token: _validToken());

        final container = ProviderContainer(
          overrides: [
            favoritesServiceProvider.overrideWithValue(
              FavoritesService(songRepository: _FakeSongRepository()),
            ),
            tidalServiceProvider.overrideWithValue(mockService),
            tidalServerProvider.overrideWith(
              () => _MockTidalServerNotifier(server),
            ),
          ],
        );
        addTearDown(container.dispose);

        const song = Song(
          id: 'tidal_1_999999',
          title: 'Brand New Favorite',
          artist: 'Artist',
          duration: Duration(minutes: 3),
          fileType: 'flac',
          sourceType: NetworkProtocol.tidal,
          remoteId: '999999',
        );

        // Keep providers alive during test
        final sub = container.listen(favoritesProvider, (_, __) {});
        final subLiked = container.listen(tidalLikedSongsProvider, (_, __) {});
        final subFavIds = container.listen(
          tidalFavoriteTrackIdsProvider,
          (_, __) {},
        );
        addTearDown(() {
          sub.close();
          subLiked.close();
          subFavIds.close();
        });

        // Initially, song is not favorite
        expect(container.read(isSongFavoriteProvider(song.id)), isFalse);

        // Toggle favorite on the song
        final isNowFav = await container
            .read(favoritesProvider.notifier)
            .toggleFavorite(song.id, song: song);
        expect(isNowFav, isTrue);

        // Instantly recognized as favorite
        expect(container.read(isSongFavoriteProvider(song.id)), isTrue);

        // Instantly visible at top of tidalLikedSongsProvider
        final likedSongs = await container.read(tidalLikedSongsProvider.future);
        expect(likedSongs.isNotEmpty, isTrue);
        expect(likedSongs.first.id, song.id);
        expect(likedSongs.first.title, 'Brand New Favorite');

        // Allow background unawaited network dispatch to execute
        await Future.delayed(const Duration(milliseconds: 50));

        // TIDAL API was called with the numeric trackId
        expect(addedTrackIds.contains('999999'), isTrue);

        // Un-toggling removes the song
        final isNowUnfav = await container
            .read(favoritesProvider.notifier)
            .toggleFavorite(song.id, song: song);
        expect(isNowUnfav, isFalse);
        expect(container.read(isSongFavoriteProvider(song.id)), isFalse);

        final likedSongsAfter = await container.read(
          tidalLikedSongsProvider.future,
        );
        expect(likedSongsAfter.any((s) => s.id == song.id), isFalse);
      },
    );
  });
}

class _FakeSongRepository implements SongRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  Future<List<Song>> getAllSongs() async => [];
}
