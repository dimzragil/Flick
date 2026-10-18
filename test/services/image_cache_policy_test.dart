import 'dart:io';

import 'package:flick/services/image_cache_policy.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The disk cache managers resolve their storage directory through
  // path_provider, which has no platform implementation under `flutter test`.
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          switch (call.method) {
            case 'getTemporaryDirectory':
            case 'getApplicationSupportDirectory':
              return Directory.systemTemp.createTempSync('flick_policy_').path;
          }
          return null;
        });
  });
  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
  });

  group('ImageCachePolicy', () {
    test('configureImageCache applies the decoded-bitmap budget', () {
      ImageCachePolicy.configureImageCache();

      final cache = PaintingBinding.instance.imageCache;
      expect(cache.maximumSizeBytes, ImageCachePolicy.memoryBudgetBytes);
      expect(cache.maximumSize, ImageCachePolicy.memoryBudgetEntries);
    });

    test('cover disk manager uses a dedicated cache key and bounds', () {
      final config = coverImageCacheManager.config;
      expect(config.cacheKey, 'flickCoverImages');
      expect(
        config.maxNrOfCacheObjects,
        ImageCachePolicy.coverDiskCacheMaxObjects,
      );
      expect(config.stalePeriod, ImageCachePolicy.coverDiskCacheStalePeriod);
    });

    test('cover disk manager holds more objects than the library default', () {
      // The default manager (200 objects) is what caused cover eviction churn;
      // keep the dedicated manager above it.
      expect(
        coverImageCacheManager.config.maxNrOfCacheObjects,
        greaterThan(DefaultCacheManager().config.maxNrOfCacheObjects),
      );
    });
  });
}
