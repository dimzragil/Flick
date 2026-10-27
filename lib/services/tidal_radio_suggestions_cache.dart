import '../models/song.dart';

/// Holds only the active seed's radio result for the current app session.
/// In-flight results are discarded if playback has moved to another seed.
class TidalRadioSuggestionsCache {
  String? _seedKey;
  int _generation = 0;
  Future<List<Song>>? _tracks;

  Future<List<Song>> get({
    required String seedKey,
    required bool Function() isSeedCurrent,
    required Future<List<Song>> Function() fetch,
  }) {
    if (_seedKey != seedKey || _tracks == null) {
      _seedKey = seedKey;
      final generation = ++_generation;
      _tracks = fetch()
          .then((tracks) {
            if (generation != _generation ||
                _seedKey != seedKey ||
                !isSeedCurrent()) {
              return const <Song>[];
            }
            return tracks;
          })
          .catchError((Object _) => <Song>[]);
    }
    final tracks = _tracks!;
    return tracks.then((result) {
      if (_seedKey != seedKey || !isSeedCurrent()) return const <Song>[];
      return result;
    });
  }

  void clear() {
    _generation++;
    _seedKey = null;
    _tracks = null;
  }
}

/// Applies display and autoplay exclusions to a cached radio response.
List<Song> filterSuggestedRadioTracks(
  Iterable<Song> tracks,
  Set<String> excludedIds, {
  int limit = 15,
}) {
  return tracks
      .where((song) => !excludedIds.contains(song.remoteId ?? song.id))
      .take(limit)
      .toList(growable: false);
}
