import 'package:flutter/foundation.dart';

import '../data/database.dart';
import '../models/song.dart';
import '../models/sources/tidal_lyrics.dart';
import 'lyrics_service.dart';
import 'online_lyrics_service.dart';
import 'sources/network_source_service.dart';
import 'sources/tidal_service.dart';

/// Loads a TIDAL track's lyrics payload (or a stand-in in tests).
typedef TidalLyricsLoader = Future<TidalLyrics?> Function(Song song);

/// Picks the lyrics source for a song.
///
/// Priority:
/// 1. Locally stored lyrics — a manual import, an embedded tag, or a sidecar
///    file. The user chose those explicitly, so they always win.
/// 2. TIDAL, by track id (`GET /v1/tracks/{id}/lyrics`).
/// 3. lrclib, by artist/title (the lookup the "Search Online" sheet already
///    uses), for TIDAL songs TIDAL has no lyrics for.
///
/// Songs from every other source (local files, SMB, UPnP, Subsonic, Jellyfin,
/// WebDAV) never reach steps 2–3: their behaviour stays exactly as before this
/// service existed.
///
/// Results are cached in memory per track for the session so reopening the
/// lyrics view does not refetch; nothing is written to the database.
class LyricsSourceService {
  LyricsSourceService({
    LyricsService? localLyrics,
    OnlineLyricsService? onlineLyrics,
    TidalLyricsLoader? tidalLyricsLoader,
  }) : _local = localLyrics ?? LyricsService(),
       _online = onlineLyrics ?? OnlineLyricsService(),
       _tidalLoader = tidalLyricsLoader ?? _loadTidalLyrics;

  static final LyricsSourceService instance = LyricsSourceService();

  final LyricsService _local;
  final OnlineLyricsService _online;
  final TidalLyricsLoader _tidalLoader;

  /// song key -> resolved lyrics for the session (null = both online sources
  /// had nothing, so reopening does not re-hit the network either).
  final Map<String, LyricsData?> _sessionCache = {};

  @visibleForTesting
  void clearSessionCache() => _sessionCache.clear();

  @visibleForTesting
  int get sessionCacheSize => _sessionCache.length;

  /// Resolve the lyrics to display for [song].
  ///
  /// [forceRefreshLocal] re-reads local lyrics from disk (an import or an edit
  /// just changed them) without discarding the session's online result.
  Future<LyricsData?> loadForSong(
    Song song, {
    bool forceRefreshLocal = false,
  }) async {
    // 1. Local lyrics win, for every source type.
    final local = await _local.loadLyricsForSong(
      song,
      forceRefresh: forceRefreshLocal,
    );
    if (local != null && local.lines.isNotEmpty) return local;

    if (!_isTidalSong(song)) {
      // Non-TIDAL songs keep the pre-existing local-only behaviour.
      return local;
    }

    final cacheKey = _cacheKey(song);
    if (_sessionCache.containsKey(cacheKey)) {
      return _sessionCache[cacheKey];
    }

    final resolved = await _resolveTidalThenLrclib(song);
    _sessionCache[cacheKey] = resolved;
    return resolved;
  }

  static String _cacheKey(Song song) =>
      '${song.sourceType ?? ''}:${song.remoteServerId ?? 0}:${song.remoteId ?? ''}';

  static bool _isTidalSong(Song song) =>
      song.sourceType == NetworkProtocol.tidal &&
      (song.remoteId ?? '').isNotEmpty &&
      song.remoteServerId != null;

  Future<LyricsData?> _resolveTidalThenLrclib(Song song) async {
    final fromTidal = _parseTidal(await _loadTidalSafely(song));
    if (fromTidal != null) return fromTidal;
    return _fetchLrclib(song);
  }

  Future<TidalLyrics?> _loadTidalSafely(Song song) async {
    try {
      return await _tidalLoader(song);
    } catch (e) {
      // No lyrics is not an error, and neither is a TIDAL hiccup: fall through
      // to lrclib and let the UI show the empty state if that misses too.
      debugPrint('[LyricsSource] TIDAL lyrics failed: $e');
      return null;
    }
  }

  /// Subtitles (line-level LRC) are preferred over plain lyrics so the player
  /// can follow playback. Both go through the existing lyrics parser, so
  /// `words` stays null and the karaoke sweep uses its estimated mode.
  LyricsData? _parseTidal(TidalLyrics? lyrics) {
    if (lyrics == null) return null;

    final subtitles = lyrics.subtitles;
    if (subtitles != null) {
      final parsed = _local.parseLyricsText(
        subtitles,
        source: 'TIDAL',
        isRightToLeft: lyrics.isRightToLeft,
      );
      if (parsed.lines.isNotEmpty) return parsed;
    }

    final plain = lyrics.lyrics;
    if (plain != null) {
      final parsed = _local.parseLyricsText(
        plain,
        source: 'TIDAL',
        isRightToLeft: lyrics.isRightToLeft,
      );
      if (parsed.lines.isNotEmpty) return parsed;
    }
    return null;
  }

  Future<LyricsData?> _fetchLrclib(Song song) async {
    try {
      final result = await _online.fetchExact(
        artist: song.artist,
        title: song.title,
        album: song.album,
        duration: song.duration,
      );
      if (result == null) return null;
      final text = result.hasSyncedLyrics
          ? result.syncedLyrics
          : result.plainLyrics;
      if (text == null || text.trim().isEmpty) return null;
      final parsed = _local.parseLyricsText(text, source: 'lrclib');
      return parsed.lines.isEmpty ? null : parsed;
    } catch (e) {
      debugPrint('[LyricsSource] lrclib lookup failed: $e');
      return null;
    }
  }

  /// Production TIDAL loader: the song's server row + the authenticated service.
  static Future<TidalLyrics?> _loadTidalLyrics(Song song) async {
    final remoteId = song.remoteId;
    final serverId = song.remoteServerId;
    if (remoteId == null || remoteId.isEmpty || serverId == null) return null;

    final server = await Database.networkServers.get(serverId);
    if (server == null) return null;

    final service = networkSourceServiceFor(NetworkProtocol.tidal);
    if (service is! TidalService) return null;
    return service.getTrackLyrics(server, remoteId);
  }
}
