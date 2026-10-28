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
import '../../../providers/app_preferences_provider.dart';
import '../../../services/player_service.dart';
import '../../../services/sources/tidal_album_deduplication.dart';
import '../../../services/sources/tidal_service.dart';
import '../../../widgets/common/cached_image_widget.dart';
import '../../../widgets/common/detail_header.dart';
import '../../../widgets/common/fetched_description.dart';
import '../../../widgets/common/flick_artwork_placeholder.dart';
import '../widgets/tidal_entity_share.dart';
import '../widgets/tidal_now_playing_title.dart';
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
  static const double _kTidalSectionGap = AppConstants.spacingMd;
  static const double _kTidalTitleContentGap = 8;

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

  Future<void> _toggleAlbumLove(Map<String, dynamic> album) async {
    final server = ref.read(tidalServerProvider).value;
    if (server == null || server.token == null || server.token!.isEmpty) return;
    final wasLoved = ref.read(tidalAlbumLovedProvider(widget.albumId));
    final optimistic = ref.read(tidalLikedAlbumsOptimisticProvider.notifier);
    final tidal = ref.read(tidalServiceProvider);
    if (wasLoved) {
      optimistic.remove(widget.albumId);
    } else {
      optimistic.add({...album, 'id': widget.albumId});
    }
    try {
      if (wasLoved) {
        await tidal.removeFavoriteAlbum(server, widget.albumId);
      } else {
        await tidal.addFavoriteAlbum(server, widget.albumId);
      }
    } catch (_) {
      if (wasLoved) {
        optimistic.add({...album, 'id': widget.albumId});
      } else {
        optimistic.remove(widget.albumId);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            wasLoved ? 'Failed to unlove album' : 'Failed to love album',
          ),
        ),
      );
    }
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
          label: 'Copy link',
          onTap: _copyTidalLink,
        ),
        DetailMoreSheetItem(
          icon: LucideIcons.share2,
          label: 'Share',
          onTap: () => _share(album),
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
    ).showSnackBar(const SnackBar(content: Text('Link copied')));
  }

  void _share(Map<String, dynamic> album) {
    final title =
        (album['title'] as String?) ??
        widget.initialAlbumData?['title'] ??
        'Album';
    final artistMap = album['artist'] as Map<String, dynamic>?;
    final artist = (artistMap?['name'] as String?);
    final coverUuid = album['cover'] as String?;
    final coverUrl = coverUuid != null
        ? TidalService.coverUrl(coverUuid, size: 320)
        : null;
    shareTidalEntity(
      context: context,
      type: TidalShareEntityType.album,
      id: widget.albumId,
      title: title,
      subtitle: artist,
      coverUrl: coverUrl,
    );
  }

  Widget _sectionTitle(BuildContext context, String title) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.scaleSize(AppConstants.spacingLg),
        0,
        context.scaleSize(AppConstants.spacingLg),
        _kTidalTitleContentGap,
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

  /// "Other versions" rail: alternative releases/editions of the current album
  /// (e.g. standard vs deluxe, remastered vs original, or alternate distributor releases).
  Widget _buildOtherVersionsSliver(
    BuildContext context, {
    required List<Map<String, dynamic>> versions,
  }) {
    if (versions.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    final cardSize = context.scaleSize(140);
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: context.scaleSize(_kTidalSectionGap)),
          StaggeredEntrance(
            index: 2,
            child: _sectionTitle(context, 'Other versions'),
          ),
          SizedBox(
            height: cardSize + 41,
            child: ListView.separated(
              padding: EdgeInsets.symmetric(
                horizontal: context.scaleSize(AppConstants.spacingLg),
              ),
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: versions.length,
              separatorBuilder: (_, __) =>
                  SizedBox(width: context.scaleSize(AppConstants.spacingSm)),
              itemBuilder: (context, index) {
                final album = versions[index];
                return StaggeredEntrance(
                  index: 3 + index,
                  child: PressScale(
                    child: _MoreAlbumCard(
                      album: album,
                      size: cardSize,
                      onTap: () => _openAlbum(album),
                      showQualityBadge: true,
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

  /// "More from `artist`" rail: other distinct albums by the same artist.
  /// Hidden while loading, on error, and when the preference is disabled.
  Widget _buildMoreFromArtistSliver(
    BuildContext context, {
    required String artistName,
    required List<Map<String, dynamic>> albums,
  }) {
    if (!ref.watch(appPreferencesProvider).showMoreFromArtist ||
        albums.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    final cardSize = context.scaleSize(140);
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: context.scaleSize(_kTidalSectionGap)),
          StaggeredEntrance(
            index: 2,
            child: _sectionTitle(context, 'More from $artistName'),
          ),
          SizedBox(
            height: cardSize + 41,
            child: ListView.separated(
              padding: EdgeInsets.symmetric(
                horizontal: context.scaleSize(AppConstants.spacingLg),
              ),
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: albums.length,
              separatorBuilder: (_, __) =>
                  SizedBox(width: context.scaleSize(AppConstants.spacingSm)),
              itemBuilder: (context, index) {
                final album = albums[index];
                return StaggeredEntrance(
                  index: 3 + index,
                  child: PressScale(
                    child: _MoreAlbumCard(
                      album: album,
                      size: cardSize,
                      onTap: () => _openAlbum(album),
                      showQualityBadge: true,
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
    final hasAccount = ref.watch(tidalAuthStateProvider);
    final isLoved = ref.watch(tidalAlbumLovedProvider(widget.albumId));
    final title = (album['title'] as String?) ?? 'Unknown Album';
    final artistMap = album['artist'] as Map<String, dynamic>?;
    final artist = (artistMap?['name'] as String?) ?? 'Unknown Artist';
    final artistId = artistMap?['id']?.toString();
    final allArtistAlbums = artistId != null && artistId.isNotEmpty
        ? (ref.watch(tidalArtistAlbumsProvider(artistId)).value ??
              const <Map<String, dynamic>>[])
        : const <Map<String, dynamic>>[];
    final otherVersions = allArtistAlbums.isNotEmpty
        ? TidalAlbumDeduplication.findOtherVersions(album, allArtistAlbums)
        : const <Map<String, dynamic>>[];
    final moreFromArtist = allArtistAlbums.isNotEmpty
        ? TidalAlbumDeduplication.filterMoreFromArtist(
            album,
            allArtistAlbums,
          ).take(10).toList()
        : const <Map<String, dynamic>>[];
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
              padding: EdgeInsets.only(
                left: context.scaleSize(AppConstants.spacingLg),
                top: context.scaleSize(AppConstants.spacingMd),
                right: context.scaleSize(AppConstants.spacingLg),
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
                  SizedBox(height: context.scaleSize(_kTidalSectionGap)),
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
                  SizedBox(height: _kTidalTitleContentGap),
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
                  SizedBox(height: context.scaleSize(_kTidalSectionGap)),
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
                      hasHiRes
                          ? 'HI-RES LOSSLESS 24-BIT'
                          : 'LOSSLESS FLAC 16-BIT',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  SizedBox(height: context.scaleSize(_kTidalSectionGap)),
                  // Unified action bar, themed with the cover's color.
                  StaggeredEntrance(
                    index: 0,
                    child: DetailActionCapsule(
                      isFavorite: isLoved,
                      onToggleFavorite: hasAccount
                          ? () => _toggleAlbumLove(album)
                          : null,
                      toggleActiveTooltip: 'Remove from loved albums',
                      toggleInactiveTooltip: 'Love album',
                      onShuffle: () => _shuffleAll(tracks),
                      onPlay: () => _playAll(tracks),
                      onQueue: () => _queueAll(tracks),
                      onMore: () => _showMore(album),
                      primaryColor: dominantColor,
                    ),
                  ),
                  SizedBox(height: context.scaleSize(_kTidalSectionGap)),
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
          if (aboutText != null)
            SliverToBoxAdapter(
              child: SizedBox(height: context.scaleSize(_kTidalSectionGap)),
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
                      title: TidalNowPlayingTitle(
                        title: song.title,
                        songId: song.id,
                        isExplicit: song.isExplicit,
                        isAtmos: song.isAtmos,
                        isHiRes: (song.bitDepth ?? 0) >= 24,
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
                        onPressed: () =>
                            SongActionsBottomSheet.show(context, song),
                      ),
                      onTap: () => _playSong(song, tracks),
                    ),
                  ),
                );
              }, childCount: listItems.length),
            ),
          ),
          if (otherVersions.isNotEmpty)
            _buildOtherVersionsSliver(context, versions: otherVersions),
          if (artistId != null &&
              artistId.isNotEmpty &&
              moreFromArtist.isNotEmpty)
            _buildMoreFromArtistSliver(
              context,
              artistName: artist,
              albums: moreFromArtist,
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
    this.showQualityBadge = false,
  });

  final Map<String, dynamic> album;
  final double size;
  final VoidCallback onTap;
  final bool showQualityBadge;

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

    final mediaMeta = album['mediaMetadata'] as Map<String, dynamic>?;
    final tags =
        (mediaMeta?['tags'] as List<dynamic>?)?.cast<String>() ?? const [];
    final isHiRes =
        tags.contains('HIRES_LOSSLESS') || tags.contains('HIRES_LOSSLESS_MQA');
    final isLossless =
        tags.contains('LOSSLESS') || album['audioQuality'] == 'LOSSLESS';

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
            Row(
              children: [
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
                if (showQualityBadge && (isHiRes || isLossless)) ...[
                  if (year != null) const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: isHiRes
                          ? const Color(0xFFE5A93C).withValues(alpha: 0.15)
                          : AppColors.glassBackgroundStrong,
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(
                        color: isHiRes
                            ? const Color(0xFFE5A93C).withValues(alpha: 0.5)
                            : AppColors.glassBorder,
                        width: 0.5,
                      ),
                    ),
                    child: Text(
                      isHiRes ? 'HI-RES' : 'CD',
                      style: TextStyle(
                        color: isHiRes
                            ? const Color(0xFFE5A93C)
                            : AppColors.textSecondary,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
                if (showQualityBadge && album['explicit'] == true) ...[
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 3,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.glassBackgroundStrong,
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: const Text(
                      'E',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 8,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
