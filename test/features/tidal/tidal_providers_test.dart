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
  // The Hub TTL caches are process-global; reset them around every test so a
  // leftover entry can never mask a missing invalidation.
  setUp(() => invalidateTidalHubCache());
  tearDown(() => invalidateTidalHubCache());

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

  // ---------------------------------------------------------------------------
  // Playlist cache coherency (U-HIGH-1).
  //
  // The 30-minute TTL cache is consulted *inside* the provider builder, so
  // `ref.invalidate(tidalUserPlaylistsProvider)` alone rebuilt straight back
  // into the stale entry. Each mutation must also drop the TTL entry, and an
  // explicit refresh must bypass it entirely.
  // ---------------------------------------------------------------------------
  group('Tidal playlist mutations invalidate the TTL cache', () {
    late int listRequests;
    late List<String> remoteTitles;
    late ProviderContainer container;

    late NetworkServerEntity server;

    setUp(() {
      invalidateTidalHubCache();
      listRequests = 0;
      remoteTitles = ['Original'];
      server = _testServer(token: _validToken());

      final client = MockClient((request) async {
        final path = request.url.path;

        if (request.method == 'GET' &&
            path.contains('/users/user-1/playlists')) {
          listRequests++;
          return http.Response(
            jsonEncode({
              'items': [
                for (final title in remoteTitles)
                  {'uuid': 'pl-$title', 'title': title},
              ],
            }),
            200,
          );
        }

        // createPlaylist (OpenAPI POST /v2/playlists).
        if (request.method == 'POST' &&
            path.contains('/playlists') &&
            !path.endsWith('/items')) {
          return http.Response(
            jsonEncode({
              'data': {'id': 'pl-new', 'title': 'New'},
            }),
            200,
          );
        }

        // deletePlaylist and addTracksToPlaylist / addTrackToPlaylist.
        if (request.method == 'DELETE' || path.endsWith('/items')) {
          return http.Response('', 200);
        }

        // _getPlaylistWithEtag and any other metadata read.
        return http.Response('{}', 200);
      });

      container = ProviderContainer(
        overrides: [
          tidalServiceProvider.overrideWithValue(
            TidalService.create(client: client),
          ),
          tidalServerProvider.overrideWith(
            () => _MockTidalServerNotifier(server),
          ),
        ],
      );
      addTearDown(container.dispose);
    });

    Future<List<Map<String, dynamic>>> readPlaylists() {
      return container.read(tidalUserPlaylistsProvider.future);
    }

    test('non-mutation rebuilds still use the TTL cache', () async {
      final first = await readPlaylists();
      expect(first.single['title'], 'Original');
      expect(listRequests, 1);

      // A rebuild that is not a mutation or explicit refresh must stay cached
      // (no regression in API-call reduction).
      container.invalidate(tidalUserPlaylistsProvider);
      final second = await readPlaylists();
      expect(second.single['title'], 'Original');
      expect(listRequests, 1);
    });

    test('createPlaylist invalidates the cache', () async {
      await readPlaylists();
      expect(listRequests, 1);

      remoteTitles = ['Original', 'New'];
      await container
          .read(tidalPlaylistMutationsProvider)
          .createPlaylist(server, title: 'New');

      final playlists = await readPlaylists();
      expect(listRequests, 2);
      expect(
        playlists.map((p) => p['title']),
        containsAll(['Original', 'New']),
      );
    });

    test('addTrackToPlaylist invalidates the cache', () async {
      await readPlaylists();
      expect(listRequests, 1);

      await container
          .read(tidalPlaylistMutationsProvider)
          .addTrackToPlaylist(
            server,
            playlistId: 'pl-Original',
            trackId: '12345',
          );

      await readPlaylists();
      expect(listRequests, 2);
    });

    test('addTracksToPlaylist (import) invalidates the cache', () async {
      await readPlaylists();
      expect(listRequests, 1);

      await container
          .read(tidalPlaylistMutationsProvider)
          .addTracksToPlaylist(
            server,
            playlistId: 'pl-Original',
            trackIds: ['12345', '67890'],
          );

      await readPlaylists();
      expect(listRequests, 2);
    });

    test('deletePlaylist invalidates the cache', () async {
      await readPlaylists();
      expect(listRequests, 1);

      remoteTitles = [];
      final deleted = await container
          .read(tidalPlaylistMutationsProvider)
          .deletePlaylist(server, 'pl-Original');
      expect(deleted, isTrue);

      final playlists = await readPlaylists();
      expect(listRequests, 2);
      expect(playlists, isEmpty);
    });

    test('refreshUserPlaylists bypasses the TTL cache', () async {
      await readPlaylists();
      expect(listRequests, 1);

      // Sanity check: a plain rebuild would be served from the TTL entry.
      container.invalidate(tidalUserPlaylistsProvider);
      await readPlaylists();
      expect(listRequests, 1);

      // Explicit refresh must force a real fetch even inside the TTL window.
      await container
          .read(tidalPlaylistMutationsProvider)
          .refreshUserPlaylists();
      expect(listRequests, 2);
    });
  });

  // ---------------------------------------------------------------------------
  // autoDispose behavior (Tier 3 of the progressive-slowdown fix).
  //
  // The detail providers were keepAlive: every visited album/playlist/artist/
  // mix/feed retained its parsed payload for the process lifetime. They are
  // now autoDispose, so closing the last listener must DISPOSE the instance
  // and a re-listen must REBUILD (fresh fetch).
  //
  // The discriminating probe is the HTTP request count against the mock
  // client: under keepAlive a re-listen would return the retained state and
  // fire zero further requests; under autoDispose the rebuild hits the client
  // again. A canned error response is fine for this: the build still ran and
  // called the service, ending in an error state.
  // ---------------------------------------------------------------------------
  group('TIDAL detail providers autoDispose', () {
    setUp(() {
      // The Hub TTL caches are process-global: drop any leftovers so the
      // probes below never read a stale cached entry instead of refetching.
      invalidateTidalHubCache();
    });

    /// Subscribes via [subscribe] (which starts the provider build), awaits
    /// [resolve] (the provider's build future — a thrown error state is
    /// fine), closes the subscription, waits for the scheduled disposal to
    /// flush, then re-subscribes. Fails unless the re-listen triggered a new
    /// fetch ([requestCount] advanced), which only happens when the provider
    /// actually disposed between the two listeners.
    Future<void> expectRefetchAfterDispose<T>({
      required ProviderSubscription<T> Function() subscribe,
      required Future<void> Function() resolve,
      required int Function() requestCount,
      void Function()? beforeRelisten,
      String? reason,
    }) async {
      Future<void> awaitQuietly(Future<void> future) async {
        try {
          await future;
        } catch (_) {
          // Error state (canned non-200/invalid mock body) — fine: the
          // build still ran and reached the counting client.
        }
      }

      final first = subscribe();
      await awaitQuietly(resolve());
      first.close();
      // Flush the container's scheduled disposal (microtask queue) so the
      // re-listen below observes disposal, not retention.
      await Future<void>.delayed(Duration.zero);

      final beforeRelistenCount = requestCount();
      beforeRelisten?.call();

      final second = subscribe();
      await awaitQuietly(resolve());
      second.close();

      expect(
        requestCount(),
        greaterThan(beforeRelistenCount),
        reason:
            reason ??
            're-listen must rebuild (autoDispose), not return the retained '
                'keepAlive state',
      );
    }

    ProviderContainer probedContainer(MockClient client) {
      final container = ProviderContainer(
        // Riverpod 3 auto-retries failed providers with backoff timers; an
        // error-state probe would flood and `provider.future` would never
        // settle. Retries are not what these tests verify — disable them.
        retry: (_, _) => null,
        overrides: [
          tidalServiceProvider.overrideWithValue(
            TidalService.create(client: client),
          ),
          tidalServerProvider.overrideWith(
            () => _MockTidalServerNotifier(_testServer(token: _validToken())),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test(
      'tidalAlbumDetailsProvider disposes after the last listener',
      () async {
        var requests = 0;
        final client = MockClient((request) async {
          requests++;
          return http.Response('', 500);
        });
        final container = probedContainer(client);

        await expectRefetchAfterDispose(
          subscribe: () =>
              container.listen(tidalAlbumDetailsProvider('album-1'), (_, _) {}),
          resolve: () async =>
              container.read(tidalAlbumDetailsProvider('album-1').future),
          requestCount: () => requests,
        );
      },
    );

    test(
      'tidalPlaylistDetailsProvider disposes after the last listener',
      () async {
        var requests = 0;
        final client = MockClient((request) async {
          requests++;
          return http.Response('', 500);
        });
        final container = probedContainer(client);

        await expectRefetchAfterDispose(
          subscribe: () => container.listen(
            tidalPlaylistDetailsProvider('playlist-1'),
            (_, _) {},
          ),
          resolve: () async =>
              container.read(tidalPlaylistDetailsProvider('playlist-1').future),
          requestCount: () => requests,
        );
      },
    );

    test(
      'tidalArtistDetailsProvider disposes after the last listener',
      () async {
        var requests = 0;
        final client = MockClient((request) async {
          requests++;
          return http.Response('', 500);
        });
        final container = probedContainer(client);

        await expectRefetchAfterDispose(
          subscribe: () => container.listen(
            tidalArtistDetailsProvider('artist-1'),
            (_, _) {},
          ),
          resolve: () async =>
              container.read(tidalArtistDetailsProvider('artist-1').future),
          requestCount: () => requests,
        );
      },
    );

    test(
      'tidalArtistAlbumsProvider disposes after the last listener',
      () async {
        var requests = 0;
        final client = MockClient((request) async {
          requests++;
          return http.Response('', 500);
        });
        final container = probedContainer(client);

        await expectRefetchAfterDispose(
          subscribe: () => container.listen(
            tidalArtistAlbumsProvider('artist-1'),
            (_, _) {},
          ),
          resolve: () async =>
              container.read(tidalArtistAlbumsProvider('artist-1').future),
          requestCount: () => requests,
        );
      },
    );

    test('tidalArtistBioProvider disposes after the last listener', () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        return http.Response('', 500);
      });
      final container = probedContainer(client);

      await expectRefetchAfterDispose(
        subscribe: () =>
            container.listen(tidalArtistBioProvider('artist-1'), (_, _) {}),
        resolve: () async =>
            container.read(tidalArtistBioProvider('artist-1').future),
        requestCount: () => requests,
      );
    });

    test('tidalHomeFeedProvider disposes after the last listener', () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        return http.Response('', 500);
      });
      final container = probedContainer(client);

      await expectRefetchAfterDispose(
        subscribe: () =>
            container.listen(tidalHomeFeedProvider('static'), (_, _) {}),
        resolve: () async =>
            container.read(tidalHomeFeedProvider('static').future),
        requestCount: () => requests,
        // The feed itself has a TTL cache; drop it so the re-listen must not
        // only rebuild but also defer to the cache path hitting the client.
        beforeRelisten: () => invalidateTidalHubCache(feedSlug: 'static'),
      );
    });

    test('tidalMixDetailsProvider disposes after the last listener', () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        return http.Response('', 500);
      });
      final container = probedContainer(client);

      await expectRefetchAfterDispose(
        subscribe: () =>
            container.listen(tidalMixDetailsProvider('mix-1'), (_, _) {}),
        resolve: () async =>
            container.read(tidalMixDetailsProvider('mix-1').future),
        requestCount: () => requests,
      );
    });

    test('tidalLikedSongsProvider disposes after the last listener', () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        return http.Response('', 500);
      });
      final container = probedContainer(client);

      await expectRefetchAfterDispose(
        subscribe: () => container.listen(tidalLikedSongsProvider, (_, _) {}),
        resolve: () async => container.read(tidalLikedSongsProvider.future),
        requestCount: () => requests,
      );
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
