import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flick/core/utils/dev_log.dart';

/// Service to extract dominant colors from images for adaptive theming.
///
/// Uses palette extraction to determine the primary colors from album art,
/// enabling background-aware color adjustments throughout the app.
class ColorExtractionService {
  ColorExtractionService._();
  static final ColorExtractionService _instance = ColorExtractionService._();
  factory ColorExtractionService() => _instance;

  // Cache extracted colors to avoid recomputation
  static const int _colorCacheMaxEntries = 64;
  final Map<String, Color> _colorCache = {};

  @visibleForTesting
  static const int maxCacheEntries = _colorCacheMaxEntries;

  @visibleForTesting
  int get cacheSize => _colorCache.length;

  @visibleForTesting
  void clearCacheForTesting() => _colorCache.clear();

  @visibleForTesting
  void cacheColorForTesting(String imagePath, Color color) {
    _cacheColor(imagePath, color);
  }

  void _cacheColor(String imagePath, Color color) {
    if (_colorCache.length >= _colorCacheMaxEntries) {
      _colorCache.remove(_colorCache.keys.first);
    }
    _colorCache[imagePath] = color;
  }

  /// Extracts the dominant/average color from an image file or remote URL.
  ///
  /// Remote (http/https) images are resolved through the shared disk cache
  /// ([DefaultCacheManager]): a cache hit is used directly, otherwise the
  /// image is downloaded once. This lets network-sourced artwork (e.g.
  /// TIDAL covers) participate in adaptive theming just like local files.
  ///
  /// Returns null if extraction fails, the file doesn't exist, or the
  /// remote image can't be fetched.
  Future<Color?> extractDominantColor(String? imagePath) async {
    if (imagePath == null || imagePath.isEmpty) {
      return null;
    }

    // Check cache first
    if (_colorCache.containsKey(imagePath)) {
      return _colorCache[imagePath];
    }

    try {
      final localPath = await _resolveLocalPath(imagePath);
      if (localPath == null) {
        return null;
      }

      final file = File(localPath);
      if (!await file.exists()) {
        return null;
      }

      final Uint8List bytes = await file.readAsBytes();
      final ui.Codec codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 32, // Sample at low resolution for speed
        targetHeight: 32,
      );
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      final ui.Image image = frameInfo.image;

      // Get pixel data
      final ByteData? byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );

      if (byteData == null) {
        return null;
      }

      final color = _calculateAverageColor(byteData, image.width, image.height);

      // Cache the result
      _cacheColor(imagePath, color);

      return color;
    } catch (e) {
      devLog('ColorExtractionService: Failed to extract color: $e');
      return null;
    }
  }

  /// Resolves [imagePath] to a local file path.
  ///
  /// Plain file paths are returned as-is. Remote URLs go through
  /// [DefaultCacheManager]: the disk-cached file is preferred so no network
  /// fetch happens when the image was already loaded elsewhere in the app
  /// (e.g. by [CachedImageWidget]); otherwise it is downloaded once.
  /// Returns null when the path can't be resolved to a readable file.
  Future<String?> _resolveLocalPath(String imagePath) async {
    if (!imagePath.startsWith('http://') &&
        !imagePath.startsWith('https://')) {
      return imagePath;
    }
    try {
      final cacheManager = DefaultCacheManager();
      final cached = await cacheManager.getFileFromCache(imagePath);
      if (cached != null && await cached.file.exists()) {
        return cached.file.path;
      }
      final downloaded = await cacheManager.getSingleFile(imagePath);
      if (await downloaded.exists()) {
        return downloaded.path;
      }
    } catch (e) {
      devLog('ColorExtractionService: Failed to fetch remote image: $e');
    }
    return null;
  }

  /// Calculates the average color from pixel data, with brightness adjustment.
  Color _calculateAverageColor(ByteData byteData, int width, int height) {
    int totalR = 0, totalG = 0, totalB = 0;
    int pixelCount = width * height;

    for (int i = 0; i < byteData.lengthInBytes; i += 4) {
      final r = byteData.getUint8(i);
      final g = byteData.getUint8(i + 1);
      final b = byteData.getUint8(i + 2);
      // Skip alpha (i + 3)

      totalR += r;
      totalG += g;
      totalB += b;
    }

    final avgR = totalR ~/ pixelCount;
    final avgG = totalG ~/ pixelCount;
    final avgB = totalB ~/ pixelCount;

    return Color.fromARGB(255, avgR, avgG, avgB);
  }

  /// Extracts the dominant color and returns it blended with the app's
  /// base background color for a more cohesive look.
  Future<Color> extractBlendedBackgroundColor(
    String? imagePath, {
    Color baseColor = const Color(0xFF0A0A0A),
    double blendFactor = 0.4,
  }) async {
    final dominantColor = await extractDominantColor(imagePath);

    if (dominantColor == null) {
      return baseColor;
    }

    // Blend the dominant color with the base color
    return Color.lerp(baseColor, dominantColor, blendFactor)!;
  }

  /// Clears the color cache. Useful when album art changes.
  void clearCache() {
    _colorCache.clear();
  }

  /// Removes a specific entry from the cache.
  void invalidateCache(String imagePath) {
    _colorCache.remove(imagePath);
  }
}
