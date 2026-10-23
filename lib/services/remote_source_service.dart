import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/utils/app_log.dart';
import '../data/database.dart';
import '../data/repositories/song_repository.dart';
import '../models/song.dart';
import '../src/rust/api/audio_api.dart' as rust_audio;
import 'sources/network_source_service.dart';
import 'sources/tidal_service.dart';

/// Bridges playback/download for network-sourced songs.
///
/// A cache hit returns the local file path immediately (gapless/crossfade
/// handoff reads a local file); a miss downloads the original-quality stream
/// into [NetworkCacheService] via the protocol service registered for the
/// song's `sourceType`.
class RemoteSourceService {
  RemoteSourceService._();

  static RemoteSourceService instance = RemoteSourceService._();

  @visibleForTesting
  static RemoteSourceService create() => RemoteSourceService._();

  /// Progress (0..1) of the interactive playback download, null when idle.
  final ValueNotifier<double?> downloadProgressNotifier = ValueNotifier(null);

  /// Transient, user-facing notice for a blocked track start (for example
  /// TIDAL's resolve breaker being open). The UI shows it as a snackbar and
  /// resets it to null; null means nothing to report.
  final ValueNotifier<String?> playbackIssueNotifier = ValueNotifier(null);

  void _reportPlaybackIssue(Object error) {
    if (error is TidalUnavailableException) {
      playbackIssueNotifier.value = error.message;
    }
  }

  /// Songs whose format probe failed (e.g. AAC-in-M4A Symphonia gap);
  /// skip retrying them every play.
  final Set<String> _probeFailed = {};

  Future<NetworkServerEntity> _serverFor(Song song) async {
    final serverId = song.remoteServerId;
    if (serverId == null) {
      throw StateError('Network song has no remote server id');
    }
    final server = await Database.networkServers.get(serverId);
    if (server == null) {
      throw StateError('Network server $serverId not found');
    }
    return server;
  }

  /// Ensure a playable local copy of [song] exists and return its path.
  /// Downloads (with progress on [downloadProgressNotifier]) when uncached.
  Future<String> ensureLocal(Song song, {bool reportProgress = true}) async {
    if (!song.isNetworkSource) {
      throw StateError('Song is not a network source');
    }
    final sourceType = song.sourceType;
    if (sourceType == null) {
      throw StateError('Network song has no source type');
    }
    final server = await _serverFor(song);
    final remoteId = song.remoteId;
    if (remoteId == null) {
      throw StateError('Network song has no remote id');
    }
    final service = networkSourceServiceFor(sourceType);
    if (service is TidalService && song.title.isNotEmpty) {
      TidalService.recordTrackTitle(remoteId, song.title);
    }
    try {
      final path = await service.stream(
        server,
        remoteId,
        extension: song.fileType,
        onProgress: reportProgress
            ? (p) => downloadProgressNotifier.value = p
            : null,
      );
      unawaited(_backfillAudioFormat(song, path));
      return path;
    } on TidalUnavailableException catch (e) {
      // The resolve was refused fast (shared failure or open breaker); tell
      // the user instead of leaving them with a dead spinner.
      _reportPlaybackIssue(e);
      rethrow;
    } finally {
      if (reportProgress) downloadProgressNotifier.value = null;
    }
  }

  /// Cancel any active in-flight network stream downloads.
  void cancelAllDownloads() {
    try {
      final tidal = networkSourceServiceFor(NetworkProtocol.tidal);
      if (tidal is TidalService) {
        tidal.cancelAllDownloads();
      }
    } catch (_) {}
  }

  /// ponytail: probe-once backfill for sources whose sync can't read tags
  /// (SMB/WebDAV listing has no sampleRate/bitDepth, or TIDAL DASH master).
  /// Runs after the file is local either way; HTTP-direct streams skip it.
  Future<void> _backfillAudioFormat(Song song, String localPath) async {
    if (_probeFailed.contains(song.id)) return;
    try {
      final probed = await rust_audio.audioProbeFormat(path: localPath);
      final realRate = probed.sampleRate;
      final realBits = probed.bitsPerSample ?? 16;
      if (song.sampleRate == realRate && song.bitDepth == realBits) return;
      if (song.filePath != null) {
        await SongRepository().updateAudioFormat(
          song.filePath!,
          sampleRate: realRate,
          bitDepth: realBits,
        );
      }
    } catch (e) {
      _probeFailed.add(song.id);
      AppLog.instance.add('Format backfill failed for "${song.title}": $e');
    }
  }

  /// Resolve a direct ranged HTTP stream for [song] when the protocol supports
  /// byte-range requests. Returns null when unsupported (UPnP/SMB) or on
  /// resolve failure — callers fall back to cache-then-play via [ensureLocal].
  Future<({String url, Map<String, String> headers})?> resolveHttpPlayback(
    Song song,
  ) async {
    if (!song.isNetworkSource) return null;
    final sourceType = song.sourceType;
    final remoteId = song.remoteId;
    if (sourceType == null || remoteId == null) return null;
    try {
      final server = await _serverFor(song);
      final service = networkSourceServiceFor(sourceType);
      if (service is TidalService && song.title.isNotEmpty) {
        TidalService.recordTrackTitle(remoteId, song.title);
      }
      return await service.streamDescriptor(
        server,
        remoteId,
        extension: song.fileType,
      );
    } catch (e) {
      AppLog.instance.add('HTTP stream resolve failed for "${song.title}": $e');
      return null;
    }
  }

  /// Descriptor for the Rust engine, which consumes `(url, headers)` through
  /// flutter_rust_bridge.
  ///
  /// TIDAL DASH has no CDN-hosted manifest the engine could fetch, and the
  /// engine has no MPD reader, so the speaker's temp-`.mpd` descriptor is
  /// translated into the segment plan the parser already produced. Anything
  /// the engine cannot fetch directly returns null, which sends the caller
  /// down cache-then-play (always direct CDN bytes, never a proxy).
  Future<({String url, Map<String, String> headers})?> resolveRustHttpPlayback(
    Song song,
  ) async {
    final http = await resolveHttpPlayback(song);
    if (http == null) return null;
    final sourceType = song.sourceType;
    final remoteId = song.remoteId;
    if (sourceType == null || remoteId == null) return http;
    try {
      final service = networkSourceServiceFor(sourceType);
      if (service is TidalService) {
        final plan = service.directDashPlan(remoteId);
        if (plan != null) return plan;
        if (http.url.startsWith('file:')) {
          // A local manifest path means the engine got no plan; it cannot read
          // the file, so let the caller fall back instead of failing on load.
          return null;
        }
      }
    } catch (e) {
      AppLog.instance.add('Rust HTTP stream resolve failed: $e');
    }
    return http;
  }

  /// Format resolution for network sources (Tidal etc.) without downloading.
  ({int sampleRate, int bitDepth, String? resolution, String? fileType})?
  getAudioFormat(Song song) {
    if (!song.isNetworkSource) return null;
    final remoteId = song.remoteId;
    if (remoteId == null) return null;
    try {
      final tidal = networkSourceServiceFor(NetworkProtocol.tidal);
      if (tidal is TidalService) {
        final res = tidal.getResolvedStream(remoteId);
        if (res != null) {
          return (
            sampleRate: res.sampleRate,
            bitDepth: res.bitDepth,
            resolution: res.resolutionString,
            fileType: res.codec != null ? res.codec! : (res.ext ?? 'flac'),
          );
        }
      }
    } catch (_) {}
    return null;
  }

  /// Formatted stream-quality log line for a TIDAL song's cached resolution.
  /// Returns null when the song is not a TIDAL network song or no resolution
  /// is cached. Used to log exactly one line per played track (at play
  /// start), instead of logging at resolve time (which also fires for every
  /// background-prefetched playlist/album track).
  String? resolvedStreamLog(Song song) {
    if (!song.isNetworkSource) return null;
    final remoteId = song.remoteId;
    if (remoteId == null) return null;
    try {
      final tidal = networkSourceServiceFor(NetworkProtocol.tidal);
      if (tidal is TidalService) {
        final res = tidal.getResolvedStream(remoteId);
        final profile = res?.profile;
        if (res != null && profile != null) {
          return TidalService.formatStreamResolvedLog(remoteId, profile, res);
        }
      }
    } catch (_) {}
    return null;
  }

  /// Background prefetch for the next queue entry. Best effort: never throws,
  /// does not touch [downloadProgressNotifier] (interactive downloads own it).
  Future<void> prefetch(Song song) async {
    // Direct streaming sources (Tidal) stream on-demand with <1s latency via
    // queueNextHttp; avoid downloading 80-100 MB in the background.
    if (song.sourceType == NetworkProtocol.tidal) return;
    try {
      await ensureLocal(song, reportProgress: false);
    } catch (e) {
      AppLog.instance.add('Prefetch failed for "${song.title}": $e');
    }
  }
}
