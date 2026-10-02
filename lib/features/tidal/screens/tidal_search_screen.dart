import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/constants/app_constants.dart';
import '../../../widgets/common/blurred_song_background.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/duration_format.dart';
import '../../../core/utils/navigation_helper.dart';
import '../../../core/utils/responsive.dart';
import '../../../models/song.dart';
import '../../../services/player_service.dart';
import '../../../services/sources/tidal_service.dart';
import '../../../widgets/common/cached_image_widget.dart';
import '../../../widgets/common/flick_artwork_placeholder.dart';
import '../../../widgets/common/glass_search_bar.dart';
import '../providers/tidal_providers.dart';
import '../../songs/widgets/song_actions_bottom_sheet.dart';
import 'tidal_album_screen.dart';
import 'tidal_artist_screen.dart';
import 'tidal_playlist_screen.dart';

enum TidalSearchCategory {
  all('All'),
  tracks('Tracks'),
  albums('Albums'),
  artists('Artists'),
  playlists('Playlists');

  final String label;
  const TidalSearchCategory(this.label);
}

class TidalSearchScreen extends ConsumerStatefulWidget {
  const TidalSearchScreen({super.key});

  @override
  ConsumerState<TidalSearchScreen> createState() => _TidalSearchScreenState();
}

class _TidalSearchScreenState extends ConsumerState<TidalSearchScreen> {
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();
  TidalSearchCategory _selectedCategory = TidalSearchCategory.all;

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    ref.read(tidalSearchProvider.notifier).search(query);
  }

  void _onClear() {
    _searchController.clear();
    ref.read(tidalSearchProvider.notifier).clear();
  }

  void _playSong(Song song, List<Song> playlist) {
    PlayerService().play(song, playlist: playlist);
    NavigationHelper.navigateToFullPlayer(
      context,
      heroTag: 'tidal_search_song_${song.id}',
    );
  }

  void _openAlbum(Map<String, dynamic> album) {
    final albumId = album['id']?.toString();
    if (albumId == null) return;
    NavigationHelper.pushFade(
      context,
      (_) => TidalAlbumScreen(albumId: albumId, initialAlbumData: album),
    );
  }

  void _openArtist(Map<String, dynamic> artist) {
    final artistId = artist['id']?.toString();
    if (artistId == null) return;
    NavigationHelper.pushFade(
      context,
      (_) => TidalArtistScreen(artistId: artistId, initialArtistData: artist),
    );
  }

  void _openPlaylist(Map<String, dynamic> playlist) {
    final playlistId =
        playlist['uuid']?.toString() ?? playlist['id']?.toString();
    if (playlistId == null) return;
    final image =
        (playlist['image'] as String?) ?? (playlist['squareImage'] as String?);
    final imageUrl = (image != null && image.isNotEmpty)
        ? TidalService.coverUrl(image, size: 640)
        : null;
    NavigationHelper.pushFade(
      context,
      (_) => TidalPlaylistScreen(
        playlistId: playlistId,
        initialTitle: playlist['title'] as String?,
        initialImageUrl: (imageUrl != null && imageUrl.isNotEmpty)
            ? imageUrl
            : null,
        initialTrackCount:
            ((playlist['numberOfTracks'] ?? playlist['numberOfItems']) as num?)
                ?.toInt(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // NOTE: tidalSearchProvider is watched inside the results Consumer
    // below (not here) so typing a query doesn't rebuild the whole
    // screen (background, app bar, search bar, chips) on every keystroke.
    return BlurredSongBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(
              LucideIcons.arrowLeft,
              color: AppColors.textPrimary,
            ),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: const Text(
            'TIDAL Search',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        body: Column(
          children: [
            // Search input — wrapped in RepaintBoundary so blinking cursor does not repaint results
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.scaleSize(AppConstants.spacingMd),
                vertical: context.scaleSize(AppConstants.spacingSm),
              ),
              child: RepaintBoundary(
                child: GlassSearchBar(
                  controller: _searchController,
                  focusNode: _focusNode,
                  autofocus: true,
                  useFilter: false,
                  hintText: 'Search songs, albums, artists...',
                  onChanged: _onSearchChanged,
                  onClear: _onClear,
                ),
              ),
            ),
            // Category filter chips — lightweight glass container without GPU BackdropFilter
            RepaintBoundary(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(
                  horizontal: context.scaleSize(AppConstants.spacingMd),
                  vertical: context.scaleSize(AppConstants.spacingXs),
                ),
                child: Row(
                  children: TidalSearchCategory.values.map((cat) {
                    final isSelected = _selectedCategory == cat;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(cat.label),
                        selected: isSelected,
                        onSelected: (_) =>
                            setState(() => _selectedCategory = cat),
                        backgroundColor: AppColors.glassBackgroundStrong,
                        selectedColor: const Color(0x3300FFFF),
                        labelStyle: TextStyle(
                          color: isSelected
                              ? const Color(0xFF00FFFF)
                              : AppColors.textPrimary,
                          fontSize: 12,
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.w500,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            AppConstants.radiusRound,
                          ),
                          side: BorderSide(
                            color: isSelected
                                ? const Color(0xFF00FFFF)
                                : AppColors.glassBorder,
                            width: 1,
                          ),
                        ),
                        showCheckmark: false,
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
            // Content — isolated Consumer wrapped in RepaintBoundary so query typing
            // and results rendering never dirty the search bar or app bar.
            Expanded(
              child: RepaintBoundary(
                child: Consumer(
                  builder: (context, ref, _) {
                    final searchResults = ref.watch(tidalSearchProvider);
                    return _buildResultsView(searchResults);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultsView(TidalSearchResults results) {
    if (results.isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.accent),
      );
    }

    if (results.error != null) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(context.scaleSize(AppConstants.spacingLg)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                LucideIcons.circleAlert,
                size: 48,
                color: AppColors.textSecondary,
              ),
              SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
              Text(
                results.error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      );
    }

    if (results.query.isEmpty) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(context.scaleSize(AppConstants.spacingLg)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                LucideIcons.waves,
                size: context.scaleSize(56),
                color: AppColors.textSecondary.withValues(alpha: 0.5),
              ),
              SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
              const Text(
                'Search TIDAL Catalog',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: context.scaleSize(AppConstants.spacingXs)),
              const Text(
                'Instant bit-perfect playback from millions of tracks.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    if (results.isEmpty) {
      return Center(
        child: Text(
          'No results found for "${results.query}"',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
      );
    }

    switch (_selectedCategory) {
      case TidalSearchCategory.tracks:
        return _buildTracksList(results.tracks);
      case TidalSearchCategory.albums:
        return _buildAlbumsGrid(results.albums);
      case TidalSearchCategory.artists:
        return _buildArtistsList(results.artists);
      case TidalSearchCategory.playlists:
        return _buildPlaylistsList(results.playlists);
      case TidalSearchCategory.all:
        return _buildAllResults(results);
    }
  }

  Widget _buildAllResults(TidalSearchResults results) {
    return ListView(
      padding: EdgeInsets.symmetric(
        horizontal: context.scaleSize(AppConstants.spacingMd),
        vertical: context.scaleSize(AppConstants.spacingSm),
      ),
      children: [
        if (results.tracks.isNotEmpty) ...[
          _buildSectionHeader('Tracks (${results.tracks.length})'),
          ...results.tracks
              .take(6)
              .map((song) => _buildTrackTile(song, results.tracks)),
          SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
        ],
        if (results.albums.isNotEmpty) ...[
          _buildSectionHeader('Albums (${results.albums.length})'),
          SizedBox(
            height: context.scaleSize(175),
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: results.albums.length,
              itemBuilder: (context, index) {
                final album = results.albums[index];
                return _buildAlbumCard(album);
              },
            ),
          ),
          SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
        ],
        if (results.artists.isNotEmpty) ...[
          _buildSectionHeader('Artists (${results.artists.length})'),
          SizedBox(
            height: context.scaleSize(120),
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: results.artists.length,
              itemBuilder: (context, index) {
                final artist = results.artists[index];
                return _buildArtistCard(artist);
              },
            ),
          ),
          SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
        ],
        if (results.playlists.isNotEmpty) ...[
          _buildSectionHeader('Playlists (${results.playlists.length})'),
          SizedBox(
            height: context.scaleSize(160),
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: results.playlists.length,
              itemBuilder: (context, index) {
                final pl = results.playlists[index];
                return _buildPlaylistCard(pl);
              },
            ),
          ),
        ],
        SizedBox(height: context.scaleSize(AppConstants.spacingXl * 2)),
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: context.scaleSize(AppConstants.spacingXs),
      ),
      child: Text(
        title,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildTrackTile(Song song, List<Song> playlist) {
    final thumbSize = context.scaleSize(48);
    final thumbArt = TidalService.resizedCoverUrl(song.albumArt, 160);

    return RepaintBoundary(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(AppConstants.radiusSm),
          child: SizedBox(
            width: thumbSize,
            height: thumbSize,
            child: thumbArt != null
                ? CachedImageWidget(
                    imagePath: thumbArt,
                    audioSourcePath: song.filePath,
                    width: thumbSize,
                    height: thumbSize,
                    useThumbnail: true,
                    thumbnailWidth: 160,
                    thumbnailHeight: 160,
                    fit: BoxFit.cover,
                    placeholder: const FlickArtworkPlaceholder(),
                    errorWidget: const FlickArtworkPlaceholder(),
                  )
                : const FlickArtworkPlaceholder(),
          ),
        ),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Row(
        children: [
          if (song.sampleRate != null && song.sampleRate! > 48000)
            Container(
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0x33E5A93C),
                borderRadius: BorderRadius.circular(3),
              ),
              child: const Text(
                '24-BIT',
                style: TextStyle(
                  color: Color(0xFFE5A93C),
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          Expanded(
            child: Text(
              [song.artist, if (song.album != null) song.album!].join(' • '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            formatDuration(song.duration),
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          IconButton(
            icon: const Icon(
              LucideIcons.ellipsisVertical,
              size: 18,
              color: AppColors.textSecondary,
            ),
            onPressed: () => SongActionsBottomSheet.show(context, song),
          ),
        ],
      ),
      onTap: () => _playSong(song, playlist),
      ),
    );
  }

  Widget _buildTracksList(List<Song> tracks) {
    return ListView.builder(
      padding: EdgeInsets.symmetric(
        horizontal: context.scaleSize(AppConstants.spacingMd),
        vertical: context.scaleSize(AppConstants.spacingSm),
      ),
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        return _buildTrackTile(tracks[index], tracks);
      },
    );
  }

  Widget _buildAlbumCard(Map<String, dynamic> album) {
    final title = album['title'] as String? ?? 'Unknown Album';
    final artist =
        (album['artist'] as Map<String, dynamic>?)?['name'] as String? ??
        'Unknown Artist';
    final coverUuid = album['cover'] as String?;
    final coverUrl = coverUuid != null
        ? TidalService.coverUrl(coverUuid, size: 320)
        : null;
    final cardWidth = context.scaleSize(120);

    return RepaintBoundary(
      child: GestureDetector(
        onTap: () => _openAlbum(album),
        child: Container(
          width: cardWidth,
          margin: const EdgeInsets.only(right: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                child: SizedBox(
                  width: cardWidth,
                  height: cardWidth,
                  child: coverUrl != null
                      ? CachedImageWidget(
                          imagePath: coverUrl,
                          width: cardWidth,
                          height: cardWidth,
                          useThumbnail: true,
                          thumbnailWidth: 320,
                          thumbnailHeight: 320,
                          fit: BoxFit.cover,
                          placeholder: const FlickArtworkPlaceholder(),
                          errorWidget: const FlickArtworkPlaceholder(),
                        )
                      : const FlickArtworkPlaceholder(),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAlbumsGrid(List<Map<String, dynamic>> albums) {
    return GridView.builder(
      padding: EdgeInsets.all(context.scaleSize(AppConstants.spacingMd)),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.8,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: albums.length,
      itemBuilder: (context, index) {
        final album = albums[index];
        final title = album['title'] as String? ?? 'Unknown Album';
        final artist =
            (album['artist'] as Map<String, dynamic>?)?['name'] as String? ??
            'Unknown Artist';
        final coverUuid = album['cover'] as String?;
        final coverUrl = coverUuid != null
            ? TidalService.coverUrl(coverUuid, size: 320)
            : null;

        return RepaintBoundary(
          child: GestureDetector(
            onTap: () => _openAlbum(album),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: coverUrl != null
                          ? CachedImageWidget(
                              imagePath: coverUrl,
                              fit: BoxFit.cover,
                              useThumbnail: true,
                              thumbnailWidth: 320,
                              thumbnailHeight: 320,
                              placeholder: const FlickArtworkPlaceholder(),
                              errorWidget: const FlickArtworkPlaceholder(),
                            )
                          : const FlickArtworkPlaceholder(),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildArtistCard(Map<String, dynamic> artist) {
    final name = artist['name'] as String? ?? 'Unknown Artist';
    final picture = artist['picture'] as String?;
    final pictureUrl = picture != null
        ? TidalService.coverUrl(picture, size: 320)
        : null;
    final size = context.scaleSize(76);

    return RepaintBoundary(
      child: GestureDetector(
        onTap: () => _openArtist(artist),
        child: Container(
          width: size + 16,
          margin: const EdgeInsets.only(right: 8),
          child: Column(
            children: [
              ClipOval(
                child: SizedBox(
                  width: size,
                  height: size,
                  child: pictureUrl != null
                      ? CachedImageWidget(
                          imagePath: pictureUrl,
                          width: size,
                          height: size,
                          useThumbnail: true,
                          thumbnailWidth: 160,
                          thumbnailHeight: 160,
                          fit: BoxFit.cover,
                          placeholder: const FlickArtworkPlaceholder(),
                          errorWidget: const FlickArtworkPlaceholder(),
                        )
                      : const FlickArtworkPlaceholder(),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                name,
                maxLines: 1,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildArtistsList(List<Map<String, dynamic>> artists) {
    return ListView.builder(
      padding: EdgeInsets.symmetric(
        horizontal: context.scaleSize(AppConstants.spacingMd),
        vertical: context.scaleSize(AppConstants.spacingSm),
      ),
      itemCount: artists.length,
      itemBuilder: (context, index) {
        final artist = artists[index];
        final name = artist['name'] as String? ?? 'Unknown Artist';
        final picture = artist['picture'] as String?;
        final pictureUrl = picture != null
            ? TidalService.coverUrl(picture, size: 160)
            : null;
        final size = context.scaleSize(48);

        return RepaintBoundary(
          child: ListTile(
            onTap: () => _openArtist(artist),
            leading: ClipOval(
              child: SizedBox(
                width: size,
                height: size,
                child: pictureUrl != null
                    ? CachedImageWidget(
                        imagePath: pictureUrl,
                        width: size,
                        height: size,
                        useThumbnail: true,
                        thumbnailWidth: 160,
                        thumbnailHeight: 160,
                        fit: BoxFit.cover,
                        placeholder: const FlickArtworkPlaceholder(),
                        errorWidget: const FlickArtworkPlaceholder(),
                      )
                    : const FlickArtworkPlaceholder(),
              ),
            ),
            title: Text(
              name,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlaylistCard(Map<String, dynamic> playlist) {
    final title = playlist['title'] as String? ?? 'Playlist';
    final image = playlist['image'] as String?;
    final coverUrl = (image != null && image.isNotEmpty)
        ? TidalService.coverUrl(image, size: 320)
        : null;
    // coverUrl returns '' for invalid UUIDs; treat as missing.
    final imageUrl = (coverUrl != null && coverUrl.isNotEmpty)
        ? coverUrl
        : null;
    final cardWidth = context.scaleSize(110);

    return RepaintBoundary(
      child: Container(
        width: cardWidth,
        margin: const EdgeInsets.only(right: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppConstants.radiusSm),
              child: SizedBox(
                width: cardWidth,
                height: cardWidth,
                child: imageUrl != null
                    ? CachedImageWidget(
                        imagePath: imageUrl,
                        width: cardWidth,
                        height: cardWidth,
                        useThumbnail: true,
                        thumbnailWidth: 320,
                        thumbnailHeight: 320,
                        fit: BoxFit.cover,
                        placeholder: const FlickArtworkPlaceholder(),
                        errorWidget: const FlickArtworkPlaceholder(),
                      )
                    : const FlickArtworkPlaceholder(),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaylistsList(List<Map<String, dynamic>> playlists) {
    return ListView.builder(
      padding: EdgeInsets.symmetric(
        horizontal: context.scaleSize(AppConstants.spacingMd),
        vertical: context.scaleSize(AppConstants.spacingSm),
      ),
      itemCount: playlists.length,
      itemBuilder: (context, index) {
        final pl = playlists[index];
        final title = pl['title'] as String? ?? 'Playlist';
        final trackCount =
            (pl['numberOfTracks'] ?? pl['numberOfItems']) as num?;
        final image =
            (pl['image'] as String?) ?? (pl['squareImage'] as String?);
        final imageUrl = (image != null && image.isNotEmpty)
            ? TidalService.coverUrl(image, size: 160)
            : null;
        final size = context.scaleSize(48);

        return RepaintBoundary(
          child: ListTile(
            onTap: () => _openPlaylist(pl),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(AppConstants.radiusSm),
              child: SizedBox(
                width: size,
                height: size,
                child: (imageUrl != null && imageUrl.isNotEmpty)
                    ? CachedImageWidget(
                        imagePath: imageUrl,
                        width: size,
                        height: size,
                        useThumbnail: true,
                        thumbnailWidth: 160,
                        thumbnailHeight: 160,
                        fit: BoxFit.cover,
                        placeholder: const FlickArtworkPlaceholder(),
                        errorWidget: const FlickArtworkPlaceholder(),
                      )
                    : const FlickArtworkPlaceholder(),
              ),
            ),
            title: Text(
              title,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            subtitle: trackCount != null
                ? Text(
                    '$trackCount tracks',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  )
                : null,
          ),
        );
      },
    );
  }
}
