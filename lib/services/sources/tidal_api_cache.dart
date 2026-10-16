/// Simple TTL (time-to-live) cache for TIDAL API responses.
///
/// Reduces API call volume to stay clear of TIDAL's rate limits: Hub data
/// (home feed, playlists) changes slowly, so re-fetching on every Hub visit
/// wastes the shared rate-limit budget. Cached entries are served from
/// memory until [ttl] expires; afterwards the next read triggers a fresh
/// fetch.
///
/// This is intentionally in-memory only: the parsed model classes
/// (TidalHomeFeed, etc.) have no toJson/fromJson, so disk persistence would
/// require invasive serialization work. App restart re-fetches fresh data,
/// which is acceptable — users expect fresh content on cold start.
class TtlCache<T> {
  final Duration ttl;
  final Map<String, _Entry<T>> _entries = {};

  TtlCache({required this.ttl});

  /// Returns the cached value for [key], or null if absent/expired.
  T? get(String key) {
    final entry = _entries[key];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.fetchedAt) > ttl) {
      _entries.remove(key);
      return null;
    }
    return entry.value;
  }

  /// Stores [value] for [key] with the current timestamp.
  void set(String key, T value) {
    _entries[key] = _Entry(value, DateTime.now());
  }

  /// Drops the cached value for [key], forcing a fresh fetch next read.
  void invalidate(String key) => _entries.remove(key);

  /// Drops all cached values.
  void invalidateAll() => _entries.clear();
}

class _Entry<T> {
  final T value;
  final DateTime fetchedAt;
  _Entry(this.value, this.fetchedAt);
}
