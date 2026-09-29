import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/duration_format.dart';
import '../../../core/utils/navigation_helper.dart';
import '../../../core/utils/responsive.dart';
import '../../../models/song.dart';
import '../../../services/player_service.dart';
import '../../../widgets/common/cached_image_widget.dart';
import '../../songs/widgets/song_actions_bottom_sheet.dart';
import '../providers/tidal_providers.dart';

class TidalMixScreen extends ConsumerStatefulWidget {
  final String mixId;
  final String? initialTitle;
  final String? initialImageUrl;
  final String? initialSubtitle;

  const TidalMixScreen({
    super.key,
    required this.mixId,
    this.initialTitle,
    this.initialImageUrl,
    this.initialSubtitle,
  });

  @override
  ConsumerState<TidalMixScreen> createState() => _TidalMixScreenState();
}

class _TidalMixScreenState extends ConsumerState<TidalMixScreen> {
  void _playSong(Song song, List<Song> playlist) {
    PlayerService().play(song, playlist: playlist);
    NavigationHelper.navigateToFullPlayer(
      context,
      heroTag: 'tidal_mix_song_${song.id}',
    );
  }

  void _playAll(List<Song> tracks) {
    if (tracks.isEmpty) return;
    PlayerService().play(tracks.first, playlist: tracks);
    NavigationHelper.navigateToFullPlayer(
      context,
      heroTag: 'tidal_mix_play_${widget.mixId}',
    );
  }

  void _shuffleAll(List<Song> tracks) {
    if (tracks.isEmpty) return;
    final shuffled = List<Song>.from(tracks)..shuffle();
    PlayerService().play(shuffled.first, playlist: shuffled);
    NavigationHelper.navigateToFullPlayer(
      context,
      heroTag: 'tidal_mix_shuffle_${widget.mixId}',
    );
  }

  void _openSongActions(Song song) {
    SongActionsBottomSheet.show(context, song);
  }

  @override
  Widget build(BuildContext context) {
    final mixAsync = ref.watch(tidalMixDetailsProvider(widget.mixId));

    return Scaffold(
      backgroundColor: AppColors.background,
      body: mixAsync.when(
        loading: () => Scaffold(
          backgroundColor: AppColors.background,
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
              widget.initialTitle ?? 'Mix',
              style: const TextStyle(color: AppColors.textPrimary),
            ),
          ),
          body: const Center(
            child: CircularProgressIndicator(color: Color(0xFF00FFFF)),
          ),
        ),
        error: (err, _) => Scaffold(
          backgroundColor: AppColors.background,
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
                    'Failed to load mix: $err',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () =>
                        ref.invalidate(tidalMixDetailsProvider(widget.mixId)),
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
        data: (mix) {
          final title = mix.title.isNotEmpty
              ? mix.title
              : (widget.initialTitle ?? 'Mix');
          final subtitle = mix.subTitle ?? widget.initialSubtitle;
          final imageUrl = mix.imageUrl ?? widget.initialImageUrl;
          final tracks = mix.tracks;

          return CustomScrollView(
            slivers: [
              SliverAppBar(
                expandedHeight: 280,
                pinned: true,
                backgroundColor: AppColors.surface,
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
                            color: AppColors.surface,
                          ),
                          errorWidget: const ColoredBox(
                            color: AppColors.surface,
                          ),
                        )
                      else
                        const ColoredBox(color: AppColors.surface),
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              AppColors.background.withValues(alpha: 0.8),
                              AppColors.background,
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
                            if (mix.mixType != null)
                              Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0x3300FFFF),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: const Color(0x5500FFFF),
                                  ),
                                ),
                                child: Text(
                                  mix.mixType!,
                                  style: const TextStyle(
                                    color: Color(0xFF00FFFF),
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
                            if (subtitle != null && subtitle.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                subtitle,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 13,
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
              // Play & Shuffle Buttons
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
    );
  }
}
