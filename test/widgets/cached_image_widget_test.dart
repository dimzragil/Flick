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
          body: CachedImageWidget(
            imagePath: fileUri,
            width: 50,
            height: 50,
          ),
        ),
      ),
    );

    expect(find.byType(CachedImageWidget), findsOneWidget);
  });

  testWidgets('CachedImageWidget falls back to errorWidget for non-existent file',
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
  });
}
