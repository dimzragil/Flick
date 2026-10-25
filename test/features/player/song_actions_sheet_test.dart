import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/features/player/widgets/player_navigation.dart';
import 'package:flick/features/player/widgets/song_actions_sheet.dart';
import 'package:flick/features/player/widgets/song_metadata_sheet.dart';
import 'package:flick/features/tidal/providers/tidal_providers.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/player_service.dart';
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

Future<void> _pumpPlayerActions(WidgetTester tester, Song song) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tidalServerProvider.overrideWith(() => _MockTidalServerNotifier(null)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => SongActionsSheet.show(
                context,
                playerService: _FakePlayerService(),
                song: song,
                isVisualizationMode: false,
                onShowLyrics: () {},
                onToggleVisualization: (_) {},
                onShowPlayerLayout: (_) {},
                navigation: _FakePlayerNavigation(),
              ),
              child: const Text('Open player menu'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open player menu'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Player menu labels the metadata tile Credits in place', (
    tester,
  ) async {
    await _pumpPlayerActions(tester, _tidalSong);

    expect(find.text('Credits'), findsOneWidget);
    expect(find.text('View Metadata'), findsNothing);

    final refreshY = tester.getTopLeft(find.text('Refresh Motion Art')).dy;
    final creditsY = tester.getTopLeft(find.text('Credits')).dy;
    final lyricsY = tester.getTopLeft(find.text('Lyrics')).dy;
    expect(creditsY, greaterThan(refreshY));
    expect(lyricsY, greaterThan(creditsY));
  });

  testWidgets('Player Credits tile opens the credits sheet for TIDAL', (
    tester,
  ) async {
    await _pumpPlayerActions(tester, _tidalSong);

    await tester.ensureVisible(find.text('Credits'));
    await tester.tap(find.text('Credits'));
    await tester.pumpAndSettle();

    expect(find.byType(SongActionsSheet), findsNothing);
    expect(find.byType(SongMetadataSheet), findsOneWidget);
    expect(find.text('Not signed in to TIDAL'), findsOneWidget);
  });

  testWidgets('Player Credits tile still shows metadata rows for local songs', (
    tester,
  ) async {
    await _pumpPlayerActions(tester, _localSong);

    await tester.ensureVisible(find.text('Credits'));
    await tester.tap(find.text('Credits'));
    await tester.pumpAndSettle();

    expect(find.byType(SongMetadataSheet), findsOneWidget);
    expect(find.text('Song Metadata'), findsOneWidget);
    expect(find.text('Title'), findsOneWidget);
  });
}

class _FakePlayerService implements PlayerService {
  final ValueNotifier<Song?> _currentSong = ValueNotifier(null);

  @override
  ValueNotifier<Song?> get currentSongNotifier => _currentSong;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayerNavigation implements PlayerNavigation {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockTidalServerNotifier extends TidalServerNotifier {
  final NetworkServerEntity? _server;

  _MockTidalServerNotifier(this._server);

  @override
  Future<NetworkServerEntity?> build() async {
    return _server;
  }
}
