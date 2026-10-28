import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar_community/isar.dart';

import '../../../data/database.dart';
import '../../../models/song.dart';
import '../../../models/sources/tidal_models.dart';
import '../../../services/sources/network_source_service.dart';
import '../../../services/sources/tidal_album_deduplication.dart';
import '../../../services/sources/tidal_api_cache.dart';
import '../../../services/sources/tidal_service.dart';

/// TTL caches for Hub data — reduces TIDAL API calls to stay clear of
/// rate limits. Home feed changes more often than playlists.
final _homeFeedCache = TtlCache<TidalHomeFeed>(
  ttl: const Duration(minutes: 15),
);
final _playlistsCache = TtlCache<List<Map<String, dynamic>>>(
  ttl: const Duration(minutes: 30),
);
const _userPlaylistsCacheKey = 'user_playlists';

/// Clears only the cached user-playlist list.
///
/// Playlist mutations and explicit user refreshes must call this: without it
/// the next provider rebuild is served the same stale list for up to the
/// 30-minute TTL. This deliberately leaves the home feed cache warm — a
/// playlist change must not force an unrelated (and expensive) feed refetch.
void invalidateTidalPlaylistsCache() {
  _playlistsCache.invalidate(_userPlaylistsCacheKey);
}

/// Clears the Hub TTL caches, forcing fresh API fetches on next read.
/// Call this from manual retry/refresh actions so they actually hit the API.
void invalidateTidalHubCache({String? feedSlug}) {
  if (feedSlug != null) {
    _homeFeedCache.invalidate(feedSlug);
  } else {
    _homeFeedCache.invalidateAll();
  }
  invalidateTidalPlaylistsCache();
}

/// Provider for the singleton [TidalService] instance.
final tidalServiceProvider = Provider<TidalService>((ref) {
  return TidalService.instance;
});

/// Manages the active TIDAL [NetworkServerEntity] stored in the local database.
final tidalServerProvider =
    AsyncNotifierProvider<TidalServerNotifier, NetworkServerEntity?>(
      TidalServerNotifier.new,
    );

class TidalServerNotifier extends AsyncNotifier<NetworkServerEntity?> {
  @override
  Future<NetworkServerEntity?> build() async {
    return _findTidalServer();
  }

  Future<NetworkServerEntity?> _findTidalServer() async {
    try {
      final servers = await Database.networkServers.where().findAll();
      for (final s in servers) {
        if (s.protocol == NetworkProtocol.tidal) {
          return s;
        }
      }
    } catch (_) {
      // In case database is not initialized yet (e.g. testing)
    }
    return null;
  }

  /// Reload the server entity from the database.
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => _findTidalServer());
  }

  /// Run the TIDAL OAuth2 device-code sign-in flow and persist the token.
  Future<NetworkServerEntity?> signIn({
    void Function(String verificationLink)? onVerificationLink,
  }) async {
    final tidal = ref.read(tidalServiceProvider);
    final token = await tidal.signIn(onVerificationLink: onVerificationLink);
    if (token == null) return null;

    var server = await _findTidalServer();
    if (server == null) {
      server = NetworkServerEntity()
        ..label = 'Tidal'
        ..protocol = NetworkProtocol.tidal
        ..baseUrl = TidalService.tidalBaseUrl
        ..token = token;
    } else {
      server.token = token;
    }

    await Database.instance.writeTxn(() async {
      await Database.networkServers.put(server!);
    });
    await tidal.migrateServerToken(server);

    // A fresh session may belong to a different account — never serve the
    // previous account's cached Hub data.
    invalidateTidalHubCache();

    // New account — drop stale optimistic favorite adjustments.
    ref.read(tidalFavoriteTrackIdsOptimisticProvider.notifier).clear();
    ref.read(tidalLikedSongsOptimisticProvider.notifier).clear();
    ref.read(tidalFavoriteArtistIdsOptimisticProvider.notifier).clear();
    ref.read(tidalLikedAlbumsOptimisticProvider.notifier).clear();

    state = AsyncValue.data(server);
    return server;
  }

  /// Sign out by clearing the stored token.
  Future<void> signOut() async {
    final server = state.value ?? await _findTidalServer();
    if (server != null) {
      server.token = null;
      await Database.instance.writeTxn(() async {
        await Database.networkServers.put(server);
      });
      await ref.read(tidalServiceProvider).forgetToken(server.id);
      // Never let the signed-out account's Hub data survive into the next
      // session (playlists are account-specific).
      invalidateTidalHubCache();
      // Drop optimistic adjustments so they can't leak into another account.
      ref.read(tidalFavoriteTrackIdsOptimisticProvider.notifier).clear();
      ref.read(tidalLikedSongsOptimisticProvider.notifier).clear();
      ref.read(tidalFavoriteArtistIdsOptimisticProvider.notifier).clear();
      ref.read(tidalLikedAlbumsOptimisticProvider.notifier).clear();
      state = AsyncValue.data(server);
    }
  }
}

/// Indicates whether the user currently has an authenticated TIDAL session.
final tidalAuthStateProvider = Provider<bool>((ref) {
  final serverAsync = ref.watch(tidalServerProvider);
  return serverAsync.maybeWhen(
    data: (server) =>
        server != null && server.token != null && server.token!.isNotEmpty,
    orElse: () => false,
  );
});

/// Immutable result set for a TIDAL catalog search.
class TidalSearchResults {
  final List<Song> tracks;
  final List<Map<String, dynamic>> albums;
  final List<Map<String, dynamic>> artists;
  final List<Map<String, dynamic>> playlists;
  final bool isLoading;
  final String? error;
  final String query;

  const TidalSearchResults({
    this.tracks = const [],
    this.albums = const [],
    this.artists = const [],
    this.playlists = const [],
    this.isLoading = false,
    this.error,
    this.query = '',
  });

  bool get isEmpty =>
      tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty;

  static const empty = TidalSearchResults();

  TidalSearchResults copyWith({
    List<Song>? tracks,
    List<Map<String, dynamic>>? albums,
    List<Map<String, dynamic>>? artists,
    List<Map<String, dynamic>>? playlists,
    bool? isLoading,
    String? error,
    String? query,
  }) {
    return TidalSearchResults(
      tracks: tracks ?? this.tracks,
      albums: albums ?? this.albums,
      artists: artists ?? this.artists,
      playlists: playlists ?? this.playlists,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      query: query ?? this.query,
    );
  }
}

/// Notifier managing search state, debouncing, and catalog querying.
final tidalSearchProvider =
    NotifierProvider<TidalSearchNotifier, TidalSearchResults>(
      TidalSearchNotifier.new,
    );

class TidalSearchNotifier extends Notifier<TidalSearchResults> {
  Timer? _debounceTimer;

  /// Generation counter: each new search invalidates in-flight older ones so
  /// a slow response can't overwrite newer results.
  int _searchGen = 0;

  @override
  TidalSearchResults build() {
    ref.onDispose(() {
      _debounceTimer?.cancel();
    });
    return TidalSearchResults.empty;
  }

  /// Update query and schedule a debounced catalog search.
  void search(
    String rawQuery, {
    Duration debounce = const Duration(milliseconds: 400),
  }) {
    final query = rawQuery.trim();
    _debounceTimer?.cancel();

    if (query.isEmpty) {
      state = TidalSearchResults.empty;
      return;
    }

    state = state.copyWith(isLoading: true, query: query, error: null);

    final gen = ++_searchGen;
    _debounceTimer = Timer(debounce, () {
      performSearch(query, gen);
    });
  }

  /// Immediately perform catalog search without debouncing.
  Future<void> performSearch(String query, [int? gen]) async {
    final myGen = gen ?? ++_searchGen;
    final server = await ref.read(tidalServerProvider.future);
    if (server == null || server.token == null || server.token!.isEmpty) {
      if (myGen != _searchGen) return;
      state = state.copyWith(isLoading: false, error: 'Tidal is not signed in');
      return;
    }

    try {
      final tidal = ref.read(tidalServiceProvider);
      final raw = await tidal.searchCatalog(server, query);

      // Stale response: a newer search has started since.
      if (myGen != _searchGen) return;

      final rawTracks = (raw['tracks']?['items'] as List<dynamic>?) ?? const [];
      final rawAlbums = (raw['albums']?['items'] as List<dynamic>?) ?? const [];
      final rawArtists =
          (raw['artists']?['items'] as List<dynamic>?) ?? const [];
      final rawPlaylists =
          (raw['playlists']?['items'] as List<dynamic>?) ?? const [];

      final tracks = <Song>[];
      for (final item in rawTracks) {
        if (item is Map<String, dynamic>) {
          tracks.add(TidalService.makeEphemeralSong(server, item));
        }
      }

      state = TidalSearchResults(
        tracks: tracks,
        albums: TidalAlbumDeduplication.deduplicate(
          rawAlbums.whereType<Map<String, dynamic>>().toList(),
        ),
        artists: rawArtists.whereType<Map<String, dynamic>>().toList(),
        playlists: rawPlaylists.whereType<Map<String, dynamic>>().toList(),
        isLoading: false,
        error: null,
        query: query,
      );
    } catch (e) {
      if (myGen != _searchGen) return;
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Clear the current search results and any pending search timer.
  void clear() {
    _debounceTimer?.cancel();
    _searchGen++; // invalidate any in-flight search
    state = TidalSearchResults.empty;
  }
}

/// Fetches the authenticated user's TIDAL playlists.
final tidalUserPlaylistsProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final server = await ref.watch(tidalServerProvider.future);
  if (server == null || server.token == null || server.token!.isEmpty) {
    return const [];
  }
  // Serve from TTL cache when fresh — avoids re-hitting the API on every
  // Hub visit and keeps us clear of TIDAL's rate limits.
  final cached = _playlistsCache.get(_userPlaylistsCacheKey);
  if (cached != null) return cached;
  final tidal = ref.read(tidalServiceProvider);
  final result = await tidal.getUserPlaylists(server);
  _playlistsCache.set(_userPlaylistsCacheKey, result);
  return result;
});

/// Cache-coherent wrapper around TIDAL playlist mutations.
///
/// The TTL cache sits *in front of* [tidalUserPlaylistsProvider]'s builder, so
/// invalidating only the provider would rebuild it straight back into the
/// same cached list. Every successful write therefore drops the playlist TTL
/// entry as well as the provider state, making the next read hit the API.
class TidalPlaylistMutations {
  TidalPlaylistMutations(this._ref);

  final Ref _ref;

  Future<Map<String, dynamic>> createPlaylist(
    NetworkServerEntity server, {
    required String title,
    String description = '',
  }) async {
    final created = await _ref
        .read(tidalServiceProvider)
        .createPlaylist(server, title: title, description: description);
    _invalidate(
      playlistId:
          created['id']?.toString() ?? created['uuid']?.toString() ?? '',
    );
    return created;
  }

  Future<bool> deletePlaylist(
    NetworkServerEntity server,
    String playlistId,
  ) async {
    final deleted = await _ref
        .read(tidalServiceProvider)
        .deletePlaylist(server, playlistId);
    if (deleted) _invalidate(playlistId: playlistId);
    return deleted;
  }

  Future<void> addTrackToPlaylist(
    NetworkServerEntity server, {
    required String playlistId,
    required String trackId,
  }) async {
    await _ref
        .read(tidalServiceProvider)
        .addTrackToPlaylist(server, playlistId: playlistId, trackId: trackId);
    _invalidate(playlistId: playlistId);
  }

  Future<void> addTracksToPlaylist(
    NetworkServerEntity server, {
    required String playlistId,
    required List<String> trackIds,
  }) async {
    if (trackIds.isEmpty) return;
    await _ref
        .read(tidalServiceProvider)
        .addTracksToPlaylist(
          server,
          playlistId: playlistId,
          trackIds: trackIds,
        );
    _invalidate(playlistId: playlistId);
  }

  /// Explicit user refresh (pull-to-refresh / refresh button).
  ///
  /// Bypasses the TTL entry by design: a manual refresh is a request for
  /// fresh data, so it must never be answered from cache.
  Future<List<Map<String, dynamic>>> refreshUserPlaylists() {
    invalidateTidalPlaylistsCache();
    return _ref.refresh(tidalUserPlaylistsProvider.future);
  }

  void _invalidate({required String playlistId}) {
    invalidateTidalPlaylistsCache();
    _ref.invalidate(tidalUserPlaylistsProvider);
    if (playlistId.isNotEmpty) {
      _ref.invalidate(tidalPlaylistDetailsProvider(playlistId));
    }
  }
}

final tidalPlaylistMutationsProvider = Provider<TidalPlaylistMutations>(
  (ref) => TidalPlaylistMutations(ref),
);

/// TIDAL browse-detail providers are autoDispose: their payloads are large
/// (album/playlist/artist/mix track lists, raw home-feed item maps, the
/// paginated liked-songs collection), and under Riverpod's keepAlive default
/// every visited screen retained its payload for the whole process lifetime
/// (~5-20 MB per heavy browsing session, growing unboundedly).
///
/// Safety of the disposal:
/// - Every watcher is screen-local: TIDAL detail screens (album/playlist/
///   artist/mix), the Hub's Consumer tiles for feed + liked songs, and the
///   liked-songs screen. Pushed routes release their watch on pop, so the
///   instance builds again on the next visit.
/// - Non-screen references only `ref.invalidate`/`ref.refresh` (safe on
///   autoDispose providers): the add-to-playlist sheet, the Hub's
///   RefreshIndicator/sign-out handlers, and favorites_provider (itself
///   autoDispose, and it never watches this file's providers).
/// - Revisits re-fetch; the Hub TTL caches (_homeFeedCache/_playlistsCache)
///   absorb the cost within their window, `_homeFeedCache` for the feed.
///
/// Deliberately ONLY the Riverpod state is dropped here — the image cache
/// system is NOT touched (changing it alongside autoDispose previously broke
/// cover loading; see the progressive-slowdown Tier 3 notes).
///
/// Fetches album details and tracks for a given album ID.
final tidalAlbumDetailsProvider = FutureProvider.autoDispose
    .family<({Map<String, dynamic> album, List<Song> tracks}), String>((
      ref,
      albumId,
    ) async {
      final server = await ref.watch(tidalServerProvider.future);
      if (server == null) {
        throw StateError('Tidal server not found');
      }
      final tidal = ref.read(tidalServiceProvider);
      // Fetch album metadata and tracks in parallel — they're independent.
      final results = await Future.wait([
        tidal.getAlbum(server, albumId),
        tidal.getAlbumTracks(server, albumId),
      ]);
      final album = results[0] as Map<String, dynamic>;
      final rawTracks = results[1] as List;
      final tracks = rawTracks.map((t) {
        final trackMap = Map<String, dynamic>.from(t);
        if (trackMap['album'] == null && album.isNotEmpty) {
          trackMap['album'] = album;
        }
        return TidalService.makeEphemeralSong(server, trackMap);
      }).toList();
      return (album: album, tracks: tracks);
    });

/// Fetches playlist details and tracks for a given playlist UUID.
final tidalPlaylistDetailsProvider = FutureProvider.autoDispose
    .family<({Map<String, dynamic> playlist, List<Song> tracks}), String>((
      ref,
      playlistId,
    ) async {
      final server = await ref.watch(tidalServerProvider.future);
      if (server == null) {
        throw StateError('Tidal server not found');
      }
      final tidal = ref.read(tidalServiceProvider);
      // Fetch playlist metadata and tracks in parallel — they're independent.
      final results = await Future.wait([
        tidal.getPlaylist(server, playlistId),
        tidal.getPlaylistTracks(server, playlistId),
      ]);
      final playlist = results[0] as Map<String, dynamic>;
      final rawTracks = results[1] as List;
      final tracks = rawTracks
          .map((t) => TidalService.makeEphemeralSong(server, t))
          .toList();
      return (playlist: playlist, tracks: tracks);
    });

/// Fetches artist details, top tracks, albums, singles & EPs, and compilations for a given artist ID.
final tidalArtistDetailsProvider = FutureProvider.autoDispose
    .family<
      ({
        Map<String, dynamic> artist,
        List<Song> topTracks,
        List<Map<String, dynamic>> albums,
        List<Map<String, dynamic>> singlesAndEPs,
        List<Map<String, dynamic>> compilations,
      }),
      String
    >((ref, artistId) async {
      final server = await ref.watch(tidalServerProvider.future);
      if (server == null) {
        throw StateError('Tidal server not found');
      }
      final tidal = ref.read(tidalServiceProvider);

      // Fetch all sections in parallel for faster loading.
      final results = await Future.wait([
        tidal.getArtist(server, artistId),
        tidal.getArtistTopTracks(server, artistId),
        tidal.getArtistAlbums(server, artistId),
        tidal.getArtistAlbums(server, artistId, filter: 'EPSANDSINGLES'),
        tidal.getArtistAlbums(server, artistId, filter: 'COMPILATIONS'),
      ]);

      final artist = results[0] as Map<String, dynamic>;
      final rawTopTracks = results[1] as List<Map<String, dynamic>>;
      final topTracks = rawTopTracks
          .map((t) => TidalService.makeEphemeralSong(server, t))
          .toList();
      final albums = results[2] as List<Map<String, dynamic>>;
      final singlesAndEPs = results[3] as List<Map<String, dynamic>>;
      final compilations = results[4] as List<Map<String, dynamic>>;

      return (
        artist: artist,
        topTracks: topTracks,
        albums: TidalAlbumDeduplication.deduplicate(albums),
        singlesAndEPs: TidalAlbumDeduplication.deduplicate(singlesAndEPs),
        compilations: TidalAlbumDeduplication.deduplicate(compilations),
      );
    });

/// Fetches an artist's full releases for the "Other versions" and
/// "More from `artist`" rails on the TIDAL album screen.
final tidalArtistAlbumsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, artistId) async {
      final server = await ref.watch(tidalServerProvider.future);
      if (server == null) {
        throw StateError('Tidal server not found');
      }
      final tidal = ref.read(tidalServiceProvider);
      final results = await Future.wait([
        tidal.getArtistAlbums(server, artistId, limit: 50),
        tidal.getArtistAlbums(
          server,
          artistId,
          filter: 'EPSANDSINGLES',
          limit: 50,
        ),
      ]);
      final albums = results[0];
      final singles = results[1];
      return [...albums, ...singles];
    });

/// Fetches an artist's biography text (TIDAL v2), or null when unavailable.
///
/// The bio is decorative, so a missing biography or any transport failure
/// resolves to null and the screen simply skips the section.
final tidalArtistBioProvider = FutureProvider.autoDispose
    .family<String?, String>((ref, artistId) async {
      final server = await ref.watch(tidalServerProvider.future);
      if (server == null) return null;
      return ref.read(tidalServiceProvider).getArtistBio(server, artistId);
    });

/// Fetches the official TIDAL home feed for a given vibe/category slug (e.g. 'static', 'relax', 'workout').
final tidalHomeFeedProvider = FutureProvider.autoDispose
    .family<TidalHomeFeed, String>((ref, feedSlug) async {
      final server = await ref.watch(tidalServerProvider.future);
      if (server == null || server.token == null || server.token!.isEmpty) {
        return TidalHomeFeed.empty;
      }
      // Serve from TTL cache when fresh — avoids re-hitting the API on every
      // Hub visit and keeps us clear of TIDAL's rate limits.
      final cached = _homeFeedCache.get(feedSlug);
      if (cached != null) return cached;
      final tidal = ref.read(tidalServiceProvider);
      final result = await tidal.getHomeFeed(server, feedSlug: feedSlug);
      _homeFeedCache.set(feedSlug, result);
      return result;
    });

/// Fetches details and tracks for a given TIDAL mix or radio station ID.
final tidalMixDetailsProvider = FutureProvider.autoDispose
    .family<TidalMix, String>((ref, mixId) async {
      final server = await ref.watch(tidalServerProvider.future);
      if (server == null) {
        throw StateError('Tidal server not found');
      }
      final tidal = ref.read(tidalServiceProvider);
      return await tidal.getMix(server, mixId);
    });

/// Local optimistic adjustments to TIDAL favorite track IDs (added/removed).
class TidalFavoriteTrackIdsOptimisticNotifier
    extends Notifier<({Set<String> added, Set<String> removed})> {
  @override
  ({Set<String> added, Set<String> removed}) build() =>
      (added: const <String>{}, removed: const <String>{});

  void add(String id) {
    state = (
      added: {...state.added, id},
      removed: state.removed.where((x) => x != id).toSet(),
    );
  }

  void remove(String id) {
    state = (
      added: state.added.where((x) => x != id).toSet(),
      removed: {...state.removed, id},
    );
  }

  /// Clears all optimistic adjustments (e.g. on sign-out / account switch).
  void clear() {
    state = (added: const <String>{}, removed: const <String>{});
  }
}

final tidalFavoriteTrackIdsOptimisticProvider =
    NotifierProvider<
      TidalFavoriteTrackIdsOptimisticNotifier,
      ({Set<String> added, Set<String> removed})
    >(TidalFavoriteTrackIdsOptimisticNotifier.new);

/// Fetches the set of favorite track IDs for the authenticated TIDAL account,
/// merged with local optimistic additions and removals for real-time updates.
final tidalFavoriteTrackIdsProvider = FutureProvider<Set<String>>((ref) async {
  final server = await ref.watch(tidalServerProvider.future);
  if (server == null || server.token == null || server.token!.isEmpty) {
    return const <String>{};
  }
  final tidal = ref.read(tidalServiceProvider);
  final remoteIds = await tidal.getFavoriteTrackIds(server);

  final optimistic = ref.watch(tidalFavoriteTrackIdsOptimisticProvider);
  if (optimistic.added.isEmpty && optimistic.removed.isEmpty) {
    return remoteIds;
  }

  final result = Set<String>.from(remoteIds);
  result.addAll(optimistic.added);
  result.removeAll(optimistic.removed);
  return result;
});

/// Local optimistic adjustments to TIDAL Liked Songs collection.
class TidalLikedSongsOptimisticNotifier
    extends Notifier<({List<Song> added, Set<String> removed})> {
  @override
  ({List<Song> added, Set<String> removed}) build() =>
      (added: const <Song>[], removed: const <String>{});

  void add(Song song) {
    state = (
      added: [
        song,
        ...state.added.where(
          (s) => s.id != song.id && s.remoteId != song.remoteId,
        ),
      ],
      removed: state.removed
          .where((id) => id != song.id && id != song.remoteId)
          .toSet(),
    );
  }

  void remove(String trackId) {
    state = (
      added: state.added
          .where(
            (s) =>
                s.id != trackId &&
                s.remoteId != trackId &&
                !s.id.endsWith('_$trackId'),
          )
          .toList(),
      removed: {...state.removed, trackId},
    );
  }

  /// Clears all optimistic adjustments (e.g. on sign-out / account switch).
  void clear() {
    state = (added: const <Song>[], removed: const <String>{});
  }
}

final tidalLikedSongsOptimisticProvider =
    NotifierProvider<
      TidalLikedSongsOptimisticNotifier,
      ({List<Song> added, Set<String> removed})
    >(TidalLikedSongsOptimisticNotifier.new);

/// Local optimistic adjustments to TIDAL favorite artist IDs (followed and
/// unfollowed artists), mirroring the track-favorites pattern so the Follow
/// capsule reacts instantly while the network call runs in the background.
class TidalFavoriteArtistIdsOptimisticNotifier
    extends Notifier<({Set<String> added, Set<String> removed})> {
  @override
  ({Set<String> added, Set<String> removed}) build() =>
      (added: const <String>{}, removed: const <String>{});

  void add(String id) {
    state = (
      added: {...state.added, id},
      removed: state.removed.where((x) => x != id).toSet(),
    );
  }

  void remove(String id) {
    state = (
      added: state.added.where((x) => x != id).toSet(),
      removed: {...state.removed, id},
    );
  }

  /// Clears all optimistic adjustments (e.g. on sign-out / account switch).
  void clear() {
    state = (added: const <String>{}, removed: const <String>{});
  }
}

final tidalFavoriteArtistIdsOptimisticProvider =
    NotifierProvider<
      TidalFavoriteArtistIdsOptimisticNotifier,
      ({Set<String> added, Set<String> removed})
    >(TidalFavoriteArtistIdsOptimisticNotifier.new);

String? _tidalCollectionItemId(Map<String, dynamic> item) {
  final id = item['id']?.toString();
  return id == null || id.isEmpty ? null : id;
}

/// Local optimistic adjustments to loved TIDAL albums.
class TidalLikedAlbumsOptimisticNotifier
    extends
        Notifier<({List<Map<String, dynamic>> added, Set<String> removed})> {
  @override
  ({List<Map<String, dynamic>> added, Set<String> removed}) build() =>
      (added: const <Map<String, dynamic>>[], removed: const <String>{});

  void add(Map<String, dynamic> album) {
    final id = _tidalCollectionItemId(album);
    if (id == null) return;
    state = (
      added: [
        album,
        ...state.added.where((item) => _tidalCollectionItemId(item) != id),
      ],
      removed: state.removed.where((itemId) => itemId != id).toSet(),
    );
  }

  void remove(String id) {
    state = (
      added: state.added
          .where((item) => _tidalCollectionItemId(item) != id)
          .toList(),
      removed: {...state.removed, id},
    );
  }

  void clear() {
    state = (added: const <Map<String, dynamic>>[], removed: const <String>{});
  }
}

final tidalLikedAlbumsOptimisticProvider =
    NotifierProvider<
      TidalLikedAlbumsOptimisticNotifier,
      ({List<Map<String, dynamic>> added, Set<String> removed})
    >(TidalLikedAlbumsOptimisticNotifier.new);

/// Fetches the set of followed (favorite) artist IDs for the authenticated
/// TIDAL account, merged with local optimistic additions and removals for
/// real-time updates.
final tidalFavoriteArtistIdsProvider = FutureProvider<Set<String>>((ref) async {
  final server = await ref.watch(tidalServerProvider.future);
  if (server == null || server.token == null || server.token!.isEmpty) {
    return const <String>{};
  }
  final tidal = ref.read(tidalServiceProvider);
  final remoteIds = await tidal.getFavoriteArtistIds(server);

  final optimistic = ref.watch(tidalFavoriteArtistIdsOptimisticProvider);
  if (optimistic.added.isEmpty && optimistic.removed.isEmpty) {
    return remoteIds;
  }

  final result = Set<String>.from(remoteIds);
  result.addAll(optimistic.added);
  result.removeAll(optimistic.removed);
  return result;
});

/// Whether the given TIDAL artist is followed by the account, including
/// optimistic adjustments.
final tidalArtistFollowedProvider = Provider.autoDispose.family<bool, String>((
  ref,
  artistId,
) {
  final optimistic = ref.watch(tidalFavoriteArtistIdsOptimisticProvider);
  if (optimistic.added.contains(artistId)) return true;
  if (optimistic.removed.contains(artistId)) return false;
  return ref.watch(tidalFavoriteArtistIdsProvider).value?.contains(artistId) ??
      false;
});

/// Full loved-album collection, merged with optimistic album love changes.
final tidalLikedAlbumsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      final server = await ref.watch(tidalServerProvider.future);
      if (server == null || server.token == null || server.token!.isEmpty) {
        return const <Map<String, dynamic>>[];
      }
      final remote = await ref
          .read(tidalServiceProvider)
          .getFavoriteAlbums(server);
      final optimistic = ref.watch(tidalLikedAlbumsOptimisticProvider);
      final result = <Map<String, dynamic>>[...optimistic.added];
      for (final album in remote) {
        final id = _tidalCollectionItemId(album);
        if (id == null || optimistic.removed.contains(id)) continue;
        if (!result.any((item) => _tidalCollectionItemId(item) == id)) {
          result.add(album);
        }
      }
      return result;
    });

/// Whether an album is loved, including optimistic updates.
final tidalAlbumLovedProvider = Provider.autoDispose.family<bool, String>((
  ref,
  albumId,
) {
  final optimistic = ref.watch(tidalLikedAlbumsOptimisticProvider);
  if (optimistic.added.any(
    (album) => _tidalCollectionItemId(album) == albumId,
  )) {
    return true;
  }
  if (optimistic.removed.contains(albumId)) return false;
  return ref
          .watch(tidalLikedAlbumsProvider)
          .value
          ?.any((album) => _tidalCollectionItemId(album) == albumId) ??
      false;
});

/// Full followed-artist collection, merged with optimistic follow changes.
final tidalLikedArtistsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      final server = await ref.watch(tidalServerProvider.future);
      if (server == null || server.token == null || server.token!.isEmpty) {
        return const <Map<String, dynamic>>[];
      }
      final remote = await ref
          .read(tidalServiceProvider)
          .getFavoriteArtists(server);
      final optimistic = ref.watch(tidalFavoriteArtistIdsOptimisticProvider);
      final result = <Map<String, dynamic>>[];
      for (final artist in remote) {
        final id = _tidalCollectionItemId(artist);
        if (id != null && !optimistic.removed.contains(id)) result.add(artist);
      }
      final knownIds = result
          .map(_tidalCollectionItemId)
          .whereType<String>()
          .toSet();
      for (final id in optimistic.added.difference(knownIds)) {
        try {
          result.add(
            await ref.read(tidalServiceProvider).getArtist(server, id),
          );
        } catch (_) {
          // Keep the followed artist visible even if metadata temporarily fails.
          result.add({'id': id, 'name': 'Unknown Artist'});
        }
      }
      return result;
    });

/// Fetches the full TIDAL "Liked Songs" collection (favorite tracks with
/// metadata) for the authenticated account, merged with local optimistic updates
/// so newly loved tracks appear immediately.
final tidalLikedSongsProvider = FutureProvider.autoDispose<List<Song>>((
  ref,
) async {
  final server = await ref.watch(tidalServerProvider.future);
  if (server == null || server.token == null || server.token!.isEmpty) {
    return const <Song>[];
  }
  final tidal = ref.read(tidalServiceProvider);
  final remoteSongs = await tidal.getFavoriteTracks(server);

  final optimistic = ref.watch(tidalLikedSongsOptimisticProvider);
  if (optimistic.added.isEmpty && optimistic.removed.isEmpty) {
    return remoteSongs;
  }

  final result = <Song>[...optimistic.added];
  for (final s in remoteSongs) {
    if (optimistic.removed.contains(s.id) ||
        (s.remoteId != null && optimistic.removed.contains(s.remoteId))) {
      continue;
    }
    if (!result.any(
      (r) => r.id == s.id || (s.remoteId != null && r.remoteId == s.remoteId),
    )) {
      result.add(s);
    }
  }
  return result;
});
