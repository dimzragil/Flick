import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/constants/app_constants.dart';
import '../../../widgets/common/blurred_song_background.dart';
import '../../../core/theme/adaptive_color_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/navigation_helper.dart';
import '../../../core/utils/responsive.dart';
import '../../../models/song.dart';
import '../../../services/player_service.dart';
import '../../../services/sources/tidal_service.dart';
import '../../../widgets/common/cached_image_widget.dart';
import '../../../widgets/common/detail_header.dart';
import '../../../widgets/common/fetched_description.dart';
import '../../../widgets/common/flick_artwork_placeholder.dart';
import '../../../widgets/common/song_badges.dart';
import '../../player/widgets/sleep_timer_bottom_sheet.dart';
import '../../songs/widgets/song_actions_bottom_sheet.dart';
import '../providers/tidal_providers.dart';
import '../widgets/press_scale.dart';
import '../widgets/staggered_entrance.dart';
import '../widgets/tidal_detail_theme.dart';
import '../widgets/tidal_shimmer.dart';

class TidalPlaylistScreen extends ConsumerStatefulWidget {
  final String playlistId;
  final String? initialTitle;
  final String? initialImageUrl;
  final String? initialSubtitle;
  final int? initialTrackCount;

  /// Matches the tag of the hub card's cover [Hero], when opened from one.
  final String? heroTag;

  const TidalPlaylistScreen({
    super.key,
    required this.playlistId,
    this.initialTitle,
    this.initialImageUrl,
    this.initialSubtitle,
    this.initialTrackCount,
    this.heroTag,
  });

  @override
  ConsumerState<TidalPlaylistScreen> createState() =>
      _TidalPlaylistScreenState();
}

class _TidalPlaylistScreenState extends ConsumerState<TidalPlaylistScreen>
    with TidalDominantColor {
  /// Wraps [cover] in a [Hero] when this screen was opened from a hub card
  /// that supplied a matching [TidalPlaylistScreen.heroTag].
  Widget _withCoverHero(Widget cover) {
    final tag = widget.heroTag;
    return tag == null ? cover : Hero(tag: tag, child: cover);
  }

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

  void _showMore() {
    DetailMoreSheet.show(
      context,
      items: [
        DetailMoreSheetItem(
          icon: LucideIcons.link,
          label: 'Copy TIDAL link',
          onTap: _copyTidalLink,
        ),
        DetailMoreSheetItem(
          icon: LucideIcons.moonStar,
          label: 'Sleep timer',
          onTap: () => SleepTimerBottomSheet.show(context, PlayerService()),
        ),
      ],
    );
  }

  Future<void> _copyTidalLink() async {
    await Clipboard.setData(
      ClipboardData(text: 'https://tidal.com/playlist/${widget.playlistId}'),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('TIDAL link copied')));
  }

  Widget _sectionTitle(BuildContext context, String title) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.scaleSize(AppConstants.spacingLg),
        0,
        context.scaleSize(AppConstants.spacingLg),
        context.scaleSize(AppConstants.spacingSm),
      ),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: context.adaptiveTextSecondary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final detailsAsync = ref.watch(
      tidalPlaylistDetailsProvider(widget.playlistId),
    );

    return BlurredSongBackground(
      child: Stack(
        children: [
          // Dominant-color wash on top of the blurred backdrop (complements
          // it, never replaces it); fades in when the cover color resolves.
          Positioned.fill(child: TidalColorWash(color: dominantColor)),
          AdaptiveColorProvider(
            backgroundColor: themedBackground,
            albumDominantColor: dominantColor,
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
                  body: const TidalBannerBodySkeleton(),
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
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                            ),
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
                data: (data) => _buildPlaylistBody(context, data),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaylistBody(
    BuildContext context,
    ({Map<String, dynamic> playlist, List<Song> tracks}) data,
  ) {
    final playlist = data.playlist;
    // Newest tracks first (reversed API order).
    final tracks = data.tracks.reversed.toList();
    final title =
        (playlist['title'] as String?) ?? widget.initialTitle ?? 'Playlist';
    final description =
        (playlist['description'] as String?) ?? widget.initialSubtitle;
    final creator = playlist['creator'] as Map<String, dynamic>?;
    final creatorName = creator != null
        ? (creator['id'] == 0 ? 'TIDAL' : (creator['name'] as String?))
        : null;
    final nativeCover = TidalService.extractPlaylistCover(playlist, size: 640);
    final imageUrl = (nativeCover != null && nativeCover.isNotEmpty)
        ? nativeCover
        : ((tracks.isNotEmpty &&
                  tracks.first.albumArt != null &&
                  tracks.first.albumArt!.isNotEmpty)
              ? tracks.first.albumArt
              : widget.initialImageUrl);
    maybeExtractDominantColor(imageUrl);
    final aboutText = description != null && description.trim().isNotEmpty
        ? description.trim()
        : null;

    return StaggeredEntranceWindow(
      child: CustomScrollView(
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
                    _withCoverHero(
                      CachedImageWidget(
                        imagePath: imageUrl,
                        fit: BoxFit.cover,
                        placeholder: const ColoredBox(
                          color: AppColors.glassBackgroundStrong,
                        ),
                        errorWidget: const ColoredBox(
                          color: AppColors.glassBackgroundStrong,
                        ),
                      ),
                    )
                  else
                    const ColoredBox(color: AppColors.glassBackgroundStrong),
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
                            border: Border.all(color: const Color(0x54FFFFFF)),
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
          // Unified action capsule, themed with the cover's color.
          // TIDAL-specific mapping: playlists are playlist-level, so the
          // Favorite and Queue segments are dropped (null callbacks).
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.scaleSize(AppConstants.spacingMd),
                vertical: context.scaleSize(AppConstants.spacingMd),
              ),
              child: StaggeredEntrance(
                index: 0,
                child: DetailActionCapsule(
                  isFavorite: false,
                  onToggleFavorite: null,
                  onShuffle: () => _shuffleAll(tracks),
                  onPlay: () => _playAll(tracks),
                  onQueue: null,
                  onMore: _showMore,
                  primaryColor: dominantColor,
                ),
              ),
            ),
          ),
          // About this playlist — only when the API returns a description.
          if (aboutText != null)
            SliverToBoxAdapter(
              child: StaggeredEntrance(
                index: 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionTitle(context, 'About this playlist'),
                    FetchedDescription(text: aboutText, sourceLabel: 'TIDAL'),
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
                final isHiRes = (song.bitDepth ?? 0) >= 24;
                final thumbSize = context.scaleSize(48);
                final thumbArt = TidalService.resizedCoverUrl(
                  song.albumArt,
                  160,
                );

                return StaggeredEntrance(
                  index: index,
                  child: PressScale(
                    child: ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(
                          AppConstants.radiusSm,
                        ),
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
                      title: SongTitleRow(
                        title: song.title,
                        isExplicit: song.isExplicit,
                        isAtmos: song.isAtmos,
                        isHiRes: isHiRes,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      subtitle: Row(
                        children: [
                          Flexible(
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
                      trailing: IconButton(
                        icon: const Icon(
                          LucideIcons.ellipsisVertical,
                          size: 18,
                          color: AppColors.textSecondary,
                        ),
                        onPressed: () => _openSongActions(song),
                      ),
                      onTap: () => _playSong(song, tracks),
                    ),
                  ),
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
      ),
    );
  }
}
