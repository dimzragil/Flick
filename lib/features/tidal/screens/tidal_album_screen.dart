import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/constants/app_constants.dart';
import '../../../widgets/common/blurred_song_background.dart';
import '../../../core/theme/adaptive_color_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/duration_format.dart';
import '../../../core/utils/navigation_helper.dart';
import '../../../core/utils/responsive.dart';
import '../../../models/song.dart';
import '../../../providers/app_preferences_provider.dart';
import '../../../providers/favorites_provider.dart';
import '../../../services/player_service.dart';
import '../../../services/sources/tidal_service.dart';
import '../../../widgets/common/cached_image_widget.dart';
import '../../../widgets/common/detail_header.dart';
import '../../../widgets/common/fetched_description.dart';
import '../../../widgets/common/flick_artwork_placeholder.dart';
import '../../player/widgets/sleep_timer_bottom_sheet.dart';
import '../providers/tidal_providers.dart';
import '../widgets/press_scale.dart';
import '../widgets/staggered_entrance.dart';
import '../widgets/tidal_detail_theme.dart';
import '../widgets/tidal_shimmer.dart';
import '../widgets/tidal_volume_header.dart';
import '../../songs/widgets/song_actions_bottom_sheet.dart';
import 'tidal_artist_screen.dart';

class TidalAlbumScreen extends ConsumerStatefulWidget {
  final String albumId;
  final Map<String, dynamic>? initialAlbumData;

  /// Matches the tag of the hub card's cover [Hero], when opened from one.
  final String? heroTag;

  /// Overrides the dispatch of a tapped track.
  ///
  /// When set, the tapped song and the full ordered album playlist are
  /// handed to this callback instead of [PlayerService]. Tests use it to
  /// assert which song a tap resolves to — and at which position in the
  /// album — without driving real playback.
  final void Function(Song song, List<Song> playlist)? onPlayTrack;

  const TidalAlbumScreen({
    super.key,
    required this.albumId,
    this.initialAlbumData,
    this.heroTag,
    this.onPlayTrack,
  });

  @override
  ConsumerState<TidalAlbumScreen> createState() => _TidalAlbumScreenState();
}

class _TidalAlbumScreenState extends ConsumerState<TidalAlbumScreen>
    with TidalDominantColor {
  /// Wraps [cover] in a [Hero] when this screen was opened from a hub card
  /// that supplied a matching [TidalAlbumScreen.heroTag].
  Widget _withCoverHero(Widget cover) {
    final tag = widget.heroTag;
    return tag == null ? cover : Hero(tag: tag, child: cover);
  }

  void _playSong(Song song, List<Song> playlist) {
    final onPlayTrack = widget.onPlayTrack;
    if (onPlayTrack != null) {
      onPlayTrack(song, playlist);
      return;
    }
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

  Future<void> _queueAll(List<Song> tracks) async {
    if (tracks.isEmpty) return;
    for (final song in tracks) {
      await PlayerService().addToQueue(song);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Queued ${tracks.length} songs'),
        action: SnackBarAction(
          label: 'View queue',
          onPressed: () => NavigationHelper.navigateToQueue(context),
        ),
      ),
    );
  }

  bool _isAllFavorites(List<Song> tracks) {
    final favorites = ref.watch(favoritesProvider).value;
    if (favorites == null || tracks.isEmpty) return false;
    return tracks.every((song) => favorites.isFavorite(song.id));
  }

  Future<void> _toggleFavoriteAll(List<Song> tracks) async {
    if (tracks.isEmpty) return;
    final favoriteIds =
        ref.read(favoritesProvider).value?.favoriteIds ?? const <String>{};
    final notifier = ref.read(favoritesProvider.notifier);
    final isAll = tracks.every((song) => favoriteIds.contains(song.id));
    if (isAll) {
      for (final song in tracks) {
        await notifier.removeFavorite(song.id, song: song);
      }
    } else {
      for (final song in tracks) {
        if (!favoriteIds.contains(song.id)) {
          await notifier.addFavorite(song.id, song: song);
        }
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          isAll
              ? 'Removed ${tracks.length} songs from favorites'
              : 'Added ${tracks.length} songs to favorites',
        ),
      ),
    );
  }

  /// TIDAL albums currently ship without editorial text. Return the first
  /// non-empty description-shaped field so the About section appears if the
  /// API ever starts providing one — and stays hidden otherwise.
  String? _albumAboutText(Map<String, dynamic> album) {
    for (final key in const ['review', 'description']) {
      final value = album[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is Map && value['text'] is String) {
        final text = (value['text'] as String).trim();
        if (text.isNotEmpty) return text;
      }
    }
    return null;
  }

  void _openArtist(Map<String, dynamic> artist) {
    final artistId = artist['id']?.toString();
    if (artistId == null || artistId.isEmpty) return;
    NavigationHelper.pushSharedAxis(
      context,
      (_) => TidalArtistScreen(artistId: artistId, initialArtistData: artist),
    );
  }

  void _openAlbum(Map<String, dynamic> album) {
    final albumId = album['id']?.toString();
    if (albumId == null || albumId.isEmpty) return;
    NavigationHelper.pushSharedAxis(
      context,
      (_) => TidalAlbumScreen(albumId: albumId, initialAlbumData: album),
    );
  }

  void _showMore(Map<String, dynamic> album) {
    final artist = album['artist'] as Map<String, dynamic>?;
    DetailMoreSheet.show(
      context,
      items: [
        if (artist?['id'] != null)
          DetailMoreSheetItem(
            icon: LucideIcons.user,
            label: 'Go to artist',
            onTap: () => _openArtist(artist!),
          ),
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
      ClipboardData(text: 'https://tidal.com/album/${widget.albumId}'),
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

  /// "More from `artist`" rail: other albums by the same artist, fetched from
  /// the TIDAL catalog. Hidden while loading, on error, and when the
  /// preference is disabled.
  Widget _buildMoreFromArtistSliver(
    BuildContext context, {
    required String artistId,
    required String artistName,
    required String currentAlbumId,
  }) {
    if (!ref.watch(appPreferencesProvider).showMoreFromArtist) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final otherAlbums =
        ref
            .watch(tidalArtistAlbumsProvider(artistId))
            .value
            ?.where((album) => album['id']?.toString() != currentAlbumId)
            .take(10)
            .toList() ??
        const <Map<String, dynamic>>[];
    if (otherAlbums.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    final cardSize = context.scaleSize(140);
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StaggeredEntrance(
            index: 2,
            child: _sectionTitle(context, 'More from $artistName'),
          ),
          SizedBox(
            height: cardSize + context.scaleSize(60),
            child: ListView.separated(
              padding: EdgeInsets.symmetric(
                horizontal: context.scaleSize(AppConstants.spacingLg),
              ),
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: otherAlbums.length,
              separatorBuilder: (_, __) =>
                  SizedBox(width: context.scaleSize(AppConstants.spacingSm)),
              itemBuilder: (context, index) {
                final album = otherAlbums[index];
                return StaggeredEntrance(
                  index: 3 + index,
                  child: PressScale(
                    child: _MoreAlbumCard(
                      album: album,
                      size: cardSize,
                      onTap: () => _openAlbum(album),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final albumAsync = ref.watch(tidalAlbumDetailsProvider(widget.albumId));

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
                loading: () => const TidalDetailBodySkeleton(),
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
                        SizedBox(
                          height: context.scaleSize(AppConstants.spacingMd),
                        ),
                        Text(
                          'Failed to load album: $error',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                          ),
                        ),
                        SizedBox(
                          height: context.scaleSize(AppConstants.spacingMd),
                        ),
                        ElevatedButton.icon(
                          onPressed: () => ref.refresh(
                            tidalAlbumDetailsProvider(widget.albumId),
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
                data: (data) => _buildAlbumBody(context, data),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAlbumBody(
    BuildContext context,
    ({Map<String, dynamic> album, List<Song> tracks}) data,
  ) {
    final album = data.album;
    final tracks = data.tracks;
    final title = (album['title'] as String?) ?? 'Unknown Album';
    final artistMap = album['artist'] as Map<String, dynamic>?;
    final artist = (artistMap?['name'] as String?) ?? 'Unknown Artist';
    final artistId = artistMap?['id']?.toString();
    final coverUuid = album['cover'] as String?;
    // Perf (2026-10-13): header displays at 180px; 320px is plenty
    // for retina. 1280px was 7x oversize — wasted bandwidth, decode
    // CPU, memory, and battery on scroll. (1280px preserved for
    // share-card/fullscreen artwork elsewhere.)
    final coverUrl = coverUuid != null
        ? TidalService.coverUrl(coverUuid, size: 320)
        : null;
    maybeExtractDominantColor(coverUrl);
    final hasHiRes = tracks.any((t) => (t.bitDepth ?? 0) >= 24);
    final releaseDate = album['releaseDate'] as String?;
    final year = releaseDate != null && releaseDate.length >= 4
        ? releaseDate.substring(0, 4)
        : null;
    final aboutText = _albumAboutText(album);
    // Flattened track rows: volume headers interleaved with tracks for
    // multi-disc albums, a plain track list for single-disc ones.
    final listItems = buildTidalAlbumListItems(tracks);

    final coverSize = context.scaleSize(180);

    return StaggeredEntranceWindow(
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.scaleSize(AppConstants.spacingLg),
                vertical: context.scaleSize(AppConstants.spacingMd),
              ),
              child: Column(
                children: [
                  // Album Cover Art, glowing with the extracted dominant color
                  Center(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(
                          AppConstants.radiusMd,
                        ),
                        boxShadow: dominantColor == null
                            ? null
                            : [
                                BoxShadow(
                                  color: dominantColor!.withValues(alpha: 0.35),
                                  blurRadius: 32,
                                  offset: const Offset(0, 10),
                                ),
                              ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(
                          AppConstants.radiusMd,
                        ),
                        child: SizedBox(
                          width: coverSize,
                          height: coverSize,
                          child: coverUrl != null
                              ? _withCoverHero(
                                  CachedImageWidget(
                                    imagePath: coverUrl,
                                    width: coverSize,
                                    height: coverSize,
                                    fit: BoxFit.cover,
                                    placeholder:
                                        const FlickArtworkPlaceholder(),
                                    errorWidget:
                                        const FlickArtworkPlaceholder(),
                                  ),
                                )
                              : const FlickArtworkPlaceholder(),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
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
                  SizedBox(height: context.scaleSize(AppConstants.spacingXs)),
                  // Artist & Year
                  PressScale(
                    child: GestureDetector(
                      onTap: () {
                        if (artistMap != null) _openArtist(artistMap);
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
                  ),
                  SizedBox(height: context.scaleSize(AppConstants.spacingSm)),
                  // Quality Badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.glassBackgroundStrong,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: AppColors.glassBorder),
                    ),
                    child: Text(
                      hasHiRes ? 'HI-RES LOSSLESS 24-BIT' : 'LOSSLESS FLAC',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
                  // Unified action bar, themed with the cover's color.
                  StaggeredEntrance(
                    index: 0,
                    child: DetailActionCapsule(
                      isFavorite: _isAllFavorites(tracks),
                      onToggleFavorite: () => _toggleFavoriteAll(tracks),
                      onShuffle: () => _shuffleAll(tracks),
                      onPlay: () => _playAll(tracks),
                      onQueue: () => _queueAll(tracks),
                      onMore: () => _showMore(album),
                      primaryColor: dominantColor,
                    ),
                  ),
                  SizedBox(height: context.scaleSize(AppConstants.spacingLg)),
                ],
              ),
            ),
          ),
          // About this album — only when the API actually returns text.
          if (aboutText != null)
            SliverToBoxAdapter(
              child: StaggeredEntrance(
                index: 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionTitle(context, 'About this album'),
                    FetchedDescription(text: aboutText, sourceLabel: 'TIDAL'),
                  ],
                ),
              ),
            ),
          // Tracklist. Multi-disc albums are grouped by volume with a header
          // before each volume; single-disc albums render exactly as before.
          SliverPadding(
            padding: EdgeInsets.symmetric(
              horizontal: context.scaleSize(AppConstants.spacingMd),
            ),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final item = listItems[index];
                if (item is TidalVolumeHeaderItem) {
                  return StaggeredEntrance(
                    index: index,
                    child: TidalVolumeHeaderRow(
                      volume: item.volume,
                      trackCount: item.trackCount,
                      accentColor: dominantColor,
                    ),
                  );
                }
                final track = item as TidalAlbumTrackItem;
                final song = track.song;
                // Numbering follows the track's place in the whole album, so
                // the per-volume track numbers of a multi-disc album stay
                // aligned with the headers above them.
                final trackNum = song.trackNumber ?? (track.globalIndex + 1);

                return StaggeredEntrance(
                  index: index,
                  child: PressScale(
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: context.scaleSize(AppConstants.spacingSm),
                        vertical: 2,
                      ),
                      leading: SizedBox(
                        width: kTidalTrackNumberColumnWidth,
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
                          if ((song.bitDepth ?? 0) >= 24)
                            Container(
                              margin: const EdgeInsets.only(right: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.glassBackgroundStrong,
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
                    ),
                  ),
                );
              }, childCount: listItems.length),
            ),
          ),
          if (artistId != null && artistId.isNotEmpty)
            _buildMoreFromArtistSliver(
              context,
              artistId: artistId,
              artistName: artist,
              currentAlbumId: widget.albumId,
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

class _MoreAlbumCard extends StatelessWidget {
  const _MoreAlbumCard({
    required this.album,
    required this.size,
    required this.onTap,
  });

  final Map<String, dynamic> album;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final title = album['title'] as String? ?? 'Unknown Album';
    final coverUuid = album['cover'] as String?;
    final coverUrl = coverUuid != null
        ? TidalService.coverUrl(coverUuid, size: 320)
        : null;
    final releaseDate = album['releaseDate'] as String?;
    final year = releaseDate != null && releaseDate.length >= 4
        ? releaseDate.substring(0, 4)
        : null;

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: size,
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
      ),
    );
  }
}
