import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flick/features/tidal/widgets/tidal_entity_share.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  group('buildTidalShareCaption', () {
    test('album with artist produces exact caption template and tail', () {
      final caption = buildTidalShareCaption(
        type: TidalShareEntityType.album,
        title: 'Abbey Road',
        subtitle: 'The Beatles',
        id: '123456',
      );
      expect(
        caption,
        'Check out this album on Flick: "Abbey Road" by The Beatles https://tidal.com/album/123456',
      );
    });

    test('album without artist omits "by" segment', () {
      final caption = buildTidalShareCaption(
        type: TidalShareEntityType.album,
        title: 'Compilation Vol. 1',
        subtitle: null,
        id: '999',
      );
      expect(
        caption,
        'Check out this album on Flick: "Compilation Vol. 1" https://tidal.com/album/999',
      );
    });

    test('artist produces exact artist template and tail', () {
      final caption = buildTidalShareCaption(
        type: TidalShareEntityType.artist,
        title: 'Taylor Swift',
        id: '789',
      );
      expect(
        caption,
        'Check out this artist on Flick: Taylor Swift https://tidal.com/artist/789',
      );
    });

    test('mix with subtitle/author produces exact mix template and tail', () {
      final caption = buildTidalShareCaption(
        type: TidalShareEntityType.mix,
        title: 'My Daily Discovery',
        subtitle: 'Personalized for you',
        id: 'mix001',
      );
      expect(
        caption,
        'Check out this mix on Flick: "My Daily Discovery" by Personalized for you https://tidal.com/mix/mix001',
      );
    });

    test('mix without subtitle produces mix template without "by"', () {
      final caption = buildTidalShareCaption(
        type: TidalShareEntityType.mix,
        title: 'Chill Mix',
        subtitle: '',
        id: 'mix002',
      );
      expect(
        caption,
        'Check out this mix on Flick: "Chill Mix" https://tidal.com/mix/mix002',
      );
    });

    test('playlist produces exact playlist template and tail', () {
      final caption = buildTidalShareCaption(
        type: TidalShareEntityType.playlist,
        title: 'Summer Hits',
        subtitle: 'TIDAL',
        id: 'pl-abc-123',
      );
      expect(
        caption,
        'Check out this playlist on Flick: "Summer Hits" https://tidal.com/playlist/pl-abc-123',
      );
    });

    test('falls back to default title when title is empty', () {
      expect(
        buildTidalShareCaption(
          type: TidalShareEntityType.album,
          title: '   ',
          subtitle: 'Artist Name',
          id: '1',
        ),
        'Check out this album on Flick: "Album" by Artist Name https://tidal.com/album/1',
      );
      expect(
        buildTidalShareCaption(
          type: TidalShareEntityType.artist,
          title: '',
          id: '2',
        ),
        'Check out this artist on Flick: Artist https://tidal.com/artist/2',
      );
      expect(
        buildTidalShareCaption(
          type: TidalShareEntityType.mix,
          title: '',
          id: '3',
        ),
        'Check out this mix on Flick: "Mix" https://tidal.com/mix/3',
      );
      expect(
        buildTidalShareCaption(
          type: TidalShareEntityType.playlist,
          title: '',
          id: '4',
        ),
        'Check out this playlist on Flick: "Playlist" https://tidal.com/playlist/4',
      );
    });
  });

  group('TidalEntityShareCard widget', () {
    testWidgets('renders album card with title, subtitle, and Album label', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 375,
              child: TidalEntityShareCard(
                title: 'Random Access Memories',
                subtitle: 'Daft Punk',
                type: TidalShareEntityType.album,
              ),
            ),
          ),
        ),
      );

      expect(find.text('Album'), findsOneWidget);
      expect(find.text('Random Access Memories'), findsOneWidget);
      expect(find.text('Daft Punk'), findsOneWidget);
      expect(find.byIcon(Icons.album_rounded), findsOneWidget);
    });

    testWidgets('renders artist card with title and Artist label', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 375,
              child: TidalEntityShareCard(
                title: 'Radiohead',
                type: TidalShareEntityType.artist,
              ),
            ),
          ),
        ),
      );

      expect(find.text('Artist'), findsOneWidget);
      expect(find.text('Radiohead'), findsOneWidget);
      expect(find.byIcon(Icons.person_rounded), findsOneWidget);
    });

    testWidgets('renders mix card with title and subtitle', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 375,
              child: TidalEntityShareCard(
                title: 'Electronic Mix',
                subtitle: 'Various Artists',
                type: TidalShareEntityType.mix,
              ),
            ),
          ),
        ),
      );

      expect(find.text('Mix'), findsOneWidget);
      expect(find.text('Electronic Mix'), findsOneWidget);
      expect(find.text('Various Artists'), findsOneWidget);
    });

    testWidgets('renders playlist card with title and owner', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 375,
              child: TidalEntityShareCard(
                title: 'Lo-Fi Beats',
                subtitle: 'Curator 42',
                type: TidalShareEntityType.playlist,
              ),
            ),
          ),
        ),
      );

      expect(find.text('Playlist'), findsOneWidget);
      expect(find.text('Lo-Fi Beats'), findsOneWidget);
      expect(find.text('Curator 42'), findsOneWidget);
    });
  });

  group('shareTidalEntity', () {
    final validPngBytes = Uint8List.fromList(<int>[
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      0x00,
      0x00,
      0x00,
      0x0D,
      0x49,
      0x48,
      0x44,
      0x52,
      0x00,
      0x00,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x08,
      0x06,
      0x00,
      0x00,
      0x00,
      0x1F,
      0x15,
      0xC4,
      0x89,
      0x00,
      0x00,
      0x00,
      0x0A,
      0x49,
      0x44,
      0x41,
      0x54,
      0x78,
      0x9C,
      0x63,
      0x00,
      0x01,
      0x00,
      0x00,
      0x05,
      0x00,
      0x01,
      0x0D,
      0x0A,
      0x2D,
      0xB4,
      0x00,
      0x00,
      0x00,
      0x00,
      0x49,
      0x45,
      0x4E,
      0x44,
      0xAE,
      0x42,
      0x60,
      0x82,
    ]);

    testWidgets('shares file and caption on success', (tester) async {
      final tempDir = Directory.systemTemp;
      final dummyArt = File('${tempDir.path}/test_dummy_art.png');
      dummyArt.writeAsBytesSync(validPngBytes);

      List<XFile>? sharedFiles;
      String? sharedText;
      late BuildContext capturedContext;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                capturedContext = context;
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      await shareTidalEntity(
        context: capturedContext,
        type: TidalShareEntityType.album,
        id: 'test-album-1',
        title: 'Test Album',
        subtitle: 'Test Artist',
        coverUrl: dummyArt.path,
        shareXFiles: (files, {text}) async {
          sharedFiles = files;
          sharedText = text;
          return const ShareResult('success', ShareResultStatus.success);
        },
        cardCapturer: (ctx, card) async {
          return validPngBytes;
        },
      );

      expect(sharedFiles, isNotNull);
      expect(
        sharedFiles!.first.path,
        contains('flick_share_album_test-album-1.png'),
      );
      expect(
        sharedText,
        'Check out this album on Flick: "Test Album" by Test Artist https://tidal.com/album/test-album-1',
      );

      if (dummyArt.existsSync()) {
        dummyArt.deleteSync();
      }
    });

    testWidgets('shows snackbar on missing coverUrl', (tester) async {
      late BuildContext capturedContext;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                capturedContext = context;
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      await shareTidalEntity(
        context: capturedContext,
        type: TidalShareEntityType.album,
        id: 'test-album-2',
        title: 'Test Album',
        coverUrl: null,
      );
      await tester.pump();

      expect(find.text('Share failed: No cover art available'), findsOneWidget);
    });

    testWidgets('shows snackbar when cover file does not exist', (
      tester,
    ) async {
      late BuildContext capturedContext;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                capturedContext = context;
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      await shareTidalEntity(
        context: capturedContext,
        type: TidalShareEntityType.album,
        id: 'test-album-3',
        title: 'Test Album',
        coverUrl: '/tmp/non_existent_artwork_123456789.png',
      );
      await tester.pump();

      expect(
        find.text('Share failed: Cover art file could not be found'),
        findsOneWidget,
      );
    });
  });
}
