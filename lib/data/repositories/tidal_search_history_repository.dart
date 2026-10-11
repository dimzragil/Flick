import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../models/song.dart';

/// Stores songs played from TIDAL Search, shown as "Recently Played"
/// in the empty search state (Spotify-style).
class TidalSearchHistoryRepository {
  static const _key = 'tidal_search_recently_played';
  static const _maxItems = 20;

  /// Serializes recordPlay calls so concurrent plays can't read-modify-write
  /// the same JSON and silently drop an entry.
  Future<void> _pending = Future.value();

  /// Records a song played from search. Most recent first, deduplicated.
  Future<void> recordPlay(Song song) {
    final task = _pending.then((_) => _recordPlayInternal(song));
    // Keep the chain alive even if one write fails.
    _pending = task.catchError((_) {});
    return task;
  }

  Future<void> _recordPlayInternal(Song song) async {
    final prefs = await SharedPreferences.getInstance();
    final items = await getRecent();

    // Remove existing entry for this song (dedupe), then prepend.
    items.removeWhere((s) => s.id == song.id);
    items.insert(0, song);

    final trimmed = items.take(_maxItems).toList();
    final json = jsonEncode(trimmed.map((s) => s.toJson()).toList());
    await prefs.setString(_key, json);
  }

  /// Returns recently played songs, most recent first.
  Future<List<Song>> getRecent() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_key);
    if (json == null || json.isEmpty) return [];

    try {
      final list = jsonDecode(json) as List;
      return list
          .map((e) => Song.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Clears the history.
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
