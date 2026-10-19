import 'dart:ffi';
import 'dart:io';

import 'package:flick/data/database.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:path/path.dart' as p;

String? _isarCorePath() {
  final override = Platform.environment['ISAR_CORE_LIB'];
  if (override != null && File(override).existsSync()) return override;

  final abi = Abi.current();
  final fileName = switch (abi) {
    Abi.linuxX64 || Abi.linuxArm || Abi.linuxArm64 => 'libisar.so',
    Abi.macosX64 || Abi.macosArm64 => 'libisar.dylib',
    Abi.windowsX64 => 'isar.dll',
    _ => null,
  };
  if (fileName == null) return null;
  final platformDir = Platform.operatingSystem;

  final pubCache =
      Platform.environment['PUB_CACHE'] ??
      p.join(Platform.environment['HOME'] ?? '', '.pub-cache');
  final hosted = Directory(p.join(pubCache, 'hosted', 'pub.dev'));
  if (!hosted.existsSync()) return null;

  final candidates =
      hosted
          .listSync()
          .whereType<Directory>()
          .map((d) => p.basename(d.path))
          .where((name) => name.startsWith('isar_community_flutter_libs-'))
          .toList()
        ..sort();
  for (final name in candidates.reversed) {
    final path = p.join(hosted.path, name, platformDir, fileName);
    if (File(path).existsSync()) return path;
  }
  return null;
}

SongEntity _song({
  required int id,
  String? folderUri,
  int? remoteServerId,
  int? startOffsetMs,
  String? filePath,
}) {
  return SongEntity()
    ..id = id
    ..filePath = filePath ?? '/music/track_$id.flac'
    ..title = 'Track $id'
    ..artist = 'Artist'
    ..folderUri = folderUri
    ..remoteServerId = remoteServerId
    ..startOffsetMs = startOffsetMs
    ..dateAdded = DateTime.now();
}

SongAudioCacheEntity _cache(int songId) {
  return SongAudioCacheEntity()
    ..songId = songId
    ..peaks = const [0.25, 0.5, 0.75]
    ..computedAt = 1234;
}

void main() {
  final corePath = _isarCorePath();
  late Directory tempDir;
  late Isar isar;
  late SongRepository repo;

  setUpAll(() async {
    if (corePath == null) return;
    Isar.initializeIsarCore(libraries: {Abi.current(): corePath});
    tempDir = await Directory.systemTemp.createTemp('flick_audio_cache');
    isar = await Isar.open(
      [SongEntitySchema, SongAudioCacheEntitySchema],
      directory: tempDir.path,
      name: 'audio_cache_cleanup_test',
    );
    repo = SongRepository(isar: isar);
  });

  setUp(() async {
    if (corePath == null) return;
    await isar.writeTxn(() => isar.clear());
  });

  tearDownAll(() async {
    if (corePath == null) return;
    await isar.close();
    await tempDir.delete(recursive: true);
  });

  Future<void> seed(
    List<SongEntity> songs,
    List<SongAudioCacheEntity> caches,
  ) async {
    await isar.writeTxn(() async {
      await isar.songEntitys.putAll(songs);
      await isar.songAudioCacheEntitys.putAll(caches);
    });
  }

  group(
    'SongRepository audio cache cleanup',
    skip: corePath == null ? 'Isar core library not found' : false,
    () {
      test('deleting a song removes its cache row only', () async {
        await seed([_song(id: 1), _song(id: 2)], [_cache(1), _cache(2)]);

        await repo.deleteSong(1);

        expect(await isar.songEntitys.get(1), isNull);
        expect(await isar.songAudioCacheEntitys.get(1), isNull);
        expect(await isar.songEntitys.get(2), isNotNull);
        expect(await isar.songAudioCacheEntitys.get(2), isNotNull);
      });

      test('deleting a folder removes all child cache rows', () async {
        await seed(
          [
            _song(id: 1, folderUri: 'folder-a'),
            _song(id: 2, folderUri: 'folder-a'),
            _song(id: 3, folderUri: 'folder-b'),
          ],
          [_cache(1), _cache(2), _cache(3)],
        );

        await repo.deleteSongsForFolder('folder-a');

        expect(await isar.songEntitys.count(), 1);
        expect(await isar.songAudioCacheEntitys.count(), 1);
        expect(await isar.songAudioCacheEntitys.get(1), isNull);
        expect(await isar.songAudioCacheEntitys.get(2), isNull);
        expect(await isar.songAudioCacheEntitys.get(3), isNotNull);
      });

      test('clearing the library removes every cache row', () async {
        final songs = <SongEntity>[];
        final caches = <SongAudioCacheEntity>[];
        for (var id = 1; id <= 500; id++) {
          songs.add(_song(id: id));
          caches.add(_cache(id));
        }
        await seed(songs, caches);

        await repo.deleteAllSongs();

        expect(await isar.songEntitys.count(), 0);
        expect(await isar.songAudioCacheEntitys.count(), 0);
      });

      test('deleting songs by id removes their cache rows', () async {
        await seed(
          [_song(id: 1), _song(id: 2), _song(id: 3)],
          [_cache(1), _cache(2), _cache(3)],
        );

        await repo.deleteSongsByIds([1, 3]);

        expect(await isar.songEntitys.count(), 1);
        expect(await isar.songAudioCacheEntitys.count(), 1);
        expect(await isar.songAudioCacheEntitys.get(2), isNotNull);
      });

      test('deleting paths removes cache rows for all CUE tracks', () async {
        await seed(
          [
            _song(id: 1, filePath: '/music/album.flac'),
            _song(id: 2, filePath: '/music/album.flac', startOffsetMs: 0),
            _song(id: 3, filePath: '/music/album.flac', startOffsetMs: 60000),
          ],
          [_cache(1), _cache(2), _cache(3)],
        );

        await repo.deleteSongsByPath(['/music/album.flac']);

        expect(await isar.songEntitys.count(), 0);
        expect(await isar.songAudioCacheEntitys.count(), 0);
      });

      test('raw path deletion keeps CUE track cache rows', () async {
        await seed(
          [
            _song(id: 1, filePath: '/music/raw.flac'),
            _song(id: 2, filePath: '/music/cue.flac', startOffsetMs: 0),
            _song(id: 3, filePath: '/music/cue.flac', startOffsetMs: 60000),
          ],
          [_cache(1), _cache(2), _cache(3)],
        );

        await repo.deleteRawSongsByPath(['/music/raw.flac']);

        expect(await isar.songEntitys.count(), 2);
        expect(await isar.songAudioCacheEntitys.count(), 2);
        expect(await isar.songAudioCacheEntitys.get(1), isNull);
        expect(await isar.songAudioCacheEntitys.get(2), isNotNull);
        expect(await isar.songAudioCacheEntitys.get(3), isNotNull);
      });

      test('CUE path deletion keeps raw song cache rows', () async {
        await seed(
          [
            _song(id: 1, filePath: '/music/raw.flac'),
            _song(id: 2, filePath: '/music/cue.flac', startOffsetMs: 0),
            _song(id: 3, filePath: '/music/cue.flac', startOffsetMs: 60000),
          ],
          [_cache(1), _cache(2), _cache(3)],
        );

        await repo.deleteCueTracksByPath(['/music/cue.flac']);

        expect(await isar.songEntitys.count(), 1);
        expect(await isar.songAudioCacheEntitys.count(), 1);
        expect(await isar.songAudioCacheEntitys.get(1), isNotNull);
      });

      test('server removal removes cache rows for its songs only', () async {
        await seed(
          [
            _song(id: 1, remoteServerId: 7),
            _song(id: 2, remoteServerId: 7),
            _song(id: 3, remoteServerId: 8),
          ],
          [_cache(1), _cache(2), _cache(3)],
        );

        await repo.deleteSongsForRemoteServer(7);

        expect(await isar.songEntitys.count(), 1);
        expect(await isar.songAudioCacheEntitys.count(), 1);
        expect(await isar.songAudioCacheEntitys.get(3), isNotNull);
      });

      test('orphan cleanup removes only cache rows without a song', () async {
        await seed([_song(id: 2)], [_cache(1), _cache(2), _cache(99)]);

        final removed = await repo.deleteOrphanedAudioCache();

        expect(removed, 2);
        expect(await isar.songAudioCacheEntitys.count(), 1);
        expect(await isar.songAudioCacheEntitys.get(1), isNull);
        expect(await isar.songAudioCacheEntitys.get(2), isNotNull);
        expect(await isar.songAudioCacheEntitys.get(99), isNull);

        // Idempotent: a second pass finds nothing to clean.
        expect(await repo.deleteOrphanedAudioCache(), 0);
      });

      test('cache lookup still works after orphan cleanup', () async {
        await seed([_song(id: 1)], [_cache(1)]);

        expect(await repo.deleteOrphanedAudioCache(), 0);

        final cache = await repo.getAudioCache(1);
        expect(cache, isNotNull);
        expect(cache!.peaks, [0.25, 0.5, 0.75]);
      });
    },
  );
}
