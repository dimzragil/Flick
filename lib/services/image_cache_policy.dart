import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// App-wide policy for the two image caches that accumulate during browsing.
///
/// This app is unusually image-heavy (a cover on every row, card, and banner
/// of the TIDAL screens), so both caches are configured explicitly instead of
/// relying on library defaults:
///
/// * **Memory** — Flutter's `ImageCache` defaults to 1000 images / 100 MiB of
///   decoded bitmaps. The screens only request 160-320 px decodes (64 KiB -
///   400 KiB each), so a 64 MiB budget still holds several screens' worth of
///   artwork while keeping the process further away from Android's low-memory
///   trim callbacks. Every `onTrimMemory` at RUNNING_LOW or worse makes the
///   engine send a `memoryPressure` message, and `PaintingBinding` responds by
///   clearing the *entire* image cache — after which every visible cover has
///   to be re-decoded in one burst (visible as scrolling jank that comes back
///   after a background/foreground cycle).
/// * **Disk** — `DefaultCacheManager` (the manager `CachedNetworkImage` used
///   by default) keeps only 200 objects. The TIDAL screens request one small
///   CDN variant per row (160 px) plus cards (320 px), so a single hub visit
///   plus two detail screens produces more unique files than that; past the
///   limit every revisited cover is evicted and re-downloaded. The dedicated
///   [coverImageCacheManager] raises the bound to 1000 objects, which is only
///   a few tens of MiB for these small cover files.
///
/// Keep every network-artwork reader (widgets, ambient background, dominant
/// color extraction, share sheet) on [coverImageCacheManager] so they all hit
/// the same files instead of downloading duplicates.
class ImageCachePolicy {
  ImageCachePolicy._();

  /// Decoded-bitmap budget for `PaintingBinding.instance.imageCache`.
  static const int memoryBudgetBytes = 64 * 1024 * 1024;

  /// Entry-count cap for the in-memory image cache.
  static const int memoryBudgetEntries = 500;

  /// Object cap for the on-disk cover cache (default manager uses 200).
  static const int coverDiskCacheMaxObjects = 1000;

  /// How long an on-disk cover may go unused before it is evicted.
  static const Duration coverDiskCacheStalePeriod = Duration(days: 30);

  /// Applies [memoryBudgetBytes] / [memoryBudgetEntries] to the global image
  /// cache. Call once at startup, after `WidgetsFlutterBinding` is initialized.
  static void configureImageCache() {
    final cache = PaintingBinding.instance.imageCache;
    cache.maximumSizeBytes = memoryBudgetBytes;
    cache.maximumSize = memoryBudgetEntries;
  }
}

/// Disk cache for network artwork (TIDAL covers and other remote art).
///
/// Lazily created on first use so path_provider is ready by then.
final CacheManager coverImageCacheManager = CacheManager(
  Config(
    'flickCoverImages',
    stalePeriod: ImageCachePolicy.coverDiskCacheStalePeriod,
    maxNrOfCacheObjects: ImageCachePolicy.coverDiskCacheMaxObjects,
  ),
);
