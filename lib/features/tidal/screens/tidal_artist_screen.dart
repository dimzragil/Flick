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
import '../providers/tidal_providers.dart';
import '../../songs/widgets/song_actions_bottom_sheet.dart';
import 'tidal_album_screen.dart';

class TidalArtistScreen extends ConsumerStatefulWidget {
  final String artistId;
  final Map<String, dynamic>? initialArtistData;

  const TidalArtistScreen({
    super.key,
    required this.artistId,
    this.initialArtistData,
  });

  @override
  ConsumerState<TidalArtistScreen> createState() => _TidalArtistScreenState();
}

class _TidalArtistScreenState extends ConsumerState<TidalArtistScreen> {
  void _playSong(Song song, List<Song> playlist) {
    PlayerService().play(song, playlist: playlist);
    NavigationHelper.navigateToFullPlayer(
      context,
      heroTag: 'tidal_artist_song_${song.id}',
    );
  }

  void _playAll(List<Song> tracks) {
    if (tracks.isEmpty) return;
    PlayerService().play(tracks.first, playlist: tracks);
    NavigationHelper.navigateToFullPlayer(
      context,
      heroTag: 'tidal_artist_play_${widget.artistId}',
    );
  }

  void _shuffleAll(List<Song> tracks) {
    if (tracks.isEmpty) return;
    final shuffled = List<Song>.from(tracks)..shuffle();
    PlayerService().play(shuffled.first, playlist: shuffled);
    NavigationHelper.navigateToFullPlayer(
      context,
      heroTag: 'tidal_artist_shuffle_${widget.artistId}',
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

  @override
  Widget build(BuildContext context) {
    final artistAsync = ref.watch(tidalArtistDetailsProvider(widget.artistId));

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
          title: Text(
            artistAsync.value?.artist['name'] ??
                widget.initialArtistData?['name'] ??
                'Artist',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: artistAsync.when(
          loading: () => const Center(
            child: CircularProgressIndicator(color: AppColors.accent),
          ),
          error: (error, _) => Center(
            child: Padding(
              padding: EdgeInsets.all(
                context.scaleSize(AppConstants.spacingLg),
              ),
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
                    'Failed to load artist: $error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                  SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
                  ElevatedButton.icon(
                    onPressed: () => ref.refresh(
                      tidalArtistDetailsProvider(widget.artistId),
                    ),
                    icon: const Icon(LucideIcons.refreshCw, size: 16),
                    label: const Text('Retry'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      foregroundColor: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          data: (data) {
            final artist = data.artist;
            final topTracks = data.topTracks;
            final displayedTopTracks = topTracks.take(5).toList();
            final albums = data.albums;
            final singlesAndEPs = data.singlesAndEPs;
            final compilations = data.compilations;
            final name =
                (artist['name'] as String?) ??
                widget.initialArtistData?['name'] ??
                'Unknown Artist';
            final picture =
                (artist['picture'] as String?) ??
                widget.initialArtistData?['picture'] as String?;
            final pictureUrl = picture != null
                ? TidalService.coverUrl(picture, size: 640)
                : null;
            final avatarSize = context.scaleSize(140);

            return CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: context.scaleSize(AppConstants.spacingLg),
                      vertical: context.scaleSize(AppConstants.spacingMd),
                    ),
                    child: Column(
                      children: [
                        // Artist Picture
                        Center(
                          child: ClipOval(
                            child: SizedBox(
                              width: avatarSize,
                              height: avatarSize,
                              child: pictureUrl != null
                                  ? CachedImageWidget(
                                      imagePath: pictureUrl,
                                      width: avatarSize,
                                      height: avatarSize,
                                      fit: BoxFit.cover,
                                      placeholder:
                                          const FlickArtworkPlaceholder(),
                                      errorWidget:
                                          const FlickArtworkPlaceholder(),
                                    )
                                  : const FlickArtworkPlaceholder(),
                            ),
                          ),
                        ),
                        SizedBox(
                          height: context.scaleSize(AppConstants.spacingMd),
                        ),
                        // Artist Name
                        Text(
                          name,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(
                          height: context.scaleSize(AppConstants.spacingMd),
                        ),
                        // Action Buttons: Play All & Shuffle
                        if (topTracks.isNotEmpty)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              FilledButton.icon(
                                onPressed: () => _playAll(topTracks),
                                icon: const Icon(LucideIcons.play, size: 18),
                                label: const Text('Play All'),
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.accent,
                                  foregroundColor: Colors.white,
                                  padding: EdgeInsets.symmetric(
                                    horizontal: context.scaleSize(
                                      AppConstants.spacingLg,
                                    ),
                                    vertical: context.scaleSize(
                                      AppConstants.spacingSm,
                                    ),
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: context.scaleSize(
                                  AppConstants.spacingMd,
                                ),
                              ),
                              OutlinedButton.icon(
                                onPressed: () => _shuffleAll(topTracks),
                                icon: const Icon(LucideIcons.shuffle, size: 18),
                                label: const Text('Shuffle'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppColors.textPrimary,
                                  side: const BorderSide(
                                    color: AppColors.glassBorder,
                                  ),
                                  padding: EdgeInsets.symmetric(
                                    horizontal: context.scaleSize(
                                      AppConstants.spacingLg,
                                    ),
                                    vertical: context.scaleSize(
                                      AppConstants.spacingSm,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        if (topTracks.isNotEmpty) ...[
                          SizedBox(
                            height: context.scaleSize(AppConstants.spacingLg),
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Top Tracks',
                              style: TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: context.scaleSize(18),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          SizedBox(
                            height: context.scaleSize(AppConstants.spacingSm),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                // Top Tracks List
                if (topTracks.isNotEmpty)
                  SliverPadding(
                    padding: EdgeInsets.symmetric(
                      horizontal: context.scaleSize(AppConstants.spacingMd),
                    ),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final song = displayedTopTracks[index];
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: context.scaleSize(
                              AppConstants.spacingSm,
                            ),
                            vertical: 2,
                          ),
                          leading: SizedBox(
                            width: 28,
                            child: Center(
                              child: Text(
                                '${index + 1}',
                                style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 13,
                                ),
                              ),
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
                              if ((song.bitDepth ?? 0) >= 24)
                                Container(
                                  margin: const EdgeInsets.only(right: 6),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black,
                                    borderRadius: BorderRadius.circular(3),
                                    border: Border.all(
                                      color: const Color(0xFFE5A93C),
                                      width: 0.75,
                                    ),
                                  ),
                                  child: const Text(
                                    'Hi-Res',
                                    style: TextStyle(
                                      color: Color(0xFFE5A93C),
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              Expanded(
                                child: Text(
                                  song.album ?? song.artist,
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
                                onPressed: () =>
                                    SongActionsBottomSheet.show(context, song),
                              ),
                            ],
                          ),
                          onTap: () => _playSong(song, topTracks),
                        );
                      }, childCount: displayedTopTracks.length),
                    ),
                  ),

                // Albums Section (Horizontal Carousel)
                if (albums.isNotEmpty)
                  SliverToBoxAdapter(
                    child: _buildHorizontalReleaseSection(
                      context,
                      title: 'Albums',
                      items: albums,
                    ),
                  ),

                // Singles & EPs Section (Horizontal Carousel)
                if (singlesAndEPs.isNotEmpty)
                  SliverToBoxAdapter(
                    child: _buildHorizontalReleaseSection(
                      context,
                      title: 'Singles & EPs',
                      items: singlesAndEPs,
                    ),
                  ),

                // Compilations Section (Horizontal Carousel)
                if (compilations.isNotEmpty)
                  SliverToBoxAdapter(
                    child: _buildHorizontalReleaseSection(
                      context,
                      title: 'Compilations',
                      items: compilations,
                    ),
                  ),

                SliverToBoxAdapter(
                  child: SizedBox(
                    height: context.scaleSize(AppConstants.spacingXl * 2),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildHorizontalReleaseSection(
    BuildContext context, {
    required String title,
    required List<Map<String, dynamic>> items,
  }) {
    if (items.isEmpty) return const SizedBox.shrink();

    final screenWidth = MediaQuery.of(context).size.width;
    final cardWidth = ((screenWidth - 48) / 2.2).clamp(130.0, 160.0);
    final sectionHeight = cardWidth + 62.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            context.scaleSize(AppConstants.spacingLg),
            context.scaleSize(AppConstants.spacingLg),
            context.scaleSize(AppConstants.spacingLg),
            context.scaleSize(AppConstants.spacingSm),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: context.scaleSize(18),
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                '${items.length}',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: sectionHeight,
          child: ListView.separated(
            padding: EdgeInsets.symmetric(
              horizontal: context.scaleSize(AppConstants.spacingLg),
            ),
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) => SizedBox(
              width: cardWidth,
              child: _buildAlbumHorizontalCard(
                context,
                items[index],
                cardWidth,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAlbumHorizontalCard(
    BuildContext context,
    Map<String, dynamic> album,
    double size,
  ) {
    final title = album['title'] as String? ?? 'Unknown Album';
    final coverUuid = album['cover'] as String?;
    final coverUrl = coverUuid != null
        ? TidalService.coverUrl(coverUuid, size: 640)
        : null;
    final releaseDate = album['releaseDate'] as String?;
    final year = releaseDate != null && releaseDate.length >= 4
        ? releaseDate.substring(0, 4)
        : null;

    return GestureDetector(
      onTap: () => _openAlbum(album),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppConstants.radiusMd),
            child: SizedBox(
              width: size,
              height: size,
              child: coverUrl != null
                  ? CachedImageWidget(
                      imagePath: coverUrl,
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
          if (year != null)
            Text(
              year,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
              ),
            ),
        ],
      ),
    );
  }
}
