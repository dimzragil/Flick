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
import 'tidal_artist_screen.dart';

class TidalAlbumScreen extends ConsumerStatefulWidget {
  final String albumId;
  final Map<String, dynamic>? initialAlbumData;

  const TidalAlbumScreen({
    super.key,
    required this.albumId,
    this.initialAlbumData,
  });

  @override
  ConsumerState<TidalAlbumScreen> createState() => _TidalAlbumScreenState();
}

class _TidalAlbumScreenState extends ConsumerState<TidalAlbumScreen> {
  void _playSong(Song song, List<Song> playlist) {
    PlayerService().play(song, playlist: playlist);
    NavigationHelper.navigateToFullPlayer(
      context,
      heroTag: 'tidal_album_song_${song.id}',
    );
  }

  void _playAll(List<Song> tracks) {
    if (tracks.isEmpty) return;
    PlayerService().play(tracks.first, playlist: tracks);
    NavigationHelper.navigateToFullPlayer(
      context,
      heroTag: 'tidal_album_play_${widget.albumId}',
    );
  }

  void _shuffleAll(List<Song> tracks) {
    if (tracks.isEmpty) return;
    final shuffled = List<Song>.from(tracks)..shuffle();
    PlayerService().play(shuffled.first, playlist: shuffled);
    NavigationHelper.navigateToFullPlayer(
      context,
      heroTag: 'tidal_album_shuffle_${widget.albumId}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final albumAsync = ref.watch(tidalAlbumDetailsProvider(widget.albumId));

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
            albumAsync.value?.album['title'] ??
                widget.initialAlbumData?['title'] ??
                'Album',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: albumAsync.when(
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
                    'Failed to load album: $error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                  SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
                  ElevatedButton.icon(
                    onPressed: () =>
                        ref.refresh(tidalAlbumDetailsProvider(widget.albumId)),
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
            final album = data.album;
            final tracks = data.tracks;
            final title = (album['title'] as String?) ?? 'Unknown Album';
            final artist =
                (album['artist'] as Map<String, dynamic>?)?['name']
                    as String? ??
                'Unknown Artist';
            final coverUuid = album['cover'] as String?;
            final coverUrl = coverUuid != null
                ? TidalService.coverUrl(coverUuid, size: 640)
                : null;
            final quality = album['audioQuality'] as String?;
            final releaseDate = album['releaseDate'] as String?;
            final year = releaseDate != null && releaseDate.length >= 4
                ? releaseDate.substring(0, 4)
                : null;

            final coverSize = context.scaleSize(180);

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
                        // Album Cover Art
                        Center(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(
                              AppConstants.radiusMd,
                            ),
                            child: SizedBox(
                              width: coverSize,
                              height: coverSize,
                              child: coverUrl != null
                                  ? CachedImageWidget(
                                      imagePath: coverUrl,
                                      width: coverSize,
                                      height: coverSize,
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
                        // Album Title
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(
                          height: context.scaleSize(AppConstants.spacingXs),
                        ),
                        // Artist & Year
                        GestureDetector(
                          onTap: () {
                            final artistMap =
                                album['artist'] as Map<String, dynamic>?;
                            final artistId = artistMap?['id']?.toString();
                            if (artistId != null) {
                              NavigationHelper.pushFade(
                                context,
                                (_) => TidalArtistScreen(
                                  artistId: artistId,
                                  initialArtistData: artistMap,
                                ),
                              );
                            }
                          },
                          child: Text(
                            [artist, ?year].join(' • '),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        SizedBox(
                          height: context.scaleSize(AppConstants.spacingSm),
                        ),
                        // Quality Badge
                        if (quality != null)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.glassBackgroundStrong,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: quality == 'HI_RES_LOSSLESS'
                                    ? const Color(0xFFE5A93C)
                                    : AppColors.glassBorder,
                              ),
                            ),
                            child: Text(
                              quality == 'HI_RES_LOSSLESS'
                                  ? 'HI-RES LOSSLESS 24-BIT'
                                  : 'LOSSLESS FLAC',
                              style: TextStyle(
                                color: quality == 'HI_RES_LOSSLESS'
                                    ? const Color(0xFFE5A93C)
                                    : AppColors.textSecondary,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        SizedBox(
                          height: context.scaleSize(AppConstants.spacingMd),
                        ),
                        // Action Buttons: Play All & Shuffle
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            FilledButton.icon(
                              onPressed: () => _playAll(tracks),
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
                              width: context.scaleSize(AppConstants.spacingMd),
                            ),
                            OutlinedButton.icon(
                              onPressed: () => _shuffleAll(tracks),
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
                        SizedBox(
                          height: context.scaleSize(AppConstants.spacingLg),
                        ),
                      ],
                    ),
                  ),
                ),
                // Tracklist
                SliverPadding(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.scaleSize(AppConstants.spacingMd),
                  ),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final song = tracks[index];
                      final trackNum = song.trackNumber ?? (index + 1);

                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: context.scaleSize(AppConstants.spacingSm),
                          vertical: 2,
                        ),
                        leading: SizedBox(
                          width: 28,
                          child: Center(
                            child: Text(
                              '$trackNum',
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
                            if (song.sampleRate != null &&
                                song.sampleRate! > 48000)
                              Container(
                                margin: const EdgeInsets.only(right: 6),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 1,
                                ),
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
                                song.artist,
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
                        onTap: () => _playSong(song, tracks),
                      );
                    }, childCount: tracks.length),
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
}
