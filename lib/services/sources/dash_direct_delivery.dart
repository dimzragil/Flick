import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'dash_manifest_parser.dart';

/// Whether the player can fetch this DASH track's media with no local help.
///
/// The MPD is not hosted on the CDN — it arrives inside the playbackinfo
/// response — so the player has to be handed the bytes itself. Everything
/// else (init segment, media segments) must be an absolute `https://` URL the
/// player can open directly; a relative URL without a usable BaseURL would
/// have to be resolved by a server that no longer exists.
bool dashManifestIsSelfContained(DashTrackInfo info) {
  bool absoluteHttps(String url) => url.startsWith('https://');
  if (info.manifestXml.trim().isEmpty) return false;
  if (info.segmentUrls.isEmpty) return false;
  return absoluteHttps(info.initializationUrl) &&
      info.segmentUrls.every(absoluteHttps);
}

/// Temp `.mpd` files handed to the speaker engine.
///
/// ExoPlayer infers DASH from the `.mpd` extension and loads the manifest by
/// path, so the stripped MPD has to exist on disk for as long as the player
/// may load it — including queued playlist entries that ExoPlayer has already
/// prepared. (The Rust engine does not read this file: it is handed the parsed
/// segment plan instead, see `TidalService.directDashPlan`.)
///
/// The store is therefore bounded rather than aggressively purged: one file
/// per resolved track, capped at [maxFiles] (least-recently-written first),
/// with [evict]/[evictAll] for explicit cancellation. Deleting a queued
/// track's manifest on every track change would break ExoPlayer's
/// already-built sequence, which is exactly the kind of silent regression
/// this migration must not introduce.
class DashManifestStore {
  DashManifestStore({Directory? rootDirectory})
    : _rootDirectory = rootDirectory;

  /// Upper bound on live manifests (~20 KB each, so ~1.3 MB at the cap).
  static const int maxFiles = 64;

  static const String _dirName = 'tidal_mpd';

  final Directory? _rootDirectory;

  Future<Directory>? _rootFuture;

  /// trackId -> path of the manifest written for it this session.
  final Map<String, String> _pathByTrack = {};

  /// trackId -> exact bytes written, so a re-resolve of the same track does
  /// not rewrite the file (the second resolve of a play goes through here).
  final Map<String, String> _contentByTrack = {};

  @visibleForTesting
  int get trackedFileCount => _pathByTrack.length;

  String? pathFor(String trackId) => _pathByTrack[trackId];

  Future<Directory> _root() {
    return _rootFuture ??= () async {
      final injected = _rootDirectory;
      final root =
          injected ??
          Directory(
            p.join((await getApplicationCacheDirectory()).path, _dirName),
          );
      await root.create(recursive: true);
      // Nothing in a fresh process can reference a manifest written by an
      // earlier run, so clear the directory once per session.
      try {
        await for (final entry in root.list()) {
          if (entry is File && entry.path.endsWith('.mpd')) {
            await _deleteQuietly(entry);
          }
        }
      } catch (_) {}
      return root;
    }();
  }

  static String _fileName(String trackId) {
    final safe = trackId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return '${safe.isEmpty ? 'track' : safe}.mpd';
  }

  /// Write [xml] for [trackId] and return the absolute path.
  Future<String> write({required String trackId, required String xml}) async {
    final existing = _pathByTrack[trackId];
    if (existing != null &&
        _contentByTrack[trackId] == xml &&
        await File(existing).exists()) {
      return existing;
    }

    final root = await _root();
    final file = File(p.join(root.path, _fileName(trackId)));
    await file.writeAsString(xml, flush: true);
    _pathByTrack[trackId] = file.path;
    _contentByTrack[trackId] = xml;
    await _pruneToCap();
    return file.path;
  }

  /// Drop the manifest for one track (explicit cancellation / eviction).
  Future<void> evict(String trackId) async {
    final path = _pathByTrack.remove(trackId);
    _contentByTrack.remove(trackId);
    if (path == null) return;
    await _deleteQuietly(File(path));
  }

  /// Drop every manifest (playback teardown).
  Future<void> evictAll() async {
    final paths = _pathByTrack.values.toList();
    _pathByTrack.clear();
    _contentByTrack.clear();
    for (final path in paths) {
      await _deleteQuietly(File(path));
    }
  }

  Future<void> _pruneToCap() async {
    if (_pathByTrack.length <= maxFiles) return;
    final entries = <({String trackId, DateTime modified})>[];
    for (final trackId in _pathByTrack.keys) {
      final path = _pathByTrack[trackId]!;
      try {
        entries.add((
          trackId: trackId,
          modified: await File(path).lastModified(),
        ));
      } catch (_) {
        // File vanished: forget it and move on.
        _pathByTrack.remove(trackId);
        _contentByTrack.remove(trackId);
      }
    }
    entries.sort((a, b) => a.modified.compareTo(b.modified));
    final excess = _pathByTrack.length - maxFiles;
    for (var i = 0; i < excess && i < entries.length; i++) {
      final trackId = entries[i].trackId;
      final path = _pathByTrack[trackId];
      _pathByTrack.remove(trackId);
      _contentByTrack.remove(trackId);
      if (path != null) await _deleteQuietly(File(path));
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
