// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/services/album_art_service.dart';
import 'package:flick/services/artwork_gate.dart';
import 'package:flick/services/sources/tidal_service.dart';
import 'package:flick/widgets/common/flick_artwork_placeholder.dart';

export 'package:flick/services/artwork_gate.dart';

/// A cached image widget that handles both file and network images with caching,
/// placeholders, and optional thumbnail support.
class CachedImageWidget extends StatefulWidget {
  /// Image path (file path or network URL)
  final String? imagePath;

  /// Audio source path used to lazily resolve embedded artwork on demand.
  final String? audioSourcePath;

  /// BoxFit for the image
  final BoxFit fit;

  /// Placeholder widget to show while loading or on error
  final Widget? placeholder;

  /// Error widget to show if image fails to load
  final Widget? errorWidget;

  /// Optional width constraint
  final double? width;

  /// Optional height constraint
  final double? height;

  /// Whether to use thumbnail (lower resolution) for better performance
  final bool useThumbnail;

  /// Target width for thumbnail (if useThumbnail is true)
  final int? thumbnailWidth;

  /// Target height for thumbnail (if useThumbnail is true)
  final int? thumbnailHeight;

  const CachedImageWidget({
    super.key,
    this.imagePath,
    this.audioSourcePath,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.errorWidget,
    this.width,
    this.height,
    this.useThumbnail = false,
    this.thumbnailWidth,
    this.thumbnailHeight,
  });

  /// Default placeholder widget
  static Widget defaultPlaceholder() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.surfaceLight, AppColors.surface],
        ),
      ),
      child: const Center(
        child: FlickArtworkPlaceholder(size: 42, opacity: 0.9),
      ),
    );
  }

  /// Default error widget
  static Widget defaultErrorWidget() {
    return defaultPlaceholder();
  }

  @override
  State<CachedImageWidget> createState() => _CachedImageWidgetState();
}

class _CachedImageWidgetState extends State<CachedImageWidget> {
  // ponytail: cache only confirmed-existing paths to keep fast-scroll stat()
  // O(1). Misses are NOT cached so async extraction can populate the path
  // later — caching false would permanently hide art whose file appears
  // after the first check.
  static final Set<String> _knownExistingPaths = {};
  static final Map<String, int> _knownMissingPaths = {};
  static const int _missingTtlMs = 15000;
  // Negative cache for network URLs that failed to load: without this, a
  // broken URL (bad UUID, 404, malformed) is retried on every rebuild/scroll,
  // flooding the network with doomed requests and janking the list.
  // Entries expire after TTL so transient failures can recover.
  static final Map<String, int> _knownBadUrls = {};
  static const int _badUrlTtlMs = 30000; // 30 seconds

  /// Records a network URL that failed to load so it isn't retried until TTL.
  static void _markBadUrl(String url) {
    _knownBadUrls[url] = DateTime.now().millisecondsSinceEpoch;
  }

  /// True if [url] failed recently and is still within the negative-cache TTL.
  static bool _isBadUrl(String url) {
    final badAt = _knownBadUrls[url];
    if (badAt == null) return false;
    if (DateTime.now().millisecondsSinceEpoch - badAt < _badUrlTtlMs) {
      return true;
    }
    _knownBadUrls.remove(url);
    return false;
  }

  // Bound for decoded resolution when the widget has no explicit size:
  // without this the full 1280px+ image was decoded for a small thumbnail.
  static const int _defaultMemCacheSize = 512;

  String? _resolvedImagePath;
  bool _hasPendingResolve = false;
  // ponytail: one recovery attempt per failed path — a decode failure means
  // the cache file is corrupt or was pruned/cleared mid-session, so drop it
  // from _knownExistingPaths and re-extract instead of failing forever.
  final Set<String> _recoveryAttempted = {};

  @override
  void initState() {
    super.initState();
    _resolvedImagePath = _usablePath(widget.imagePath);
    _resolveEmbeddedArtwork();
  }

  @override
  void didUpdateWidget(covariant CachedImageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imagePath != widget.imagePath ||
        oldWidget.audioSourcePath != widget.audioSourcePath) {
      _resolvedImagePath = _usablePath(widget.imagePath);
      _resolveEmbeddedArtwork();
    }
  }

  @override
  Widget build(BuildContext context) {
    var imagePath = _resolvedImagePath ?? _usablePath(widget.imagePath);
    // _resolvedImagePath may hold a URL that failed AFTER it was cached
    // (initState/didUpdateWidget run before the download fails). Re-check
    // the negative cache so a doomed URL isn't retried on every rebuild.
    if (imagePath != null && _isBadUrl(imagePath)) {
      imagePath = null;
      _resolvedImagePath = null;
    }
    if (imagePath == null) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: widget.errorWidget ?? CachedImageWidget.defaultErrorWidget(),
      );
    }

    // For file paths, use FileImage with caching
    if (!imagePath.startsWith('http')) {
      return _buildFileImage(imagePath);
    }

    // For network URLs, use cached network image
    return _buildNetworkImage(imagePath);
  }

  Future<void> _resolveEmbeddedArtwork() async {
    final directPath = _usablePath(widget.imagePath);
    if (directPath != null) {
      if (_resolvedImagePath != directPath && mounted) {
        setState(() {
          _resolvedImagePath = directPath;
        });
      }
      return;
    }

    final audioSourcePath = widget.audioSourcePath;
    if (audioSourcePath == null || audioSourcePath.isEmpty) {
      if (_resolvedImagePath != null && mounted) {
        setState(() {
          _resolvedImagePath = null;
        });
      }
      return;
    }

    if (artworkExtractionPaused) {
      _enqueueDeferredResolution(audioSourcePath);
      return;
    }

    final resolvedPath = await AlbumArtService.instance.resolveArtworkPath(
      existingPath: widget.imagePath,
      audioSourcePath: audioSourcePath,
    );

    if (!mounted || audioSourcePath != widget.audioSourcePath) {
      return;
    }

    final usablePath = _usablePath(resolvedPath);
    if (_resolvedImagePath != usablePath) {
      setState(() {
        _resolvedImagePath = usablePath;
      });
    }
  }

  void _enqueueDeferredResolution(String audioSourcePath) {
    if (_hasPendingResolve) return;
    _hasPendingResolve = true;
    enqueueArtworkResolver(() {
      _hasPendingResolve = false;
      if (!mounted || widget.audioSourcePath != audioSourcePath) {
        return;
      }
      _resolveEmbeddedArtwork();
    });
  }

  /// Decoded pixel bound: explicit thumbnail size wins, then 2x the widget
  /// size for retina, then a bounded default so a sizeless widget never
  /// decodes full resolution.
  int _memCacheFor(double? dimension, int? thumbnailDimension) {
    if (widget.useThumbnail && thumbnailDimension != null) {
      return thumbnailDimension;
    }
    if (dimension != null) return (dimension * 2).round();
    return _defaultMemCacheSize;
  }

  String? _usablePath(String? path) {
    if (path == null || path.isEmpty) {
      return null;
    }

    if (path.startsWith('http')) {
      // Reject malformed URLs outright: a garbage URL (e.g. a full URL fed
      // into the UUID-based cover builder) would otherwise trigger a doomed
      // network request on every build.
      final uri = Uri.tryParse(path);
      if (uri == null ||
          !(uri.scheme == 'http' || uri.scheme == 'https') ||
          !uri.hasAuthority) {
        return null;
      }
      // Skip recently-failed URLs (negative cache with TTL).
      if (_isBadUrl(path)) {
        return null;
      }
      return path;
    }

    if (path.startsWith('tidal-cover://')) {
      final uuid = path.substring('tidal-cover://'.length);
      final url = TidalService.coverUrl(uuid, size: 640);
      if (url.isNotEmpty) {
        return url;
      }
    }

    String cleanPath = path;
    if (cleanPath.startsWith('file://')) {
      try {
        final uri = Uri.tryParse(cleanPath);
        if (uri != null && uri.isScheme('file')) {
          cleanPath = uri.toFilePath();
        } else {
          cleanPath = cleanPath.substring(7);
        }
      } catch (_) {
        cleanPath = cleanPath.substring(7);
      }
    }

    if (cleanPath.isEmpty) {
      return null;
    }

    if (_knownExistingPaths.contains(cleanPath)) {
      return cleanPath;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final lastCheck = _knownMissingPaths[cleanPath];
    if (lastCheck != null && (now - lastCheck) < _missingTtlMs) {
      return null;
    }

    try {
      if (File(cleanPath).existsSync()) {
        _knownExistingPaths.add(cleanPath);
        _knownMissingPaths.remove(cleanPath);
        return cleanPath;
      }
    } catch (_) {}

    _knownMissingPaths[cleanPath] = now;
    return null;
  }

  Widget _buildFileImage(String imagePath) {
    String cleanPath = imagePath;
    if (cleanPath.startsWith('file://')) {
      try {
        final uri = Uri.tryParse(cleanPath);
        if (uri != null && uri.isScheme('file')) {
          cleanPath = uri.toFilePath();
        } else {
          cleanPath = cleanPath.substring(7);
        }
      } catch (_) {
        cleanPath = cleanPath.substring(7);
      }
    }
    final file = File(cleanPath);

    return Image.file(
      file,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded || frame != null) {
          return child;
        }
        return SizedBox(
          width: widget.width,
          height: widget.height,
          child: widget.placeholder ?? CachedImageWidget.defaultPlaceholder(),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        _recoverFailedFile(cleanPath);
        return SizedBox(
          width: widget.width,
          height: widget.height,
          child: widget.errorWidget ?? CachedImageWidget.defaultErrorWidget(),
        );
      },
      // Use lower resolution for thumbnails; bounded default when sizeless
      // so a small thumbnail never decodes the full-resolution file.
      cacheWidth: _memCacheFor(widget.width, widget.thumbnailWidth),
      cacheHeight: _memCacheFor(widget.height, widget.thumbnailHeight),
    );
  }

  void _recoverFailedFile(String failedPath) {
    if (failedPath.startsWith('http') ||
        _recoveryAttempted.contains(failedPath)) {
      return;
    }
    _recoveryAttempted.add(failedPath);
    _knownExistingPaths.remove(failedPath);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final file = File(failedPath);
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {}
      }
      if (_resolvedImagePath == failedPath) {
        setState(() {
          _resolvedImagePath = null;
        });
      }
      _resolveEmbeddedArtwork();
    });
  }

  Widget _buildNetworkImage(String imagePath) {
    // Disk-backed cache (via flutter_cache_manager): the file is stored on
    // disk after the first download, so scrolling back never re-downloads.
    // The old Image.network only used the 100MB in-memory cache, causing
    // constant re-fetch during scroll (late reloads + heat).
    final placeholder = SizedBox(
      width: widget.width,
      height: widget.height,
      child: widget.placeholder ?? CachedImageWidget.defaultPlaceholder(),
    );
    return CachedNetworkImage(
      imageUrl: imagePath,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      placeholder: (context, url) => placeholder,
      errorWidget: (context, url, error) {
        _markBadUrl(url);
        return SizedBox(
          width: widget.width,
          height: widget.height,
          child: widget.errorWidget ?? CachedImageWidget.defaultErrorWidget(),
        );
      },
      // Keep the previous instant swap (no fade) behavior.
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      memCacheWidth: _memCacheFor(widget.width, widget.thumbnailWidth),
      memCacheHeight: _memCacheFor(widget.height, widget.thumbnailHeight),
    );
  }
}

/// Helper class for preloading images
class ImagePreloader {
  static final DefaultCacheManager _cacheManager = DefaultCacheManager();

  static Future<void> preloadFile(
    String filePath,
    BuildContext context, {
    required bool Function() isMounted,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      return;
    }

    // Check if widget is still mounted before using context
    if (!isMounted()) {
      return;
    }

    try {
      // Decode the image to cache it in memory
      final imageProvider = FileImage(file);
      // Check again before precaching (context might be invalid)
      if (isMounted()) {
        await precacheImage(imageProvider, context);
      }
    } catch (e) {
      // Ignore errors during preloading (context might be invalid)
    }
  }

  static Future<void> preloadNetwork(
    String url,
    BuildContext context, {
    required bool Function() isMounted,
  }) async {
    try {
      // First cache the file
      await _cacheManager.getSingleFile(url);

      // Check if widget is still mounted before using context
      if (!isMounted()) {
        return;
      }

      // Then decode it into memory
      final imageProvider = NetworkImage(url);
      // Check again before precaching (context might be invalid)
      if (isMounted()) {
        await precacheImage(imageProvider, context);
      }
    } catch (e) {
      // Ignore errors during preloading (context might be invalid)
    }
  }

  /// Preload multiple images
  ///
  /// [isMounted] callback should return true if the widget is still mounted.
  /// This prevents using BuildContext across async gaps.
  ///
  /// Usage:
  /// ```dart
  /// ImagePreloader.preloadImages(['path1.jpg', 'path2.jpg'], context, isMounted: () => mounted);
  /// ```
  static Future<void> preloadImages(
    List<String> imagePaths,
    BuildContext context, {
    required bool Function() isMounted,
  }) async {
    final futures = imagePaths.map((path) {
      if (path.startsWith('http')) {
        return preloadNetwork(path, context, isMounted: isMounted);
      } else {
        return preloadFile(path, context, isMounted: isMounted);
      }
    });
    await Future.wait(futures);
  }
}
