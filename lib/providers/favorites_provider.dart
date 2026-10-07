import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/tidal/providers/tidal_providers.dart';
import '../models/song.dart';
import '../services/favorites_service.dart';
import '../services/sources/network_source_service.dart';
import 'player_provider.dart';

/// Provider for the FavoritesService.
final Provider<FavoritesService> favoritesServiceProvider =
    Provider<FavoritesService>((ref) {
      return FavoritesService();
    });

/// State for favorites management.
class FavoritesState {
  final Set<String> favoriteIds;
  final List<Song> favoriteSongs;
  final bool isLoading;

  const FavoritesState({
    this.favoriteIds = const {},
    this.favoriteSongs = const [],
    this.isLoading = true,
  });

  FavoritesState copyWith({
    Set<String>? favoriteIds,
    List<Song>? favoriteSongs,
    bool? isLoading,
  }) {
    return FavoritesState(
      favoriteIds: favoriteIds ?? this.favoriteIds,
      favoriteSongs: favoriteSongs ?? this.favoriteSongs,
      isLoading: isLoading ?? this.isLoading,
    );
  }

  /// Check if a song is a favorite.
  bool isFavorite(String songId) => favoriteIds.contains(songId);

  /// Number of favorites.
  int get count => favoriteIds.length;
}

/// AsyncNotifier for favorites with autoDispose.
class FavoritesNotifier extends AsyncNotifier<FavoritesState> {
  @override
  Future<FavoritesState> build() async {
    ref.watch(favoriteNotificationSyncProvider);
    final service = ref.watch(favoritesServiceProvider);

    final songs = await service.getFavorites();
    final ids = songs.map((s) => s.id).toSet();

    return FavoritesState(
      favoriteIds: ids,
      favoriteSongs: songs,
      isLoading: false,
    );
  }

  bool _isCurrentlyFavorite(String songId, String? trackId) {
    if (state.value?.isFavorite(songId) ?? false) return true;
    if (trackId != null && trackId.isNotEmpty) {
      final tidalFavs = ref.read(tidalFavoriteTrackIdsProvider).value;
      if (tidalFavs != null && tidalFavs.contains(trackId)) {
        return true;
      }
    }
    return false;
  }

  /// Extracts the numeric TIDAL track ID if the song is from TIDAL.
  String? extractTidalTrackId(String songId, Song? song) {
    if (song?.remoteId != null &&
        song!.remoteId!.isNotEmpty &&
        song.sourceType == NetworkProtocol.tidal) {
      return song.remoteId;
    }
    if (songId.startsWith('tidal_')) {
      final parts = songId.split('_');
      if (parts.length >= 3) {
        return parts.sublist(2).join('_');
      }
    } else if (int.tryParse(songId) != null &&
        (song == null || song.sourceType == NetworkProtocol.tidal)) {
      return songId;
    }
    return null;
  }

  /// Toggle favorite status for a song.
  Future<bool> toggleFavorite(String songId, {Song? song}) async {
    final service = ref.read(favoritesServiceProvider);
    final trackId = extractTidalTrackId(songId, song);
    final isFav = _isCurrentlyFavorite(songId, trackId);
    final newState = !isFav;

    if (newState) {
      await service.addFavorite(songId);
    } else {
      await service.removeFavorite(songId);
    }

    // Sync with TIDAL if it is a TIDAL track
    if (trackId != null && trackId.isNotEmpty) {
      _syncTidalFavorite(trackId, newState, song: song);
    }

    // Refresh state
    ref.invalidateSelf();

    return newState;
  }

  /// Add a song to favorites.
  Future<void> addFavorite(String songId, {Song? song}) async {
    final service = ref.read(favoritesServiceProvider);
    await service.addFavorite(songId);
    final trackId = extractTidalTrackId(songId, song);
    if (trackId != null && trackId.isNotEmpty) {
      _syncTidalFavorite(trackId, true, song: song);
    }
    ref.invalidateSelf();
  }

  /// Remove a song from favorites.
  Future<void> removeFavorite(String songId, {Song? song}) async {
    final service = ref.read(favoritesServiceProvider);
    await service.removeFavorite(songId);
    final trackId = extractTidalTrackId(songId, song);
    if (trackId != null && trackId.isNotEmpty) {
      _syncTidalFavorite(trackId, false, song: song);
    }
    ref.invalidateSelf();
  }

  void _syncTidalFavorite(String trackId, bool isFavorite, {Song? song}) {
    // 1. Optimistic updates in Riverpod state for zero-latency UI reflection
    final optIds = ref.read(tidalFavoriteTrackIdsOptimisticProvider.notifier);
    final optSongs = ref.read(tidalLikedSongsOptimisticProvider.notifier);

    if (isFavorite) {
      optIds.add(trackId);

      var resolvedSong = song;
      if (resolvedSong == null) {
        final current = ref.read(currentSongProvider);
        if (current != null &&
            (current.id.endsWith('_$trackId') || current.remoteId == trackId)) {
          resolvedSong = current;
        }
      }

      if (resolvedSong != null) {
        final songWithDate = resolvedSong.copyWith(dateAdded: DateTime.now());
        optSongs.add(songWithDate);
      }
    } else {
      optIds.remove(trackId);
      optSongs.remove(trackId);
    }

    // 2. Dispatch background network call to TIDAL API
    unawaited(_dispatchTidalFavorite(trackId, isFavorite));
  }

  Future<void> _dispatchTidalFavorite(String trackId, bool isFavorite) async {
    try {
      final server = await ref.read(tidalServerProvider.future);
      if (server != null && server.token != null && server.token!.isNotEmpty) {
        final tidal = ref.read(tidalServiceProvider);
        if (isFavorite) {
          await tidal.addFavoriteTrack(server, trackId);
        } else {
          await tidal.removeFavoriteTrack(server, trackId);
        }
        ref.invalidate(tidalFavoriteTrackIdsProvider);
        ref.invalidate(tidalLikedSongsProvider);
      }
    } catch (_) {
      // Local state is preserved even if network sync errors out
    }
  }

  /// Clear all favorites.
  Future<void> clearFavorites() async {
    final service = ref.read(favoritesServiceProvider);
    await service.clearFavorites();
    ref.invalidateSelf();
  }
}

/// Main favorites provider.
final favoritesProvider =
    AsyncNotifierProvider.autoDispose<FavoritesNotifier, FavoritesState>(
      FavoritesNotifier.new,
    );

/// Convenience provider to check if a specific song is a favorite.
/// Usage: ref.watch(isSongFavoriteProvider(songId))
final isSongFavoriteProvider = Provider.autoDispose.family<bool, String>((
  ref,
  songId,
) {
  String? trackId;
  if (songId.startsWith('tidal_')) {
    final parts = songId.split('_');
    if (parts.length >= 3) {
      trackId = parts.sublist(2).join('_');
    }
  } else if (int.tryParse(songId) != null) {
    trackId = songId;
  }

  if (trackId != null && trackId.isNotEmpty) {
    final opt = ref.watch(tidalFavoriteTrackIdsOptimisticProvider);
    if (opt.added.contains(trackId)) return true;
    if (opt.removed.contains(trackId)) return false;

    final tidalFavs = ref.watch(tidalFavoriteTrackIdsProvider).value;
    if (tidalFavs != null && tidalFavs.contains(trackId)) {
      return true;
    }
  }

  final favorites = ref.watch(favoritesProvider).value;
  if (favorites?.isFavorite(songId) ?? false) return true;

  return false;
});

/// Favorites count provider.
final favoritesCountProvider = Provider.autoDispose<int>((ref) {
  return ref.watch(favoritesProvider).value?.count ?? 0;
});

/// Syncs favorites state from lock screen/notification toggles back into
/// Riverpod so the app UI reflects changes made via the media session.
final Provider<void> favoriteNotificationSyncProvider = Provider<void>((ref) {
  final service = ref.watch(playerServiceProvider);
  final notifier = service.favoriteNotificationToggleNotifier;

  void listener() {
    ref.invalidate(favoritesProvider);
    final currentSong = ref.read(currentSongProvider);
    if (currentSong != null) {
      FavoritesService().isFavorite(currentSong.id).then((isFav) {
        final favNotifier = ref.read(favoritesProvider.notifier);
        final trackId = favNotifier.extractTidalTrackId(
          currentSong.id,
          currentSong,
        );
        if (trackId != null && trackId.isNotEmpty) {
          favNotifier._syncTidalFavorite(trackId, isFav, song: currentSong);
        }
      });
    }
  }

  notifier.addListener(listener);
  ref.onDispose(() => notifier.removeListener(listener));
  return;
});
