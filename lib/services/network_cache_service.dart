import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'playback_cache_preferences_service.dart';

/// Bounded LRU download cache for network-sourced songs.
///
/// Layout: `<appCache>/network_cache/<serverId>/<md5(serverId:remoteId)>.<ext>`.
/// LRU by file mtime; eviction runs after each [stash] once the total exceeds
/// the effective cap. When [sizeCapBytes] is null (the default) the effective
/// cap is the user's live "Playback Cache Limit" preference
/// ([PlaybackCachePreferencesService]); an explicit value overrides it.
/// A cap <= 0 (see [kPlaybackCacheUnlimited]) disables eviction.
class NetworkCacheService {
  NetworkCacheService({this.sizeCapBytes, Directory? rootDirectory})
    : _rootDirectory = rootDirectory;

  /// Fallback cap: 2 GiB. Only used when the user preference is unreadable.
  static const defaultSizeCapBytes = 2 * 1024 * 1024 * 1024;

  static const _dirName = 'network_cache';

  /// Explicit byte cap, or null to follow the user's Playback Cache Limit.
  final int? sizeCapBytes;

  /// Test seam; when null, resolves the platform app cache directory.
  final Directory? _rootDirectory;

  Future<Directory> _root() async {
    if (_rootDirectory != null) return _rootDirectory;
    final cacheDir = await getApplicationCacheDirectory();
    final root = Directory(p.join(cacheDir.path, _dirName));
    await root.create(recursive: true);
    return root;
  }

  static String _hash(int remoteServerId, String remoteId) =>
      md5.convert(utf8.encode('$remoteServerId:$remoteId')).toString();

  /// Path of the cached file for (server, song), or null if not cached.
  /// Touches the file's mtime to keep it warm in the LRU order.
  Future<String?> getPath(
    int remoteServerId,
    String remoteId, {
    String? extension,
  }) async {
    final serverDir = Directory(
      p.join((await _root()).path, '$remoteServerId'),
    );
    if (!await serverDir.exists()) return null;

    final hash = _hash(remoteServerId, remoteId);
    final fileName = extension != null
        ? '$hash.$extension'
        : await _findByHash(serverDir, hash);
    if (fileName == null) return null;

    final file = File(p.join(serverDir.path, fileName));
    if (!await file.exists()) return null;

    final now = DateTime.now();
    if (file.lastModifiedSync() != now) {
      await file.setLastModified(now);
    }
    return file.path;
  }

  /// Write [bytes] to the cache and evict oldest entries if over the cap.
  /// Returns the cached file path.
  Future<String> stash(
    int remoteServerId,
    String remoteId,
    List<int> bytes, {
    String? extension,
  }) async {
    final serverDir = Directory(
      p.join((await _root()).path, '$remoteServerId'),
    );
    await serverDir.create(recursive: true);
    final file = File(
      p.join(
        serverDir.path,
        '${_hash(remoteServerId, remoteId)}.${extension ?? 'bin'}',
      ),
    );
    await file.writeAsBytes(bytes, flush: true);
    await evictIfOverCap(protect: file);
    return file.path;
  }

  /// Resolve (and create) the canonical cache path for a (server, song) entry
  /// without writing bytes. Lets a native downloader stream straight to disk,
  /// avoiding a full-file FFI buffer round-trip for large FLACs.
  Future<String> pathFor(
    int remoteServerId,
    String remoteId, {
    String? extension,
  }) async {
    final serverDir = Directory(
      p.join((await _root()).path, '$remoteServerId'),
    );
    await serverDir.create(recursive: true);
    return p.join(
      serverDir.path,
      '${_hash(remoteServerId, remoteId)}.${extension ?? 'bin'}',
    );
  }

  Future<String?> _findByHash(Directory serverDir, String hash) async {
    await for (final entry in serverDir.list()) {
      final name = p.basename(entry.path);
      if (name.startsWith('$hash.')) return name;
    }
    return null;
  }

  // ponytail: full O(n) size scan per eviction; track running totals only
  // if a server with a huge cache ever shows up on profile.
  Future<void> evictIfOverCap({File? protect}) async {
    try {
      final cap = await _effectiveCap();
      if (cap <= 0) return; // unlimited: no eviction
      final root = await _root();
      if (!await root.exists()) return;
      final files = <File>[];
      var total = 0;
      await for (final serverDir in root.list()) {
        if (serverDir is! Directory) continue;
        await for (final entry in serverDir.list()) {
          if (entry is! File) continue;
          files.add(entry);
          total += await entry.length();
        }
      }
      if (total <= cap) return;

      files.sort(
        (a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()),
      );
      for (final file in files) {
        if (total <= cap) break;
        if (file.path == protect?.path) continue;
        final length = await file.length();
        await file.delete();
        total -= length;
      }
    } catch (_) {}
  }

  /// Resolves the eviction cap: an explicit constructor [sizeCapBytes] wins,
  /// otherwise the user's live Playback Cache Limit preference is used.
  Future<int> _effectiveCap() async {
    final override = sizeCapBytes;
    if (override != null) return override;
    try {
      return await PlaybackCachePreferencesService().getMaxCacheBytes();
    } catch (_) {
      return defaultSizeCapBytes;
    }
  }

  /// Delete orphaned `.part` files left behind by interrupted streams.
  Future<void> sweepDanglingPartFiles() async {
    try {
      final root = await _root();
      if (!await root.exists()) return;
      await for (final serverDir in root.list()) {
        if (serverDir is! Directory) continue;
        await for (final entry in serverDir.list()) {
          if (entry is! File) continue;
          if (entry.path.endsWith('.part')) {
            try {
              await entry.delete();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  /// Total bytes consumed by all cached files.
  Future<int> getCacheSize() async {
    final root = await _root();
    var total = 0;
    try {
      await for (final serverDir in root.list()) {
        if (serverDir is! Directory) continue;
        await for (final entry in serverDir.list()) {
          if (entry is! File) continue;
          total += await entry.length();
        }
      }
    } catch (_) {}
    return total;
  }

  /// Remove all cached files.
  Future<void> clearCache() async {
    final root = await _root();
    try {
      await for (final serverDir in root.list()) {
        if (serverDir is! Directory) continue;
        await for (final entry in serverDir.list()) {
          if (entry is! File) continue;
          try {
            await entry.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
}
