import 'package:flick/features/tidal/providers/tidal_providers.dart';
import 'package:flick/features/tidal/screens/tidal_collection_screen.dart';
import 'package:flick/features/tidal/screens/tidal_liked_songs_screen.dart';
import 'package:flick/features/tidal/screens/tidal_playlist_screen.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Collection shows its four entries and playlist actions', (
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
      findsOneWidget,
    );
    expect(find.byTooltip('Import Playlist from JSON'), findsOneWidget);
    expect(find.byTooltip('Create TIDAL Playlist'), findsOneWidget);
    expect(find.byTooltip('Refresh Playlists'), findsOneWidget);
    expect(find.byType(TidalPlaylistScreen), findsNothing);
  });

  testWidgets('Liked Songs row opens the liked-songs screen', (tester) async {
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
  });

  testWidgets('Playlist tile opens its playlist detail screen', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentSongProvider.overrideWith((ref) => null),
          tidalUserPlaylistsProvider.overrideWith(
            (ref) async => [
              {
                'uuid': 'playlist-1',
                'title': 'Collection Playlist',
                'numberOfTracks': 3,
              },
            ],
          ),
          tidalLikedSongsProvider.overrideWith((ref) async => []),
        ],
        child: const MaterialApp(home: TidalCollectionScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Collection Playlist'));
    await tester.pumpAndSettle();

    expect(find.byType(TidalPlaylistScreen), findsOneWidget);
  });
}
