import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar_community/isar.dart';

import '../../../data/database.dart';
import '../../../models/song.dart';
import '../../../models/sources/tidal_models.dart';
import '../../../services/sources/network_source_service.dart';
import '../../../services/sources/tidal_service.dart';

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

    _debounceTimer = Timer(debounce, () {
      performSearch(query);
    });
  }

  /// Immediately perform catalog search without debouncing.
  Future<void> performSearch(String query) async {
    final server = await ref.read(tidalServerProvider.future);
    if (server == null || server.token == null || server.token!.isEmpty) {
      state = state.copyWith(isLoading: false, error: 'Tidal is not signed in');
      return;
    }

    try {
      final tidal = ref.read(tidalServiceProvider);
      final raw = await tidal.searchCatalog(server, query);

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
        albums: rawAlbums.whereType<Map<String, dynamic>>().toList(),
        artists: rawArtists.whereType<Map<String, dynamic>>().toList(),
        playlists: rawPlaylists.whereType<Map<String, dynamic>>().toList(),
        isLoading: false,
        error: null,
        query: query,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Clear the current search results and any pending search timer.
  void clear() {
    _debounceTimer?.cancel();
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
  final tidal = ref.read(tidalServiceProvider);
  return tidal.getUserPlaylists(server);
});

/// Fetches the cover art URL for a playlist, falling back to the first track's album art
/// if the playlist itself has no custom cover image.
final tidalPlaylistCoverProvider = FutureProvider.family<String?, String>((
  ref,
  playlistId,
) async {
  if (playlistId.isEmpty) return null;
  final server = await ref.watch(tidalServerProvider.future);
  if (server == null || server.token == null || server.token!.isEmpty) {
    return null;
  }
  final tidal = ref.read(tidalServiceProvider);
  try {
    // 1. Try playlist metadata first (in case it contains squareImage or cover)
    try {
      final pl = await tidal.getPlaylist(server, playlistId);
      final direct = TidalService.extractPlaylistCover(pl);
      if (direct != null && direct.isNotEmpty) return direct;
    } catch (_) {}

    // 2. Fetch tracks (limit 5) to find the first track with album art
    final tracks = await tidal.getPlaylistTracks(server, playlistId, limit: 5);
    for (final t in tracks) {
      final song = TidalService.makeEphemeralSong(server, t);
      if (song.albumArt != null && song.albumArt!.isNotEmpty) {
        return song.albumArt;
      }
    }
    return null;
  } catch (_) {
    return null;
  }
});

/// Fetches the user's custom mixes & daily discovery (My Mix 1..8, Daily Discovery).
final tidalFavoriteMixesProvider = FutureProvider<List<TidalHomeItem>>((
  ref,
) async {
  final server = await ref.watch(tidalServerProvider.future);
  if (server == null || server.token == null || server.token!.isEmpty) {
    return const [];
  }
  final tidal = ref.read(tidalServiceProvider);
  return tidal.getFavoriteMixes(server);
});

/// Fetches album details and tracks for a given album ID.
final tidalAlbumDetailsProvider =
    FutureProvider.family<
      ({Map<String, dynamic> album, List<Song> tracks}),
      String
    >((ref, albumId) async {
      final server = await ref.watch(tidalServerProvider.future);
      if (server == null) {
        throw StateError('Tidal server not found');
      }
      final tidal = ref.read(tidalServiceProvider);
      final album = await tidal.getAlbum(server, albumId);
      final rawTracks = await tidal.getAlbumTracks(server, albumId);
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
final tidalPlaylistDetailsProvider =
    FutureProvider.family<
      ({Map<String, dynamic> playlist, List<Song> tracks}),
      String
    >((ref, playlistId) async {
      final server = await ref.watch(tidalServerProvider.future);
      if (server == null) {
        throw StateError('Tidal server not found');
      }
      final tidal = ref.read(tidalServiceProvider);
      final playlist = await tidal.getPlaylist(server, playlistId);
      final rawTracks = await tidal.getPlaylistTracks(server, playlistId);
      final tracks = rawTracks
          .map((t) => TidalService.makeEphemeralSong(server, t))
          .toList();
      return (playlist: playlist, tracks: tracks);
    });

/// Fetches artist details, top tracks, albums, singles & EPs, and compilations for a given artist ID.
final tidalArtistDetailsProvider =
    FutureProvider.family<
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
        albums: albums,
        singlesAndEPs: singlesAndEPs,
        compilations: compilations,
      );
    });

/// Fetches the official TIDAL home feed for a given vibe/category slug (e.g. 'static', 'relax', 'workout').
final tidalHomeFeedProvider = FutureProvider.family<TidalHomeFeed, String>((
  ref,
  feedSlug,
) async {
  final server = await ref.watch(tidalServerProvider.future);
  if (server == null || server.token == null || server.token!.isEmpty) {
    return TidalHomeFeed.empty;
  }
  final tidal = ref.read(tidalServiceProvider);
  return await tidal.getHomeFeed(server, feedSlug: feedSlug);
});

/// Fetches details and tracks for a given TIDAL mix or radio station ID.
final tidalMixDetailsProvider = FutureProvider.family<TidalMix, String>((
  ref,
  mixId,
) async {
  final server = await ref.watch(tidalServerProvider.future);
  if (server == null) {
    throw StateError('Tidal server not found');
  }
  final tidal = ref.read(tidalServiceProvider);
  return await tidal.getMix(server, mixId);
});

/// Fetches the set of favorite track IDs for the authenticated TIDAL account.
final tidalFavoriteTrackIdsProvider = FutureProvider<Set<String>>((ref) async {
  final server = await ref.watch(tidalServerProvider.future);
  if (server == null || server.token == null || server.token!.isEmpty) {
    return const <String>{};
  }
  final tidal = ref.read(tidalServiceProvider);
  return await tidal.getFavoriteTrackIds(server);
});
