import 'package:flick/features/tidal/providers/tidal_providers.dart';
import 'package:flick/features/tidal/screens/tidal_collection_screen.dart';
import 'package:flick/features/tidal/screens/tidal_album_screen.dart';
import 'package:flick/features/tidal/screens/tidal_artist_screen.dart';
import 'package:flick/features/tidal/screens/tidal_liked_albums_screen.dart';
import 'package:flick/features/tidal/screens/tidal_liked_artists_screen.dart';
import 'package:flick/features/tidal/screens/tidal_liked_songs_screen.dart';
import 'package:flick/features/tidal/screens/tidal_playlist_screen.dart';
import 'package:flick/features/tidal/screens/tidal_playlists_screen.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/models/song.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
          tidalLikedAlbumsProvider.overrideWith((ref) async => []),
          tidalLikedArtistsProvider.overrideWith((ref) async => []),
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
    expect(find.text('0 albums'), findsOneWidget);
    expect(find.text('0 artists'), findsOneWidget);
    final likedSongsTile = tester.widget<ListTile>(
      find
          .ancestor(
            of: find.text('Liked Songs'),
            matching: find.byType(ListTile),
          )
          .first,
    );
    expect(likedSongsTile.leading, isA<Icon>());
    expect((likedSongsTile.leading! as Icon).icon, LucideIcons.heart);
    expect((likedSongsTile.leading! as Icon).color, AppColors.textSecondary);
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
          tidalLikedAlbumsProvider.overrideWith((ref) async => []),
          tidalLikedArtistsProvider.overrideWith((ref) async => []),
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
      find.text('No loved albums yet — tap the heart on any album.'),
      findsOneWidget,
    );
    Navigator.of(tester.element(find.byType(TidalLikedAlbumsScreen))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Artists'));
    await tester.pumpAndSettle();
    expect(find.byType(TidalLikedArtistsScreen), findsOneWidget);
    expect(
      find.text('No followed artists yet — tap Follow on any artist.'),
      findsOneWidget,
    );
  });

  testWidgets('liked album and artist lists render entries and open details', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentSongProvider.overrideWith((ref) => null),
          tidalLikedAlbumsProvider.overrideWith(
            (ref) async => [
              {
                'id': 'album-1',
                'title': 'Loved Record',
                'cover': 'cover-1',
                'artist': {'name': 'Album Artist'},
              },
            ],
          ),
          tidalLikedArtistsProvider.overrideWith(
            (ref) async => [
              {
                'id': 'artist-1',
                'name': 'Followed Artist',
                'picture': 'picture-1',
              },
            ],
          ),
          tidalAlbumDetailsProvider('album-1').overrideWith(
            (ref) async => (
              album: <String, dynamic>{
                'id': 'album-1',
                'title': 'Loved Record',
              },
              tracks: <Song>[],
            ),
          ),
          tidalArtistDetailsProvider('artist-1').overrideWith(
            (ref) async => (
              artist: <String, dynamic>{
                'id': 'artist-1',
                'name': 'Followed Artist',
              },
              topTracks: <Song>[],
              albums: <Map<String, dynamic>>[],
              singlesAndEPs: <Map<String, dynamic>>[],
              compilations: <Map<String, dynamic>>[],
            ),
          ),
        ],
        child: const MaterialApp(home: TidalLikedAlbumsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Loved Record'), findsOneWidget);
    expect(find.text('Album Artist'), findsOneWidget);
    await tester.tap(find.text('Loved Record'));
    await tester.pumpAndSettle();
    expect(find.byType(TidalAlbumScreen), findsOneWidget);
    Navigator.of(tester.element(find.byType(TidalAlbumScreen))).pop();
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          currentSongProvider.overrideWith((ref) => null),
          tidalLikedArtistsProvider.overrideWith(
            (ref) async => [
              {
                'id': 'artist-1',
                'name': 'Followed Artist',
                'picture': 'picture-1',
              },
            ],
          ),
          tidalArtistDetailsProvider('artist-1').overrideWith(
            (ref) async => (
              artist: <String, dynamic>{
                'id': 'artist-1',
                'name': 'Followed Artist',
              },
              topTracks: <Song>[],
              albums: <Map<String, dynamic>>[],
              singlesAndEPs: <Map<String, dynamic>>[],
              compilations: <Map<String, dynamic>>[],
            ),
          ),
        ],
        child: const MaterialApp(home: TidalLikedArtistsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Followed Artist'), findsOneWidget);
    await tester.tap(find.text('Followed Artist'));
    await tester.pumpAndSettle();
    expect(find.byType(TidalArtistScreen), findsOneWidget);
  });
}
