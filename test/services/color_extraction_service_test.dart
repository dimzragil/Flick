import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/color_extraction_service.dart';

/// Renders a solid square and encodes it as PNG, so the test owns its fixture
/// instead of depending on an asset or a checked-in binary.
Future<Uint8List> _solidPng(Color color, {int size = 8}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    Paint()..color = color,
  );
  final image = await recorder.endRecording().toImage(size, size);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final service = ColorExtractionService();

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('flick_color_extract_');
    service.clearCacheForTesting();
    service.onNativeResourcesForTesting = null;
  });

  tearDown(() async {
    service.onNativeResourcesForTesting = null;
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('disposes the decoded image and the codec before returning', () async {
    final file = File('${tempDir.path}/cover.png');
    await file.writeAsBytes(await _solidPng(const Color(0xFF3366CC)));

    ui.Image? decodedImage;
    ui.Codec? usedCodec;
    service.onNativeResourcesForTesting = (image, codec) {
      decodedImage = image;
      usedCodec = codec;
    };

    final color = await service.extractDominantColor(file.path);

    expect(color, isNotNull);
    // 0x33 = 51, averaged over a solid image.
    expect(color!.r, closeTo(51 / 255, 0.01));
    expect(color.g, closeTo(102 / 255, 0.01));
    expect(color.b, closeTo(204 / 255, 0.01));

    expect(decodedImage, isNotNull);
    expect(
      decodedImage!.debugDisposed,
      isTrue,
      reason: 'ui.Image must be released in a finally block',
    );

    // A disposed codec can no longer hand out frames, so this both documents
    // and verifies the codec.dispose() in the outer finally.
    expect(usedCodec, isNotNull);
    var codecStillUsable = true;
    try {
      await usedCodec!.getNextFrame();
    } catch (_) {
      codecStillUsable = false;
    }
    expect(
      codecStillUsable,
      isFalse,
      reason: 'ui.Codec must be released in a finally block',
    );
  });

  test('caches the extracted color and skips the decode on a hit', () async {
    final file = File('${tempDir.path}/cover.png');
    await file.writeAsBytes(await _solidPng(const Color(0xFF3366CC)));

    var decodes = 0;
    service.onNativeResourcesForTesting = (_, __) => decodes++;

    final first = await service.extractDominantColor(file.path);
    expect(first, isNotNull);
    expect(decodes, 1);

    // Deleting the source proves the second call never reaches the decoder.
    await file.delete();
    final second = await service.extractDominantColor(file.path);

    expect(second, first);
    expect(decodes, 1);
    expect(service.cacheSize, 1);
  });

  test('returns null for a missing file and caches nothing', () async {
    final missing = '${tempDir.path}/nope.png';

    expect(await service.extractDominantColor(missing), isNull);
    expect(service.cacheSize, 0);
  });
}
