import 'dart:async';

import 'package:flick/features/tidal/providers/tidal_providers.dart';
import 'package:flick/features/tidal/screens/tidal_playlist_screen.dart';
import 'package:flick/features/tidal/screens/tidal_playlists_screen.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Playlists shows user playlists and only import/create actions', (
    tester,
  ) async {
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
              {'uuid': 'playlist-2', 'title': 'Road Trip', 'numberOfItems': 11},
            ],
          ),
        ],
        child: const MaterialApp(home: TidalPlaylistsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Playlists'), findsOneWidget);
    expect(find.text('Collection Playlist'), findsOneWidget);
    expect(find.text('3 tracks'), findsOneWidget);
    expect(find.text('Road Trip'), findsOneWidget);
    expect(find.text('11 tracks'), findsOneWidget);
    expect(find.byTooltip('Import Playlist from JSON'), findsOneWidget);
    expect(find.byTooltip('Create TIDAL Playlist'), findsOneWidget);
    expect(find.byTooltip('Refresh Playlists'), findsNothing);
  });

  testWidgets('Playlist tile opens its detail screen', (tester) async {
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
        ],
        child: const MaterialApp(home: TidalPlaylistsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Collection Playlist'));
    await tester.pumpAndSettle();

    expect(find.byType(TidalPlaylistScreen), findsOneWidget);
  });

  testWidgets('Playlists has create and import options when empty', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentSongProvider.overrideWith((ref) => null),
          tidalUserPlaylistsProvider.overrideWith((ref) async => []),
        ],
        child: const MaterialApp(home: TidalPlaylistsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('No playlists found in your TIDAL library.'),
      findsOneWidget,
    );
    expect(find.text('Create Playlist'), findsOneWidget);
    expect(find.text('Import JSON'), findsOneWidget);
  });

  testWidgets('pull-to-refresh reloads user playlists', (tester) async {
    var loads = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentSongProvider.overrideWith((ref) => null),
          tidalUserPlaylistsProvider.overrideWith((ref) async {
            loads++;
            return [];
          }),
        ],
        child: const MaterialApp(home: TidalPlaylistsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final initialLoads = loads;

    unawaited(
      tester.state<RefreshIndicatorState>(find.byType(RefreshIndicator)).show(),
    );
    await tester.pumpAndSettle();

    expect(loads, greaterThan(initialLoads));
  });
}
