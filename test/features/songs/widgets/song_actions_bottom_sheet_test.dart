import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/features/player/widgets/song_metadata_sheet.dart';
import 'package:flick/features/songs/widgets/song_actions_bottom_sheet.dart';
import 'package:flick/features/tidal/providers/tidal_providers.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/favorites_provider.dart';
import 'package:flick/services/sources/network_source_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const Song _tidalSong = Song(
  id: 'tidal-1',
  title: 'Get Lucky',
  artist: 'Daft Punk',
  duration: Duration(minutes: 6),
  fileType: 'FLAC',
  filePath: 'tidal://20115564',
  sourceType: NetworkProtocol.tidal,
  remoteId: '20115564',
);

const Song _localSong = Song(
  id: 'local-1',
  title: 'Local Track',
  artist: 'Local Artist',
  duration: Duration(minutes: 3),
  fileType: 'FLAC',
  filePath: '/music/local.flac',
);

const List<String> _tidalLabels = [
  'Play Next',
  'Add to My Favorites',
  'Add to Tidal Playlist',
  'Share',
  'Start Track Radio',
  'Credits',
  'Go to Artist',
  'Go to Album',
];

Future<void> _pumpSongActions(
  WidgetTester tester, {
  required Song song,
  bool isFavorite = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        isSongFavoriteProvider(song.id).overrideWithValue(isFavorite),
        tidalServerProvider.overrideWith(() => _MockTidalServerNotifier(null)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => SongActionsBottomSheet.show(context, song),
              child: const Text('Open menu'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open menu'));
  await tester.pumpAndSettle();
}

void _expectVerticalOrder(WidgetTester tester, List<String> labels) {
  final positions = [
    for (final label in labels) tester.getTopLeft(find.text(label)).dy,
  ];
  for (var i = 1; i < positions.length; i++) {
    expect(
      positions[i],
      greaterThan(positions[i - 1]),
      reason: '"${labels[i]}" must render below "${labels[i - 1]}"',
    );
  }
}

void main() {
  testWidgets('TIDAL variant renders the exact order and labels', (
    tester,
  ) async {
    await _pumpSongActions(tester, song: _tidalSong);

    for (final label in _tidalLabels) {
      expect(find.text(label), findsOneWidget, reason: 'missing "$label"');
    }

    expect(find.text('Add to Favorites'), findsNothing);
    expect(find.text('Remove from My Favorites'), findsNothing);
    expect(find.text('Add to TIDAL Playlist'), findsNothing);
    expect(find.text('View Metadata'), findsNothing);
    expect(find.text('Remove from Playlist'), findsNothing);

    _expectVerticalOrder(tester, _tidalLabels);
  });

  testWidgets('TIDAL variant shows the favorited label variant', (
    tester,
  ) async {
    await _pumpSongActions(tester, song: _tidalSong, isFavorite: true);

    expect(find.text('Remove from My Favorites'), findsOneWidget);
    expect(find.text('Add to My Favorites'), findsNothing);

    _expectVerticalOrder(tester, [
      'Play Next',
      'Remove from My Favorites',
      'Add to Tidal Playlist',
      'Share',
      'Start Track Radio',
      'Credits',
      'Go to Artist',
      'Go to Album',
    ]);
  });

  testWidgets('TIDAL variant hides Share when the song has no file path', (
    tester,
  ) async {
    const songWithoutPath = Song(
      id: 'tidal-2',
      title: 'Get Lucky',
      artist: 'Daft Punk',
      duration: Duration(minutes: 6),
      fileType: 'FLAC',
      sourceType: NetworkProtocol.tidal,
      remoteId: '20115564',
    );

    await _pumpSongActions(tester, song: songWithoutPath);

    expect(find.text('Share'), findsNothing);
    _expectVerticalOrder(tester, [
      'Play Next',
      'Add to My Favorites',
      'Add to Tidal Playlist',
      'Start Track Radio',
      'Credits',
      'Go to Artist',
      'Go to Album',
    ]);
  });

  testWidgets('tapping Credits opens the Player credits sheet', (tester) async {
    await _pumpSongActions(tester, song: _tidalSong);

    await tester.tap(find.text('Credits'));
    await tester.pumpAndSettle();

    expect(find.byType(SongActionsBottomSheet), findsNothing);
    expect(find.byType(SongMetadataSheet), findsOneWidget);
    expect(find.text('Not signed in to TIDAL'), findsOneWidget);
    expect(find.text('Song Metadata'), findsNothing);
  });

  testWidgets('local variant keeps its existing order and labels', (
    tester,
  ) async {
    await _pumpSongActions(tester, song: _localSong);

    const localLabels = [
      'Add to Favorites',
      'Play Next',
      'Add to Playlist',
      'Set Album Art',
      'Edit Metadata',
      'View Metadata',
      'Go to Artist',
      'Go to Album',
      'Share',
      'Delete Song',
    ];

    for (final label in localLabels) {
      expect(find.text(label), findsOneWidget, reason: 'missing "$label"');
    }

    expect(find.text('Add to My Favorites'), findsNothing);
    expect(find.text('Add to Tidal Playlist'), findsNothing);
    expect(find.text('Credits'), findsNothing);

    _expectVerticalOrder(tester, localLabels);
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
