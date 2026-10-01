import 'dart:convert';

import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/models/song.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the last played song and enough context to restore playback.
class LastPlayedService {
  static const String _lastSongIdKey = 'last_played_song_id';
  static const String _lastSongDataKey = 'last_played_song_data';
  static const String _lastPositionKey = 'last_played_position_ms';
  static const String _lastPlaylistSongIdsKey = 'last_played_playlist_song_ids';
  static const String _lastPlaylistDataKey = 'last_played_playlist_data';
  static const String _lastPlaylistIndexKey = 'last_played_playlist_index';
  static const String _lastWasPlayingKey = 'last_played_was_playing';

  SongRepository? _songRepository;

  LastPlayedService({SongRepository? songRepository})
    : _songRepository = songRepository;

  SongRepository get _repository => _songRepository ??= SongRepository();

  /// Save the current song and position, including ephemeral network tracks.
  Future<void> saveLastPlayed(
    Song song,
    Duration position, {
    List<Song>? playlist,
    int? currentIndex,
    bool wasPlaying = false,
  }) async {
    final songData = jsonEncode(song.toJson());
    final playlistSongs = playlist != null && playlist.isNotEmpty
        ? playlist
        : null;
    final playlistData = playlistSongs == null
        ? null
        : jsonEncode(playlistSongs.map((item) => item.toJson()).toList());
    final playlistIds = playlistSongs == null
        ? null
        : jsonEncode(playlistSongs.map((item) => item.id).toList());

    final prefs = await SharedPreferences.getInstance();
    // Store the payload before the ID, which acts as the legacy commit marker.
    await prefs.setString(_lastSongDataKey, songData);
    await prefs.setInt(_lastPositionKey, position.inMilliseconds);
    await prefs.setBool(_lastWasPlayingKey, wasPlaying);

    if (playlistSongs != null) {
      await prefs.setString(_lastPlaylistDataKey, playlistData!);
      await prefs.setString(_lastPlaylistSongIdsKey, playlistIds!);
      if (currentIndex != null &&
          currentIndex >= 0 &&
          currentIndex < playlistSongs.length) {
        await prefs.setInt(_lastPlaylistIndexKey, currentIndex);
      } else {
        await prefs.remove(_lastPlaylistIndexKey);
      }
    } else {
      await prefs.remove(_lastPlaylistDataKey);
      await prefs.remove(_lastPlaylistSongIdsKey);
      await prefs.remove(_lastPlaylistIndexKey);
    }

    await prefs.setString(_lastSongIdKey, song.id);
  }

  /// Restore the last played song and position, preferring its JSON snapshot.
  Future<
    ({
      Song song,
      Duration position,
      List<Song>? playlist,
      int? playlistIndex,
      bool wasPlaying,
    })?
  >
  getLastPlayed() async {
    final prefs = await SharedPreferences.getInstance();
    final songId = prefs.getString(_lastSongIdKey);
    if (songId == null || songId.isEmpty) return null;

    Song? song;
    final songDataRaw = prefs.getString(_lastSongDataKey);
    if (songDataRaw != null && songDataRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(songDataRaw);
        if (decoded is Map<String, dynamic>) {
          final restoredSong = Song.fromJson(decoded);
          if (restoredSong.id == songId) {
            song = restoredSong;
          }
        }
      } on FormatException {
        // Older or damaged snapshots fall back to the local song database.
      }
    }

    List<Song>? allSongs;
    if (song == null) {
      allSongs = await _repository.getAllSongs();
      song = allSongs.where((item) => item.id == songId).firstOrNull;
    }
    if (song == null) return null;

    List<Song>? restoredPlaylist;
    final playlistDataRaw = prefs.getString(_lastPlaylistDataKey);
    if (playlistDataRaw != null && playlistDataRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(playlistDataRaw);
        if (decoded is List) {
          final mapped = decoded
              .whereType<Map<String, dynamic>>()
              .map(Song.fromJson)
              .where((item) => item.id.isNotEmpty)
              .toList();
          if (mapped.isNotEmpty && mapped.any((item) => item.id == song!.id)) {
            restoredPlaylist = mapped;
          }
        }
      } on FormatException {
        // Older or damaged snapshots fall back to the legacy ID list.
      }
    }

    if (restoredPlaylist == null) {
      final playlistIdsRaw = prefs.getString(_lastPlaylistSongIdsKey);
      if (playlistIdsRaw != null) {
        try {
          final decoded = jsonDecode(playlistIdsRaw);
          if (decoded is List) {
            allSongs ??= await _repository.getAllSongs();
            final songsById = {for (final item in allSongs) item.id: item};
            final mapped = decoded
                .whereType<String>()
                .map((id) => songsById[id])
                .whereType<Song>()
                .toList();
            if (mapped.isNotEmpty &&
                mapped.any((item) => item.id == song!.id)) {
              restoredPlaylist = mapped;
            }
          }
        } on FormatException {
          // Ignore invalid or stale playlist data.
        }
      }
    }

    int? restoredPlaylistIndex;
    if (restoredPlaylist != null) {
      final storedIndex = prefs.getInt(_lastPlaylistIndexKey);
      if (storedIndex != null &&
          storedIndex >= 0 &&
          storedIndex < restoredPlaylist.length &&
          restoredPlaylist[storedIndex].id == song.id) {
        restoredPlaylistIndex = storedIndex;
      } else {
        restoredPlaylistIndex = restoredPlaylist.indexWhere(
          (item) => item.id == song!.id,
        );
      }
    }

    final positionMs = prefs.getInt(_lastPositionKey) ?? 0;
    return (
      song: song,
      position: Duration(milliseconds: positionMs < 0 ? 0 : positionMs),
      playlist: restoredPlaylist,
      playlistIndex: restoredPlaylistIndex,
      wasPlaying: prefs.getBool(_lastWasPlayingKey) ?? false,
    );
  }

  /// Remove both current and legacy persisted playback state.
  Future<void> clearLastPlayed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastSongIdKey);
    await prefs.remove(_lastSongDataKey);
    await prefs.remove(_lastPositionKey);
    await prefs.remove(_lastPlaylistSongIdsKey);
    await prefs.remove(_lastPlaylistDataKey);
    await prefs.remove(_lastPlaylistIndexKey);
    await prefs.remove(_lastWasPlayingKey);
  }
}
