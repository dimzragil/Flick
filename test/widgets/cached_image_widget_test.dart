import 'dart:io';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File sampleFile;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('flick_img_test_');
    sampleFile = File('${tempDir.path}/test_cover.jpg');
    // Minimal 1x1 JPEG or dummy bytes
    sampleFile.writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]);
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('CachedImageWidget handles raw file path', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CachedImageWidget(
            imagePath: sampleFile.path,
            width: 50,
            height: 50,
          ),
        ),
      ),
    );

    expect(find.byType(CachedImageWidget), findsOneWidget);
  });

  testWidgets('CachedImageWidget handles file:// URI scheme', (tester) async {
    final fileUri = sampleFile.uri.toString();
    expect(fileUri.startsWith('file://'), isTrue);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CachedImageWidget(imagePath: fileUri, width: 50, height: 50),
        ),
      ),
    );

    expect(find.byType(CachedImageWidget), findsOneWidget);
  });

  testWidgets(
    'CachedImageWidget falls back to errorWidget for non-existent file',
    (tester) async {
      const errorKey = Key('error_fallback');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedImageWidget(
              imagePath: 'file:///non/existent/path/image.jpg',
              width: 50,
              height: 50,
              errorWidget: const SizedBox(key: errorKey),
            ),
          ),
        ),
      );

      expect(find.byKey(errorKey), findsOneWidget);
    },
  );

  group('lookup caches are bounded', () {
    setUp(() => CachedImageWidget.clearPathCachesForTesting());
    tearDown(() => CachedImageWidget.clearPathCachesForTesting());

    test('existing-path cache stays within its cap', () {
      final overflow = CachedImageWidget.pathCacheMaxEntries + 8;
      for (var i = 0; i < overflow; i++) {
        final file = File('${tempDir.path}/cover_$i.jpg')
          ..writeAsBytesSync(const [0]);
        expect(
          CachedImageWidget.resolveUsablePathForTesting(file.path),
          file.path,
        );
      }

      expect(
        CachedImageWidget.knownExistingPathsCount,
        CachedImageWidget.pathCacheMaxEntries,
      );
      // An evicted path still resolves: it is simply re-checked on disk.
      expect(
        CachedImageWidget.resolveUsablePathForTesting(
          File('${tempDir.path}/cover_0.jpg').path,
        ),
        isNotNull,
      );
    });

    test('negative path cache stays within its cap', () {
      final overflow = CachedImageWidget.negativeCacheMaxEntries + 64;
      for (var i = 0; i < overflow; i++) {
        expect(
          CachedImageWidget.resolveUsablePathForTesting(
            '${tempDir.path}/missing_$i.jpg',
          ),
          isNull,
        );
      }

      expect(
        CachedImageWidget.knownMissingPathsCount,
        CachedImageWidget.negativeCacheMaxEntries,
      );
    });

    test('bad-url cache evicts oldest entries first', () {
      final first = 'https://cdn.example.com/first.jpg';
      CachedImageWidget.markBadUrlForTesting(first);
      expect(CachedImageWidget.resolveUsablePathForTesting(first), isNull);

      final overflow = CachedImageWidget.negativeCacheMaxEntries + 1;
      for (var i = 0; i < overflow; i++) {
        CachedImageWidget.markBadUrlForTesting(
          'https://cdn.example.com/bad_$i.jpg',
        );
      }

      expect(
        CachedImageWidget.knownBadUrlsCount,
        CachedImageWidget.negativeCacheMaxEntries,
      );
      // The oldest entry was evicted, so the URL is no longer suppressed.
      expect(CachedImageWidget.resolveUsablePathForTesting(first), first);
    });
  });
}
