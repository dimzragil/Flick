import '../core/utils/dev_log.dart';
import '../data/repositories/song_repository.dart';

/// Startup sweep for `song_audio_cache` rows whose song no longer exists.
///
/// Older releases deleted songs without removing their waveform/analysis
/// cache, and a preload pass racing a deletion can still produce an orphan.
/// The sweep is idempotent and cheap (it reads only song IDs, not peaks), so
/// running it on every launch keeps the cache table bounded.
Future<void> runAudioCacheOrphanCleanup() async {
  try {
    final removed = await SongRepository().deleteOrphanedAudioCache();
    if (removed > 0) {
      devLog('[audio-cache] removed $removed orphaned cache row(s)');
    }
  } catch (e) {
    // Maintenance must never block startup; the next launch retries.
    devLog('[audio-cache] orphan cleanup failed: $e');
  }
}
