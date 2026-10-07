import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/responsive.dart';
import '../../../models/song.dart';
import '../../../services/player_service.dart';
import '../../../services/sources/tidal_service.dart';
import '../../../widgets/common/cached_image_widget.dart';
import '../../../widgets/common/flick_artwork_placeholder.dart';
import '../../songs/widgets/song_actions_bottom_sheet.dart';
import '../providers/tidal_providers.dart';

/// Full "Liked Songs" collection — the user's TIDAL favorite tracks.
class TidalLikedSongsScreen extends ConsumerWidget {
  const TidalLikedSongsScreen({super.key});

  void _playSong(BuildContext context, Song song, List<Song> playlist) {
    PlayerService().play(song, playlist: playlist);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final likedAsync = ref.watch(tidalLikedSongsProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft, color: AppColors.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Row(
          children: [
            Icon(LucideIcons.heart, size: 20, color: Colors.pinkAccent),
            SizedBox(width: 8),
            Text(
              'Liked Songs',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        actions: [
          likedAsync.when(
            data: (songs) => songs.isNotEmpty
                ? IconButton(
                    icon: const Icon(
                      LucideIcons.play,
                      color: AppColors.textPrimary,
                    ),
                    onPressed: () => _playSong(context, songs.first, songs),
                  )
                : const SizedBox.shrink(),
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
        ],
      ),
      body: RefreshIndicator(
        color: Colors.pinkAccent,
        backgroundColor: AppColors.surface,
        onRefresh: () => ref.refresh(tidalLikedSongsProvider.future),
        child: likedAsync.when(
          loading: () => const Center(
            child: CircularProgressIndicator(color: Colors.pinkAccent),
          ),
          error: (err, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Failed to load liked songs:\n$err',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary),
              ),
            ),
          ),
          data: (songs) {
            if (songs.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No liked songs yet.\nTap the heart on any track to add it here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                ),
              );
            }
            return ListView.builder(
              padding: EdgeInsets.symmetric(
                horizontal: context.scaleSize(AppConstants.spacingMd),
                vertical: context.scaleSize(AppConstants.spacingSm),
              ),
              itemCount: songs.length,
              itemBuilder: (context, index) {
                final song = songs[index];
                return _buildSongTile(context, song, songs, index);
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildSongTile(
    BuildContext context,
    Song song,
    List<Song> playlist,
    int index,
  ) {
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
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          song.artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              song.formattedDuration,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
            IconButton(
              icon: const Icon(
                LucideIcons.ellipsisVertical,
                color: AppColors.textSecondary,
                size: 18,
              ),
              onPressed: () => SongActionsBottomSheet.show(context, song),
            ),
          ],
        ),
        onTap: () => _playSong(context, song, playlist),
      ),
    );
  }
}
