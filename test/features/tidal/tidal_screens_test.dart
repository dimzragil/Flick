import 'dart:convert';

import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/features/tidal/providers/tidal_providers.dart';
import 'package:flick/features/tidal/screens/tidal_album_screen.dart';
import 'package:flick/features/tidal/screens/tidal_hub_screen.dart';
import 'package:flick/features/tidal/screens/tidal_search_screen.dart';
import 'package:flick/models/nav_bar_config.dart';
import 'package:flick/models/song.dart';
import 'package:flick/models/sources/tidal_models.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flick/services/sources/tidal_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

    expect(find.text('TIDAL'), findsOneWidget);
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
          tidalFavoriteMixesProvider.overrideWith((ref) async => []),
          tidalLikedSongsProvider.overrideWith((ref) async => []),
        ],
        child: const MaterialApp(home: TidalHubScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('TIDAL'), findsOneWidget);
    expect(find.byTooltip('Search'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Image &&
            w.image is AssetImage &&
            (w.image as AssetImage).assetName == 'assets/icons/tidal_logo.png',
      ),
      findsOneWidget,
    );
    expect(find.text('My Playlists'), findsOneWidget);
    expect(find.text('My Audiophile Tracks'), findsOneWidget);
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
      ),
      const Song(
        id: 'tidal_9_2',
        title: 'Track Two',
        artist: 'Test Artist',
        duration: Duration(seconds: 180),
        fileType: 'flac',
        trackNumber: 2,
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
    expect(find.text('Play All'), findsOneWidget);
    expect(find.text('Shuffle'), findsOneWidget);
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
            tidalFavoriteMixesProvider.overrideWith((ref) async => []),
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
