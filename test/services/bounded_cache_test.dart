import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/color_extraction_service.dart';
import 'package:flick/services/player_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ColorExtractionService FIFO Cache', () {
    final service = ColorExtractionService();

    setUp(() {
      service.clearCacheForTesting();
    });

    test('bounds cache to max entries and evicts oldest (FIFO)', () {
      const max = ColorExtractionService.maxCacheEntries;
      expect(max, 64);

      // Fill cache to max
      for (var i = 0; i < max; i++) {
        service.cacheColorForTesting('path_$i', Color(0xFF000000 + i));
      }
      expect(service.cacheSize, max);

      // Inserting 65th item should evict path_0
      service.cacheColorForTesting('path_$max', const Color(0xFFFFFFFF));
      expect(service.cacheSize, max);

      // Verify that after 70 total items, cache size remains capped at 64
      service.clearCacheForTesting();
      for (var i = 0; i < 70; i++) {
        service.cacheColorForTesting('item_$i', Color(0xFF000000 + i));
      }
      expect(service.cacheSize, 64);
    });
  });

  group('PlayerService FIFO Bounded Caching Helpers', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('player_cache_test');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('updateFifoBoundedMap bounds entries and triggers onEvicted', () async {
      const max = PlayerService.playbackPathCacheMaxEntries;
      expect(max, 64);

      final map = <String, String>{};
      final files = <File>[];

      for (var i = 0; i < 70; i++) {
        final f = File('${tempDir.path}/staged_$i.tmp');
        await f.writeAsString('data_$i');
        files.add(f);

        updateFifoBoundedMap(
          map: map,
          key: 'uri_$i',
          value: f.path,
          maxEntries: max,
          onEvicted: (_, evictedPath) {
            unawaited(File(evictedPath).delete());
          },
        );
      }

      expect(map.length, max);

      // Wait a moment for unawaited file deletion to settle
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // The first 6 files (0..5) should have been evicted and their files deleted
      for (var i = 0; i < 6; i++) {
        expect(
          await files[i].exists(),
          isFalse,
          reason: 'File $i should have been deleted on eviction',
        );
      }

      // The remaining 64 files (6..69) should still exist
      for (var i = 6; i < 70; i++) {
        expect(
          await files[i].exists(),
          isTrue,
          reason: 'File $i should still exist',
        );
      }
    });

    test('updateFifoBoundedMap preserves capacity when updating existing key', () {
      final map = <String, String>{};
      for (var i = 0; i < 5; i++) {
        updateFifoBoundedMap(
          map: map,
          key: 'k$i',
          value: 'v$i',
          maxEntries: 5,
        );
      }
      expect(map.length, 5);

      // Updating existing key should NOT evict anything
      var evicted = false;
      updateFifoBoundedMap(
        map: map,
        key: 'k2',
        value: 'v2_updated',
        maxEntries: 5,
        onEvicted: (_, __) => evicted = true,
      );

      expect(map.length, 5);
      expect(evicted, isFalse);
      expect(map['k2'], 'v2_updated');
    });

    test('updateFifoBoundedSet bounds entries to maxEntries with FIFO eviction', () {
      const max = PlayerService.playbackPathCacheMaxEntries;
      final set = <String>{};

      for (var i = 0; i < 70; i++) {
        updateFifoBoundedSet(
          set: set,
          item: 'unsupported_$i',
          maxEntries: max,
        );
      }

      expect(set.length, max);
      // Items 0..5 should have been evicted
      for (var i = 0; i < 6; i++) {
        expect(set.contains('unsupported_$i'), isFalse);
      }
      // Items 6..69 should still be present
      for (var i = 6; i < 70; i++) {
        expect(set.contains('unsupported_$i'), isTrue);
      }
    });
  });
}
