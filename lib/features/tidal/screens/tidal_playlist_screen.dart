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
import '../../songs/widgets/song_actions_bottom_sheet.dart';
import '../providers/tidal_providers.dart';

class TidalPlaylistScreen extends ConsumerStatefulWidget {
  final String playlistId;
  final String? initialTitle;
  final String? initialImageUrl;
  final String? initialSubtitle;
  final int? initialTrackCount;

  const TidalPlaylistScreen({
    super.key,
    required this.playlistId,
    this.initialTitle,
    this.initialImageUrl,
    this.initialSubtitle,
    this.initialTrackCount,
  });

  @override
  ConsumerState<TidalPlaylistScreen> createState() =>
      _TidalPlaylistScreenState();
}

class _TidalPlaylistScreenState extends ConsumerState<TidalPlaylistScreen> {
  void _playSong(Song song, List<Song> playlist) {
    PlayerService().play(song, playlist: playlist);
    NavigationHelper.navigateToFullPlayer(
      context,
      heroTag: 'tidal_playlist_song_${song.id}',
    );
  }

  void _playAll(List<Song> tracks) {
    if (tracks.isEmpty) return;
    PlayerService().play(tracks.first, playlist: tracks);
    NavigationHelper.navigateToFullPlayer(
      context,
      heroTag: 'tidal_playlist_play_${widget.playlistId}',
    );
  }

  void _shuffleAll(List<Song> tracks) {
    if (tracks.isEmpty) return;
    final shuffled = List<Song>.from(tracks)..shuffle();
    PlayerService().play(shuffled.first, playlist: shuffled);
    NavigationHelper.navigateToFullPlayer(
      context,
      heroTag: 'tidal_playlist_shuffle_${widget.playlistId}',
    );
  }

  void _openSongActions(Song song) {
    SongActionsBottomSheet.show(context, song);
  }

  @override
  Widget build(BuildContext context) {
    final detailsAsync = ref.watch(
      tidalPlaylistDetailsProvider(widget.playlistId),
    );

    return BlurredSongBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: detailsAsync.when(
          loading: () => Scaffold(
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
                widget.initialTitle ?? 'Playlist',
                style: const TextStyle(color: AppColors.textPrimary),
              ),
            ),
            body: const Center(
              child: CircularProgressIndicator(color: Color(0xD9FFFFFF)),
            ),
          ),
          error: (err, _) => Scaffold(
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
            ),
            body: Center(
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
                      color: Colors.redAccent,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Failed to load playlist: $err',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => ref.invalidate(
                        tidalPlaylistDetailsProvider(widget.playlistId),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF00A2C7),
                      ),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          data: (data) {
            final playlist = data.playlist;
            final tracks = data.tracks;
            final title =
                (playlist['title'] as String?) ??
                widget.initialTitle ??
                'Playlist';
            final description =
                (playlist['description'] as String?) ?? widget.initialSubtitle;
            final creator = playlist['creator'] as Map<String, dynamic>?;
            final creatorName = creator != null
                ? (creator['id'] == 0 ? 'TIDAL' : (creator['name'] as String?))
                : null;
            final nativeCover = TidalService.extractPlaylistCover(
              playlist,
              size: 640,
            );
            final imageUrl = (nativeCover != null && nativeCover.isNotEmpty)
                ? nativeCover
                : ((tracks.isNotEmpty &&
                          tracks.first.albumArt != null &&
                          tracks.first.albumArt!.isNotEmpty)
                      ? tracks.first.albumArt
                      : widget.initialImageUrl);

            return CustomScrollView(
              slivers: [
                SliverAppBar(
                  expandedHeight: 280,
                  pinned: true,
                  backgroundColor: Colors.transparent,
                  leading: IconButton(
                    icon: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        LucideIcons.arrowLeft,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  flexibleSpace: FlexibleSpaceBar(
                    background: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (imageUrl != null && imageUrl.isNotEmpty)
                          CachedImageWidget(
                            imagePath: imageUrl,
                            fit: BoxFit.cover,
                            placeholder: const ColoredBox(
                              color: AppColors.glassBackgroundStrong,
                            ),
                            errorWidget: const ColoredBox(
                              color: AppColors.glassBackgroundStrong,
                            ),
                          )
                        else
                          const ColoredBox(
                            color: AppColors.glassBackgroundStrong,
                          ),
                        Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.5),
                                Colors.black.withValues(alpha: 0.85),
                              ],
                            ),
                          ),
                        ),
                        Positioned(
                          left: context.scaleSize(AppConstants.spacingMd),
                          right: context.scaleSize(AppConstants.spacingMd),
                          bottom: context.scaleSize(AppConstants.spacingMd),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0x33FFFFFF),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: const Color(0x54FFFFFF),
                                  ),
                                ),
                                child: const Text(
                                  'PLAYLIST',
                                  style: TextStyle(
                                    color: Color(0xD9FFFFFF),
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (creatorName != null) ...[
                                const SizedBox(height: 4),
                                Text(
                                  'By $creatorName',
                                  style: const TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                              if (description != null &&
                                  description.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  description,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: AppColors.textTertiary,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 4),
                              Text(
                                '${tracks.length} tracks',
                                style: const TextStyle(
                                  color: AppColors.textTertiary,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Play & Shuffle
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: context.scaleSize(AppConstants.spacingMd),
                      vertical: context.scaleSize(AppConstants.spacingMd),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () => _playAll(tracks),
                            icon: const Icon(LucideIcons.play, size: 18),
                            label: const Text('Play All'),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF00A2C7),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _shuffleAll(tracks),
                            icon: const Icon(LucideIcons.shuffle, size: 18),
                            label: const Text('Shuffle'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.textPrimary,
                              side: const BorderSide(
                                color: AppColors.glassBorder,
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
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
                      final trackNum = index + 1;
                      final isHiRes =
                          song.sampleRate != null && song.sampleRate! > 48000;

                      return ListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
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
                            if (isHiRes)
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
                              onPressed: () => _openSongActions(song),
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
