import 'package:flick/features/tidal/providers/tidal_providers.dart';
import 'package:flick/features/tidal/screens/tidal_collection_screen.dart';
import 'package:flick/features/tidal/screens/tidal_liked_albums_screen.dart';
import 'package:flick/features/tidal/screens/tidal_liked_artists_screen.dart';
import 'package:flick/features/tidal/screens/tidal_liked_songs_screen.dart';
import 'package:flick/features/tidal/screens/tidal_playlist_screen.dart';
import 'package:flick/features/tidal/screens/tidal_playlists_screen.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Collection shows four entries without inline playlists', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentSongProvider.overrideWith((ref) => null),
          tidalUserPlaylistsProvider.overrideWith((ref) async => []),
          tidalLikedSongsProvider.overrideWith((ref) async => []),
        ],
        child: const MaterialApp(home: TidalCollectionScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Collection'), findsOneWidget);
    expect(find.text('Liked Songs'), findsOneWidget);
    expect(find.text('Playlists'), findsOneWidget);
    expect(find.text('0 playlists'), findsOneWidget);
    expect(find.text('Albums'), findsOneWidget);
    expect(find.text('Artists'), findsOneWidget);
    expect(
      find.text('Albums you love will appear here once album liking lands.'),
      findsOneWidget,
    );
    expect(
      find.text('Artists you love will appear here once artist liking lands.'),
      findsOneWidget,
    );
    expect(
      find.text('No playlists found in your TIDAL library.'),
      findsNothing,
    );
    expect(find.byTooltip('Import Playlist from JSON'), findsNothing);
    expect(find.byTooltip('Create TIDAL Playlist'), findsNothing);
    expect(find.byTooltip('Refresh Playlists'), findsNothing);
    expect(find.byType(TidalPlaylistScreen), findsNothing);
  });

  testWidgets('Collection rows open their corresponding screens', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentSongProvider.overrideWith((ref) => null),
          tidalUserPlaylistsProvider.overrideWith((ref) async => []),
          tidalLikedSongsProvider.overrideWith((ref) async => []),
        ],
        child: const MaterialApp(home: TidalCollectionScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Liked Songs'));
    await tester.pumpAndSettle();
    expect(find.byType(TidalLikedSongsScreen), findsOneWidget);
    Navigator.of(tester.element(find.byType(TidalLikedSongsScreen))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Playlists'));
    await tester.pumpAndSettle();
    expect(find.byType(TidalPlaylistsScreen), findsOneWidget);
    Navigator.of(tester.element(find.byType(TidalPlaylistsScreen))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Albums'));
    await tester.pumpAndSettle();
    expect(find.byType(TidalLikedAlbumsScreen), findsOneWidget);
    expect(
      find.text('Albums you love will appear here once album liking lands.'),
      findsOneWidget,
    );
    Navigator.of(tester.element(find.byType(TidalLikedAlbumsScreen))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Artists'));
    await tester.pumpAndSettle();
    expect(find.byType(TidalLikedArtistsScreen), findsOneWidget);
    expect(
      find.text('Artists you love will appear here once artist liking lands.'),
      findsOneWidget,
    );
  });
}
