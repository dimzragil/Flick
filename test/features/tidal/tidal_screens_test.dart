import 'dart:async';
import 'dart:convert';

import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/features/tidal/providers/tidal_providers.dart';
import 'package:flick/features/tidal/screens/tidal_album_screen.dart';
import 'package:flick/features/tidal/screens/tidal_artist_screen.dart';
import 'package:flick/features/tidal/screens/tidal_hub_screen.dart';
import 'package:flick/features/tidal/screens/tidal_mix_screen.dart';
import 'package:flick/features/tidal/screens/tidal_playlist_screen.dart';
import 'package:flick/features/tidal/screens/tidal_search_screen.dart';
import 'package:flick/features/tidal/widgets/tidal_shimmer.dart';
import 'package:flick/features/tidal/widgets/tidal_tab_pill.dart';
import 'package:flick/models/nav_bar_config.dart';
import 'package:flick/models/song.dart';
import 'package:flick/models/sources/tidal_models.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flick/services/sources/tidal_service.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class _MockTidalServerNotifier extends TidalServerNotifier {
  final NetworkServerEntity? _server;
  _MockTidalServerNotifier(this._server);

  @override
  Future<NetworkServerEntity?> build() async {
    return _server;
  }
}

/// Keeps the search provider in its first-query loading state so the loading
/// skeleton stays on screen for the duration of the test.
class _MockSearchLoadingNotifier extends TidalSearchNotifier {
  @override
  TidalSearchResults build() =>
      const TidalSearchResults(isLoading: true, query: 'test');
}

NetworkServerEntity _serverWithToken() => NetworkServerEntity()
  ..id = 9
  ..label = 'Tidal'
  ..protocol = 'tidal'
  ..baseUrl = TidalService.tidalBaseUrl
  ..token = jsonEncode({
    'access_token': 'token-123',
    'refresh_token': 'ref-123',
    'user_id': 'user-1',
    'country_code': 'NO',
    'expires_at_ms': DateTime.now()
        .add(const Duration(hours: 1))
        .millisecondsSinceEpoch,
  });

void main() {
  testWidgets('TidalHubScreen displays sign-in view when unauthenticated', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentSongProvider.overrideWith((ref) => null),
          tidalServerProvider.overrideWith(
            () => _MockTidalServerNotifier(null),
          ),
        ],
        child: const MaterialApp(home: TidalHubScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate(
        (w) =>
            w is SvgPicture &&
            w.bytesLoader is SvgAssetLoader &&
            (w.bytesLoader as SvgAssetLoader).assetName ==
                'assets/icons/tidal_logo.svg',
      ),
      findsNWidgets(2), // Header + sign-in body
    );
    expect(find.text('TIDAL HiFi & Master'), findsOneWidget);
    expect(find.text('Sign in with TIDAL'), findsOneWidget);
  });

  testWidgets('TidalHubScreen displays logged-in hub when authenticated', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentSongProvider.overrideWith((ref) => null),
          tidalServerProvider.overrideWith(
            () => _MockTidalServerNotifier(_serverWithToken()),
          ),
          tidalUserPlaylistsProvider.overrideWith(
            (ref) async => [
              {
                'uuid': 'pl-1',
                'title': 'My Audiophile Tracks',
                'numberOfTracks': 10,
              },
            ],
          ),
          tidalHomeFeedProvider.overrideWith(
            (ref, slug) async => TidalHomeFeed.empty,
          ),
          tidalLikedSongsProvider.overrideWith((ref) async => []),
        ],
        child: const MaterialApp(home: TidalHubScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.byTooltip('Search'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is SvgPicture &&
            w.bytesLoader is SvgAssetLoader &&
            (w.bytesLoader as SvgAssetLoader).assetName ==
                'assets/icons/tidal_logo.svg',
      ),
      findsWidgets,
    );
    expect(find.text('My Playlists'), findsOneWidget);
    expect(find.text('My Audiophile Tracks'), findsOneWidget);
  });

  testWidgets(
    'TidalHubScreen only builds the feed sections near the viewport',
    (tester) async {
      final sections = [
        for (var i = 0; i < 12; i++)
          TidalHomeSection(
            title: 'Carousel $i',
            sectionType: 'HORIZONTAL_LIST',
            items: [
              TidalHomeItem(id: 'item-$i', title: 'Item $i', type: 'ALBUM'),
            ],
          ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentSongProvider.overrideWith((ref) => null),
            tidalServerProvider.overrideWith(
              () => _MockTidalServerNotifier(_serverWithToken()),
            ),
            tidalUserPlaylistsProvider.overrideWith((ref) async => []),
            tidalHomeFeedProvider.overrideWith(
              (ref, slug) async => TidalHomeFeed(sections: sections),
            ),
            tidalLikedSongsProvider.overrideWith((ref) async => []),
          ],
          child: const MaterialApp(home: TidalHubScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // The first section is on screen…
      expect(find.text('Carousel 0'), findsOneWidget);
      // …while a section far below the fold is not inflated at all. The feed
      // used to be one Column child of the ListView, which built every section.
      expect(find.text('Carousel 11'), findsNothing);

      await tester.scrollUntilVisible(
        find.text('Carousel 11'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Carousel 11'), findsOneWidget);
    },
  );

  testWidgets(
    'TidalHubScreen carousels keep independent offsets across dispose/remount',
    (tester) async {
      // Regression test for the bbba76e6 virtualization fallout: keyless
      // horizontal carousels under the vertical feed's PageStorageKey all
      // shared one PageStorage slot, so a remounted carousel restored
      // another carousel's (or the feed's) offset, clamped to its own end.
      final sections = [
        TidalHomeSection(
          title: 'Carousel 0',
          sectionType: 'HORIZONTAL_LIST',
          items: [
            for (var j = 0; j < 10; j++)
              TidalHomeItem(id: 'c0-$j', title: 'C0 Item $j', type: 'ALBUM'),
          ],
        ),
        TidalHomeSection(
          title: 'Carousel 1',
          sectionType: 'HORIZONTAL_LIST',
          items: [
            for (var j = 0; j < 10; j++)
              TidalHomeItem(id: 'c1-$j', title: 'C1 Item $j', type: 'ALBUM'),
          ],
        ),
        for (var i = 2; i < 12; i++)
          TidalHomeSection(
            title: 'Carousel $i',
            sectionType: 'HORIZONTAL_LIST',
            items: [
              TidalHomeItem(id: 'item-$i', title: 'Item $i', type: 'ALBUM'),
            ],
          ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentSongProvider.overrideWith((ref) => null),
            tidalServerProvider.overrideWith(
              () => _MockTidalServerNotifier(_serverWithToken()),
            ),
            tidalUserPlaylistsProvider.overrideWith((ref) async => []),
            tidalHomeFeedProvider.overrideWith(
              (ref, slug) async => TidalHomeFeed(sections: sections),
            ),
            tidalLikedSongsProvider.overrideWith((ref) async => []),
          ],
          child: const MaterialApp(home: TidalHubScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // Scroll the first carousel right; its offset is saved on scroll end.
      await tester.drag(find.text('C0 Item 0'), const Offset(-400, 0));
      await tester.pumpAndSettle();
      expect(find.text('C0 Item 0'), findsNothing);

      // Scroll the feed to the bottom (disposing the top sections) and back
      // up: remounted carousels must restore their OWN offset, not a shared
      // one — Carousel 1 never scrolled, so it comes back at the start.
      await tester.scrollUntilVisible(
        find.text('Carousel 11'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Carousel 1'),
        -400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('C1 Item 0'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('Carousel 0'),
        -400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      // Carousel 0 remembers its own scroll position (still scrolled right).
      expect(find.text('C0 Item 0'), findsNothing);
      expect(find.text('C0 Item 4'), findsOneWidget);
    },
  );

  testWidgets('TidalHubScreen vertical feed keeps a 1000px cache lookahead', (
    tester,
  ) async {
    // Pins the Option A scroll-jank fix: the default 250px cache covered
    // barely one ~253px carousel section, so every section entry paid a
    // remount + cover decode on a scroll frame.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentSongProvider.overrideWith((ref) => null),
          tidalServerProvider.overrideWith(
            () => _MockTidalServerNotifier(_serverWithToken()),
          ),
          tidalUserPlaylistsProvider.overrideWith((ref) async => []),
          tidalHomeFeedProvider.overrideWith(
            (ref, slug) async => TidalHomeFeed(sections: []),
          ),
          tidalLikedSongsProvider.overrideWith((ref) async => []),
        ],
        child: const MaterialApp(home: TidalHubScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final feedList = tester.widget<ListView>(
      find.byKey(const PageStorageKey<String>('tidal-hub-feed')),
    );
    // ignore: deprecated_member_use
    expect(feedList.cacheExtent, 1000.0);
  });

  testWidgets(
    'TidalSearchScreen displays search bar and category filter chips',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentSongProvider.overrideWith((ref) => null),
            tidalServerProvider.overrideWith(
              () => _MockTidalServerNotifier(_serverWithToken()),
            ),
          ],
          child: const MaterialApp(home: TidalSearchScreen()),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('TIDAL Search'), findsOneWidget);
      expect(find.text('Search songs, albums, artists...'), findsOneWidget);
      expect(find.text('All'), findsOneWidget);
      expect(find.text('Tracks'), findsOneWidget);
      expect(find.text('Albums'), findsOneWidget);
      expect(find.text('Artists'), findsOneWidget);
      expect(find.text('Playlists'), findsOneWidget);
      expect(find.text('Search TIDAL Catalog'), findsOneWidget);
    },
  );

  testWidgets('TidalAlbumScreen displays album details and tracklist', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const testAlbumId = 'alb-99';
    final testTracks = [
      const Song(
        id: 'tidal_9_1',
        title: 'Track One',
        artist: 'Test Artist',
        duration: Duration(seconds: 240),
        fileType: 'flac',
        trackNumber: 1,
        bitDepth: 24,
      ),
      const Song(
        id: 'tidal_9_2',
        title: 'Track Two',
        artist: 'Test Artist',
        duration: Duration(seconds: 180),
        fileType: 'flac',
        trackNumber: 2,
        bitDepth: 24,
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentSongProvider.overrideWith((ref) => null),
          tidalServerProvider.overrideWith(
            () => _MockTidalServerNotifier(_serverWithToken()),
          ),
          tidalAlbumDetailsProvider(testAlbumId).overrideWith(
            (ref) async => (
              album: {
                'id': testAlbumId,
                'title': 'Test Album Title',
                'artist': {'name': 'Test Artist'},
                'audioQuality': 'HI_RES_LOSSLESS',
                'releaseDate': '2024-01-01',
              },
              tracks: testTracks,
            ),
          ),
        ],
        child: const MaterialApp(home: TidalAlbumScreen(albumId: testAlbumId)),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Test Album Title'), findsNWidgets(2)); // AppBar + Header
    // Unified action capsule replaces the old text buttons.
    expect(find.byTooltip('Play'), findsOneWidget);
    expect(find.byTooltip('Shuffle'), findsOneWidget);
    expect(find.byTooltip('Queue'), findsOneWidget);
    expect(find.byTooltip('More'), findsOneWidget);
    expect(find.text('Track One'), findsOneWidget);
    expect(find.text('Track Two'), findsOneWidget);
    expect(find.text('HI-RES LOSSLESS 24-BIT'), findsOneWidget);
  });

  testWidgets(
    'TidalHubScreen keeps hero tags unique and navigates without duplicates',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // The same album appears in two feed sections, so its covers must get
      // distinct hero tags (scope + index) or the next push would assert.
      const albumItem = TidalHomeItem(
        id: 'alb-77',
        title: 'Twice Shown Album',
        type: 'ALBUM',
        imageUrl: 'https://example.com/cover.jpg',
        raw: {'artifactId': 'alb-77', 'title': 'Twice Shown Album'},
      );
      final feed = TidalHomeFeed(
        sections: const [
          TidalHomeSection(
            title: 'Albums For You',
            sectionType: 'HORIZONTAL_LIST',
            items: [albumItem],
          ),
          TidalHomeSection(
            title: 'New Releases',
            sectionType: 'HORIZONTAL_LIST',
            items: [albumItem],
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentSongProvider.overrideWith((ref) => null),
            tidalServerProvider.overrideWith(
              () => _MockTidalServerNotifier(_serverWithToken()),
            ),
            tidalHomeFeedProvider.overrideWith((ref, slug) async => feed),
            tidalUserPlaylistsProvider.overrideWith(
              (ref) async => [
                {
                  'uuid': 'pl-1',
                  'title': 'My Audiophile Tracks',
                  'numberOfTracks': 10,
                },
              ],
            ),
            tidalLikedSongsProvider.overrideWith((ref) async => []),
            tidalAlbumDetailsProvider('alb-77').overrideWith(
              (ref) async => (
                album: {
                  'id': 'alb-77',
                  'title': 'Twice Shown Album',
                  'artist': {'name': 'Test Artist'},
                  'cover': 'cover-uuid',
                },
                tracks: const <Song>[],
              ),
            ),
          ],
          child: const MaterialApp(home: TidalHubScreen()),
        ),
      );

      await tester.pumpAndSettle();

      final tags = tester
          .widgetList<Hero>(find.byType(Hero))
          .map((hero) => hero.tag)
          .toList();
      expect(tags, isNotEmpty);
      expect(
        tags.length,
        tags.toSet().length,
        reason: 'duplicate hero tags within the hub route: $tags',
      );

      // Scrolling the hub (dragging across cards) must not throw or leave
      // press-scales stuck; rows mounted after the entrance window render
      // statically instead of replaying the animation.
      await tester.fling(
        find.byType(ListView).first,
        const Offset(0, -300),
        1500,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Navigating from the hub must not throw a duplicate-tag assertion.
      await tester.ensureVisible(find.text('Twice Shown Album').first);
      await tester.tap(find.text('Twice Shown Album').first);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(TidalAlbumScreen), findsOneWidget);
    },
  );

  testWidgets('TidalHubScreen shows shimmer skeletons while content loads', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentSongProvider.overrideWith((ref) => null),
          tidalServerProvider.overrideWith(
            () => _MockTidalServerNotifier(_serverWithToken()),
          ),
          // Feed and playlists stay pending so the skeletons stay mounted.
          // Never pumpAndSettle here: the shimmer repeats forever.
          tidalHomeFeedProvider.overrideWith(
            (ref, slug) => Completer<TidalHomeFeed>().future,
          ),
          tidalUserPlaylistsProvider.overrideWith(
            (ref) => Completer<List<Map<String, dynamic>>>().future,
          ),
          tidalLikedSongsProvider.overrideWith((ref) async => []),
        ],
        child: const MaterialApp(home: TidalHubScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(TidalHubFeedSkeleton), findsOneWidget);
    expect(find.byType(TidalListSkeleton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TidalSearchScreen shows the shimmer skeleton on first search', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentSongProvider.overrideWith((ref) => null),
          tidalServerProvider.overrideWith(
            () => _MockTidalServerNotifier(_serverWithToken()),
          ),
          tidalSearchProvider.overrideWith(_MockSearchLoadingNotifier.new),
        ],
        child: const MaterialApp(home: TidalSearchScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(TidalSearchSkeleton), findsOneWidget);
    // Category pills still render after the AnimatedContainer swap.
    expect(
      find.byType(TidalTabPill),
      findsNWidgets(TidalSearchCategory.values.length),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('hub drill-in pushes a shared-axis route (300ms/250ms)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const albumItem = TidalHomeItem(
      id: 'alb-55',
      title: 'Shared Axis Album',
      type: 'ALBUM',
      imageUrl: 'https://example.com/cover.jpg',
      raw: {'artifactId': 'alb-55', 'title': 'Shared Axis Album'},
    );
    const feed = TidalHomeFeed(
      sections: [
        TidalHomeSection(
          title: 'Albums For You',
          sectionType: 'HORIZONTAL_LIST',
          items: [albumItem],
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentSongProvider.overrideWith((ref) => null),
          tidalServerProvider.overrideWith(
            () => _MockTidalServerNotifier(_serverWithToken()),
          ),
          tidalHomeFeedProvider.overrideWith((ref, slug) async => feed),
          tidalUserPlaylistsProvider.overrideWith((ref) async => []),
          tidalLikedSongsProvider.overrideWith((ref) async => []),
          tidalAlbumDetailsProvider('alb-55').overrideWith(
            (ref) async => (
              album: {
                'id': 'alb-55',
                'title': 'Shared Axis Album',
                'artist': {'name': 'Test Artist'},
              },
              tracks: const <Song>[],
            ),
          ),
        ],
        child: const MaterialApp(home: TidalHubScreen()),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.text('Shared Axis Album').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Mid-transition the destination is already mounted and the route runs
    // the shared-axis timing.
    expect(find.byType(TidalAlbumScreen), findsOneWidget);
    final route = ModalRoute.of(tester.element(find.byType(TidalAlbumScreen)));
    expect(route, isA<PageRouteBuilder<dynamic>>());
    expect(route!.transitionDuration, const Duration(milliseconds: 300));
    expect(route.reverseTransitionDuration, const Duration(milliseconds: 250));

    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(TidalAlbumScreen), findsOneWidget);
  });

  testWidgets('TidalMixScreen shows the banner skeleton while loading', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentSongProvider.overrideWith((ref) => null),
          tidalServerProvider.overrideWith(
            () => _MockTidalServerNotifier(_serverWithToken()),
          ),
          tidalMixDetailsProvider.overrideWith(
            (ref, mixId) => Completer<TidalMix>().future,
          ),
        ],
        child: const MaterialApp(home: TidalMixScreen(mixId: 'mix-1')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(TidalBannerBodySkeleton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TidalMixScreen shows capsule and About description', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentSongProvider.overrideWith((ref) => null),
          tidalServerProvider.overrideWith(
            () => _MockTidalServerNotifier(_serverWithToken()),
          ),
          tidalMixDetailsProvider('mix-1').overrideWith(
            (ref) async => const TidalMix(
              mixId: 'mix-1',
              title: 'Test Mix',
              mixType: 'DAILY_MIX',
              description: 'A radio station just for you.',
            ),
          ),
        ],
        child: const MaterialApp(home: TidalMixScreen(mixId: 'mix-1')),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Test Mix'), findsOneWidget);
    expect(find.text('About this mix'), findsOneWidget);
    expect(find.text('A radio station just for you.'), findsOneWidget);
    // Capsule mapping: Play/Shuffle/More only — no Favorite or Queue.
    expect(find.byTooltip('Play'), findsOneWidget);
    expect(find.byTooltip('Shuffle'), findsOneWidget);
    expect(find.byTooltip('More'), findsOneWidget);
    expect(find.byTooltip('Follow artist'), findsNothing);
    expect(find.byTooltip('Queue'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TidalPlaylistScreen shows the banner skeleton while loading', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentSongProvider.overrideWith((ref) => null),
          tidalServerProvider.overrideWith(
            () => _MockTidalServerNotifier(_serverWithToken()),
          ),
          tidalPlaylistDetailsProvider.overrideWith(
            (ref, playlistId) =>
                Completer<
                      ({Map<String, dynamic> playlist, List<Song> tracks})
                    >()
                    .future,
          ),
        ],
        child: const MaterialApp(home: TidalPlaylistScreen(playlistId: 'pl-1')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(TidalBannerBodySkeleton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TidalArtistScreen shows capsule, bio and top tracks', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const artistId = 'art-1';

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentSongProvider.overrideWith((ref) => null),
          tidalServerProvider.overrideWith(
            () => _MockTidalServerNotifier(_serverWithToken()),
          ),
          tidalArtistDetailsProvider(artistId).overrideWith(
            (ref) async => (
              artist: {'id': artistId, 'name': 'Test Artist'},
              topTracks: const [
                Song(
                  id: 'tidal_9_1',
                  title: 'Top One',
                  artist: 'Test Artist',
                  duration: Duration(seconds: 200),
                  fileType: 'flac',
                ),
              ],
              albums: const <Map<String, dynamic>>[],
              singlesAndEPs: const <Map<String, dynamic>>[],
              compilations: const <Map<String, dynamic>>[],
            ),
          ),
          tidalArtistBioProvider(
            artistId,
          ).overrideWith((ref) async => 'Born in Oslo.'),
          tidalFavoriteArtistIdsProvider.overrideWith(
            (ref) async => <String>{},
          ),
        ],
        child: const MaterialApp(home: TidalArtistScreen(artistId: artistId)),
      ),
    );

    await tester.pumpAndSettle();

    expect(
      find.text('Test Artist'),
      findsNWidgets(3), // AppBar + header + track subtitle
    );
    // Capsule mapping: Follow instead of Favorite, no Queue.
    expect(find.byTooltip('Follow artist'), findsOneWidget);
    expect(find.byTooltip('Play'), findsOneWidget);
    expect(find.byTooltip('Shuffle'), findsOneWidget);
    expect(find.byTooltip('More'), findsOneWidget);
    expect(find.byTooltip('Queue'), findsNothing);
    expect(find.text('About'), findsOneWidget);
    expect(find.text('Born in Oslo.'), findsOneWidget);
    expect(find.text('Top One'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'TidalArtistScreen falls back to selectedAlbumCoverFallback without a picture',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const artistId = 'art-1';

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentSongProvider.overrideWith((ref) => null),
            tidalServerProvider.overrideWith(
              () => _MockTidalServerNotifier(_serverWithToken()),
            ),
            tidalArtistDetailsProvider(artistId).overrideWith(
              (ref) async => (
                artist: {
                  'id': artistId,
                  'name': 'Test Artist',
                  'selectedAlbumCoverFallback': 'fb-uuid',
                },
                topTracks: const <Song>[],
                albums: const <Map<String, dynamic>>[],
                singlesAndEPs: const <Map<String, dynamic>>[],
                compilations: const <Map<String, dynamic>>[],
              ),
            ),
            tidalArtistBioProvider(artistId).overrideWith((ref) async => null),
            tidalFavoriteArtistIdsProvider.overrideWith(
              (ref) async => <String>{},
            ),
          ],
          child: const MaterialApp(home: TidalArtistScreen(artistId: artistId)),
        ),
      );

      await tester.pumpAndSettle();

      final fallbackUrl = TidalService.artistPictureUrl('fb-uuid', size: 320);
      expect(fallbackUrl, isNotEmpty);
      // The avatar is the only CachedImageWidget inside the ClipOval.
      final avatar = find.descendant(
        of: find.byType(ClipOval),
        matching: find.byType(CachedImageWidget),
      );
      expect(avatar, findsOneWidget);
      expect(tester.widget<CachedImageWidget>(avatar).imagePath, fallbackUrl);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TidalArtistScreen falls back to the first album cover when no artist image',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const artistId = 'art-1';

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentSongProvider.overrideWith((ref) => null),
            tidalServerProvider.overrideWith(
              () => _MockTidalServerNotifier(_serverWithToken()),
            ),
            tidalArtistDetailsProvider(artistId).overrideWith(
              (ref) async => (
                artist: {'id': artistId, 'name': 'Test Artist'},
                topTracks: const <Song>[],
                albums: const [
                  {'id': 'alb-1', 'title': 'Album One', 'cover': 'abc-cover'},
                ],
                singlesAndEPs: const <Map<String, dynamic>>[],
                compilations: const <Map<String, dynamic>>[],
              ),
            ),
            tidalArtistBioProvider(artistId).overrideWith((ref) async => null),
            tidalFavoriteArtistIdsProvider.overrideWith(
              (ref) async => <String>{},
            ),
          ],
          child: const MaterialApp(home: TidalArtistScreen(artistId: artistId)),
        ),
      );

      await tester.pumpAndSettle();

      final albumCoverUrl = TidalService.artistPictureUrl(
        'abc-cover',
        size: 320,
      );
      expect(albumCoverUrl, isNotEmpty);
      final avatar = find.descendant(
        of: find.byType(ClipOval),
        matching: find.byType(CachedImageWidget),
      );
      expect(avatar, findsOneWidget);
      expect(tester.widget<CachedImageWidget>(avatar).imagePath, albumCoverUrl);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('TidalPlaylistScreen shows capsule and About description', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentSongProvider.overrideWith((ref) => null),
          tidalServerProvider.overrideWith(
            () => _MockTidalServerNotifier(_serverWithToken()),
          ),
          tidalPlaylistDetailsProvider('pl-1').overrideWith(
            (ref) async => (
              playlist: {
                'uuid': 'pl-1',
                'title': 'Test Playlist',
                'description': 'A long playlist description.',
              },
              tracks: const <Song>[],
            ),
          ),
        ],
        child: const MaterialApp(home: TidalPlaylistScreen(playlistId: 'pl-1')),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Test Playlist'), findsOneWidget);
    expect(find.text('About this playlist'), findsOneWidget);
    expect(find.text('A long playlist description.'), findsOneWidget);
    // Capsule mapping: Play/Shuffle/More only — no Favorite or Queue.
    expect(find.byTooltip('Play'), findsOneWidget);
    expect(find.byTooltip('Shuffle'), findsOneWidget);
    expect(find.byTooltip('More'), findsOneWidget);
    expect(find.byTooltip('Follow artist'), findsNothing);
    expect(find.byTooltip('Queue'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  group('NavBarButton.tidal and navigation', () {
    test('NavBarButton.tidal has correct properties', () {
      expect(NavBarButton.tidal.pageIndex, 9);
      expect(NavBarButton.tidal.label, 'Tidal');
      expect(NavBarButton.tidal.icon, LucideIcons.waves);
      expect(NavBarButton.values.byName('tidal'), NavBarButton.tidal);
    });

    test('NavBarConfig can include and reorder NavBarButton.tidal', () {
      final config = const NavBarConfig().copyWith(
        enabledButtons: [
          NavBarButton.menu,
          NavBarButton.songs,
          NavBarButton.tidal,
          NavBarButton.settings,
        ],
      );

      expect(config.enabledButtons.contains(NavBarButton.tidal), isTrue);
      expect(config.hasAllEssential, isTrue);

      final reordered = config.reorder(2, 0);
      expect(reordered.enabledButtons.first, NavBarButton.tidal);
    });
  });
}
