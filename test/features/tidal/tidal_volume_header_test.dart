import 'dart:convert';

import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/features/tidal/providers/tidal_providers.dart';
import 'package:flick/features/tidal/screens/tidal_album_screen.dart';
import 'package:flick/features/tidal/widgets/tidal_volume_header.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flick/services/sources/tidal_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _MockTidalServerNotifier extends TidalServerNotifier {
  final NetworkServerEntity? _server;
  _MockTidalServerNotifier(this._server);

  @override
  Future<NetworkServerEntity?> build() async => _server;
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

/// A track with the given disc/volume and track number.
Song _song(String id, {int? discNumber, int? trackNumber, String? title}) =>
    Song(
      id: id,
      title: title ?? 'Track $id',
      artist: 'Test Artist',
      duration: const Duration(seconds: 200),
      fileType: 'flac',
      trackNumber: trackNumber,
      discNumber: discNumber,
    );

/// Six tracks: three on volume 1, three on volume 2.
List<Song> _multiDiscTracks() => [
  _song('t1', discNumber: 1, trackNumber: 1),
  _song('t2', discNumber: 1, trackNumber: 2),
  _song('t3', discNumber: 1, trackNumber: 3),
  _song('t4', discNumber: 2, trackNumber: 1),
  _song('t5', discNumber: 2, trackNumber: 2),
  _song('t6', discNumber: 2, trackNumber: 3),
];

void main() {
  group('buildTidalAlbumListItems', () {
    test('single-disc album renders no headers and keeps the API order', () {
      final tracks = [
        _song('t1', discNumber: 1, trackNumber: 1),
        _song('t2', discNumber: 1, trackNumber: 2),
        _song('t3', discNumber: 1, trackNumber: 3),
      ];

      final items = buildTidalAlbumListItems(tracks);

      expect(items, hasLength(3));
      expect(items.every((item) => item is TidalAlbumTrackItem), isTrue);
      expect(
        items.cast<TidalAlbumTrackItem>().map((item) => item.song.id).toList(),
        ['t1', 't2', 't3'],
      );
      expect(
        items.cast<TidalAlbumTrackItem>().map((item) => item.globalIndex),
        [0, 1, 2],
      );
    });

    test('tracks with a null discNumber produce no headers', () {
      final tracks = [
        _song('t1', trackNumber: 1),
        _song('t2', trackNumber: 2),
        _song('t3', trackNumber: 3),
      ];

      final items = buildTidalAlbumListItems(tracks);

      expect(items, hasLength(3));
      expect(items.whereType<TidalVolumeHeaderItem>(), isEmpty);
      expect(items.every((item) => item is TidalAlbumTrackItem), isTrue);
    });

    test('a null discNumber mixed with a real one groups under volume 1', () {
      final tracks = [
        _song('t1', discNumber: 1),
        _song('t2'),
        _song('t3', discNumber: 2),
      ];

      final items = buildTidalAlbumListItems(tracks);

      final headers = items.whereType<TidalVolumeHeaderItem>().toList();
      expect(headers.map((h) => h.volume), [1, 2]);
      expect(headers.first.trackCount, 2);
      expect(headers.last.trackCount, 1);
    });

    test('multi-disc album inserts a header before each volume', () {
      final items = buildTidalAlbumListItems(_multiDiscTracks());

      final headers = items.whereType<TidalVolumeHeaderItem>().toList();
      expect(headers, hasLength(2));
      expect(headers.map((h) => h.volume), [1, 2]);
      expect(headers.map((h) => h.trackCount), [3, 3]);

      // Layout: header, 3 tracks, header, 3 tracks.
      expect(items[0], isA<TidalVolumeHeaderItem>());
      expect((items[0] as TidalVolumeHeaderItem).volume, 1);
      for (var i = 1; i <= 3; i++) {
        expect(items[i], isA<TidalAlbumTrackItem>());
      }
      expect(items[4], isA<TidalVolumeHeaderItem>());
      expect((items[4] as TidalVolumeHeaderItem).volume, 2);
      for (var i = 5; i <= 7; i++) {
        expect(items[i], isA<TidalAlbumTrackItem>());
      }
    });

    test('volume-2 tracks keep their index in the full album list', () {
      final items = buildTidalAlbumListItems(_multiDiscTracks());

      final tracks = items.whereType<TidalAlbumTrackItem>().toList();
      // The first track of volume 2 is the 4th track of the album.
      expect(tracks[3].song.id, 't4');
      expect(tracks[3].globalIndex, 3);
      expect(tracks[5].globalIndex, 5);
      // Global indices are unique and cover the whole list.
      expect(tracks.map((t) => t.globalIndex).toList(), [0, 1, 2, 3, 4, 5]);
    });

    test('a non-positive discNumber is treated as volume 1', () {
      final tracks = [
        _song('t1', discNumber: 0),
        _song('t2', discNumber: -3),
        _song('t3', discNumber: 2),
      ];

      final items = buildTidalAlbumListItems(tracks);

      final headers = items.whereType<TidalVolumeHeaderItem>().toList();
      expect(headers.map((h) => h.volume), [1, 2]);
      expect(headers.first.trackCount, 2);
    });

    test('an empty album produces no items', () {
      expect(buildTidalAlbumListItems(const []), isEmpty);
    });
  });

  group('TidalAlbumScreen volume headers', () {
    Future<void> pumpAlbum(
      WidgetTester tester, {
      required String albumId,
      required List<Song> tracks,
      void Function(Song song, List<Song> playlist)? onPlayTrack,
    }) async {
      tester.view.physicalSize = const Size(800, 2400);
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
            tidalAlbumLovedProvider(albumId).overrideWith((ref) => false),
            tidalAlbumDetailsProvider(albumId).overrideWith(
              (ref) async => (
                album: {
                  'id': albumId,
                  'title': 'Multi Disc Album',
                  'artist': {'name': 'Test Artist'},
                },
                tracks: tracks,
              ),
            ),
          ],
          child: MaterialApp(
            home: TidalAlbumScreen(albumId: albumId, onPlayTrack: onPlayTrack),
          ),
        ),
      );

      await tester.pumpAndSettle();
    }

    testWidgets('multi-disc album shows a header per volume', (tester) async {
      await pumpAlbum(tester, albumId: 'alb-multi', tracks: _multiDiscTracks());

      expect(find.text('Volume 1'), findsOneWidget);
      expect(find.text('Volume 2'), findsOneWidget);
      expect(find.text('3 tracks'), findsNWidgets(2));
      // Every track is still rendered.
      for (final track in _multiDiscTracks()) {
        expect(find.text(track.title), findsOneWidget);
      }
      // The header label lines up with the track titles below it.
      expect(
        tester.getTopLeft(find.text('Volume 1')).dx,
        tester.getTopLeft(find.text('Track t1')).dx,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('single-disc album shows no headers', (tester) async {
      await pumpAlbum(
        tester,
        albumId: 'alb-single',
        tracks: [
          _song('t1', discNumber: 1, trackNumber: 1),
          _song('t2', discNumber: 1, trackNumber: 2),
        ],
      );

      expect(find.text('Volume 1'), findsNothing);
      expect(find.text('Volume 2'), findsNothing);
      expect(find.text('Track t1'), findsOneWidget);
      expect(find.text('Track t2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('album with null disc numbers shows no headers', (
      tester,
    ) async {
      await pumpAlbum(
        tester,
        albumId: 'alb-null-disc',
        tracks: [_song('t1'), _song('t2'), _song('t3')],
      );

      expect(find.text('Volume 1'), findsNothing);
      expect(find.text('Track t1'), findsOneWidget);
      expect(find.text('Track t3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a volume-2 track plays it at its global album index', (
      tester,
    ) async {
      Song? played;
      List<Song>? playlist;

      await pumpAlbum(
        tester,
        albumId: 'alb-multi',
        tracks: _multiDiscTracks(),
        onPlayTrack: (song, list) {
          played = song;
          playlist = list;
        },
      );

      await tester.tap(find.text('Track t4'));
      await tester.pumpAndSettle();

      expect(played, isNotNull);
      expect(played!.id, 't4');
      // The whole album is handed over — headers don't shift the order.
      expect(playlist!.map((s) => s.id).toList(), [
        't1',
        't2',
        't3',
        't4',
        't5',
        't6',
      ]);
      // The track resolves to its real position in the album, not to its
      // position below the "Volume 2" header.
      expect(playlist!.indexWhere((s) => s.id == played!.id), 3);
      expect(tester.takeException(), isNull);
    });
  });
}
