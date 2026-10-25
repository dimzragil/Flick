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
import '../providers/tidal_providers.dart';
import '../widgets/press_scale.dart';
import '../widgets/staggered_entrance.dart';
import '../widgets/tidal_detail_theme.dart';
import '../widgets/tidal_shimmer.dart';
import '../../songs/widgets/song_actions_bottom_sheet.dart';
import 'tidal_album_screen.dart';

class TidalArtistScreen extends ConsumerStatefulWidget {
  final String artistId;
  final Map<String, dynamic>? initialArtistData;

  /// Matches the tag of the hub card's cover [Hero], when opened from one.
  final String? heroTag;

  const TidalArtistScreen({
    super.key,
    required this.artistId,
    this.initialArtistData,
    this.heroTag,
  });

  @override
  ConsumerState<TidalArtistScreen> createState() => _TidalArtistScreenState();
}

class _TidalArtistScreenState extends ConsumerState<TidalArtistScreen>
    with TidalDominantColor {
  /// Wraps [cover] in a [Hero] when this screen was opened from a hub card
  /// that supplied a matching [TidalArtistScreen.heroTag].
  Widget _withCoverHero(Widget cover) {
    final tag = widget.heroTag;
    return tag == null ? cover : Hero(tag: tag, child: cover);
  }

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
    NavigationHelper.pushSharedAxis(
      context,
      (_) => TidalAlbumScreen(albumId: albumId, initialAlbumData: album),
    );
  }

  /// Whether the account is signed in — following needs a user token.
  bool _hasAccount() {
    final token = ref.read(tidalServerProvider).value?.token;
    return token != null && token.isNotEmpty;
  }

  /// Optimistic follow/unfollow, mirroring the track-favorites pattern: the
  /// capsule flips instantly while the TIDAL call runs, and reverts with a
  /// snackbar when the network fails.
  Future<void> _toggleFollow() async {
    final server = ref.read(tidalServerProvider).value;
    if (server == null) return;
    final wasFollowed = ref.read(tidalArtistFollowedProvider(widget.artistId));
    final optimistic = ref.read(
      tidalFavoriteArtistIdsOptimisticProvider.notifier,
    );
    final tidal = ref.read(tidalServiceProvider);

    if (wasFollowed) {
      optimistic.remove(widget.artistId);
    } else {
      optimistic.add(widget.artistId);
    }

    try {
      if (wasFollowed) {
        await tidal.removeFavoriteArtist(server, widget.artistId);
      } else {
        await tidal.addFavoriteArtist(server, widget.artistId);
      }
    } catch (_) {
      // Revert the optimistic flip so the capsule reflects the truth.
      if (wasFollowed) {
        optimistic.add(widget.artistId);
      } else {
        optimistic.remove(widget.artistId);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            wasFollowed
                ? 'Failed to unfollow artist'
                : 'Failed to follow artist',
          ),
        ),
      );
    }
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
      ClipboardData(text: 'https://tidal.com/artist/${widget.artistId}'),
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

  /// A non-empty string [value], or null for missing/empty data.
  static String? _nonEmpty(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  /// First usable `cover` uuid among an already-fetched release list.
  static String? _firstReleaseCover(List<Map<String, dynamic>> releases) {
    for (final release in releases) {
      final cover = _nonEmpty(release['cover']);
      if (cover != null) return cover;
    }
    return null;
  }

  /// Builds the avatar CDN url for an artist picture or fallback cover uuid,
  /// mapping empty and nil/placeholder uuids (which [TidalService.coverUrl] rejects)
  /// to null so the placeholder shows instead of a doomed image request.
  ///
  /// Uses [TidalService.artistPictureUrl] to ensure supported CDN dimensions
  /// (320x320) are requested; 640x640 returns HTTP 403 on TIDAL CDN.
  static String? _avatarUrl(String? coverUuid) {
    if (coverUuid == null || coverUuid.isEmpty) return null;
    final url = TidalService.artistPictureUrl(coverUuid, size: 320);
    return url.isEmpty ? null : url;
  }

  @override
  Widget build(BuildContext context) {
    final artistAsync = ref.watch(tidalArtistDetailsProvider(widget.artistId));

    return BlurredSongBackground(
      child: Stack(
        children: [
          // Dominant-color wash on top of the blurred backdrop (complements
          // it, never replaces it); fades in when the photo color resolves.
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
                loading: () =>
                    const TidalDetailBodySkeleton(artSize: 140, circle: true),
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
                          'Failed to load artist: $error',
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
                data: (data) => _buildArtistBody(context, data),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildArtistBody(
    BuildContext context,
    ({
      Map<String, dynamic> artist,
      List<Song> topTracks,
      List<Map<String, dynamic>> albums,
      List<Map<String, dynamic>> singlesAndEPs,
      List<Map<String, dynamic>> compilations,
    })
    data,
  ) {
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
    // Avatar source chain, all from already-fetched data (zero extra API
    // calls, and only the resolved image is ever downloaded):
    // 1. the artist photo (`picture`);
    // 2. TIDAL's `selectedAlbumCoverFallback` — an album-cover uuid the
    //    server fills in for artists without a photo (same payload, served
    //    by the same CDN at 640x640);
    // 3. the first cover among the already-fetched releases;
    // 4. the placeholder (stub artists with neither field nor releases).
    final picture =
        _nonEmpty(artist['picture']) ??
        _nonEmpty(widget.initialArtistData?['picture']) ??
        _nonEmpty(artist['selectedAlbumCoverFallback']) ??
        _nonEmpty(widget.initialArtistData?['selectedAlbumCoverFallback']) ??
        _firstReleaseCover(albums) ??
        _firstReleaseCover(singlesAndEPs) ??
        _firstReleaseCover(compilations);
    final pictureUrl = _avatarUrl(picture);
    maybeExtractDominantColor(pictureUrl);
    final avatarSize = context.scaleSize(140);

    final hasAccount = _hasAccount();
    final followed = ref.watch(tidalArtistFollowedProvider(widget.artistId));
    final bio = ref.watch(tidalArtistBioProvider(widget.artistId)).value;
    final aboutText = bio != null && bio.trim().isNotEmpty ? bio.trim() : null;

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
                  // Artist Picture, glowing with the extracted dominant color
                  Center(
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
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
                      child: ClipOval(
                        child: SizedBox(
                          width: avatarSize,
                          height: avatarSize,
                          child: pictureUrl != null
                              ? _withCoverHero(
                                  CachedImageWidget(
                                    imagePath: pictureUrl,
                                    width: avatarSize,
                                    height: avatarSize,
                                    useThumbnail: true,
                                    thumbnailWidth: 320,
                                    thumbnailHeight: 320,
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
                  SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
                  // Unified action bar, themed with the photo's color.
                  // TIDAL-specific mapping: the first segment is Follow
                  // (no favorite concept for artists) and Queue is dropped.
                  StaggeredEntrance(
                    index: 0,
                    child: DetailActionCapsule(
                      isFavorite: followed,
                      onToggleFavorite: hasAccount ? _toggleFollow : null,
                      onShuffle: () => _shuffleAll(topTracks),
                      onPlay: () => _playAll(topTracks),
                      onQueue: null,
                      onMore: _showMore,
                      primaryColor: dominantColor,
                      toggleActiveIcon: LucideIcons.userCheck,
                      toggleInactiveIcon: LucideIcons.userPlus,
                      toggleActiveTooltip: 'Unfollow artist',
                      toggleInactiveTooltip: 'Follow artist',
                    ),
                  ),
                  // About — only when the TIDAL biography is available.
                  if (aboutText != null) ...[
                    SizedBox(height: context.scaleSize(AppConstants.spacingLg)),
                    StaggeredEntrance(
                      index: 1,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _sectionTitle(context, 'About'),
                          FetchedDescription(
                            text: aboutText,
                            sourceLabel: 'TIDAL',
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (topTracks.isNotEmpty) ...[
                    SizedBox(height: context.scaleSize(AppConstants.spacingLg)),
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
                    SizedBox(height: context.scaleSize(AppConstants.spacingSm)),
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
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: context.scaleSize(AppConstants.spacingSm),
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
                                    placeholder:
                                        const FlickArtworkPlaceholder(),
                                    errorWidget:
                                        const FlickArtworkPlaceholder(),
                                  )
                                : const FlickArtworkPlaceholder(),
                          ),
                        ),
                        title: SongTitleRow(
                          title: song.title,
                          isExplicit: song.isExplicit,
                          isAtmos: song.isAtmos,
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
                                song.album ?? song.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            if ((song.bitDepth ?? 0) >= 24) const HiResBadge(),
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
                        onTap: () => _playSong(song, topTracks),
                      ),
                    ),
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
                startIndex: 2,
              ),
            ),

          // Singles & EPs Section (Horizontal Carousel)
          if (singlesAndEPs.isNotEmpty)
            SliverToBoxAdapter(
              child: _buildHorizontalReleaseSection(
                context,
                title: 'Singles & EPs',
                items: singlesAndEPs,
                startIndex: 4,
              ),
            ),

          // Compilations Section (Horizontal Carousel)
          if (compilations.isNotEmpty)
            SliverToBoxAdapter(
              child: _buildHorizontalReleaseSection(
                context,
                title: 'Compilations',
                items: compilations,
                startIndex: 6,
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

  Widget _buildHorizontalReleaseSection(
    BuildContext context, {
    required String title,
    required List<Map<String, dynamic>> items,
    required int startIndex,
  }) {
    if (items.isEmpty) return const SizedBox.shrink();

    final screenWidth = MediaQuery.of(context).size.width;
    final cardWidth = ((screenWidth - 48) / 2.2).clamp(130.0, 160.0);
    final sectionHeight = cardWidth + 62.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        StaggeredEntrance(
          index: startIndex,
          child: Padding(
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
        ),
        SizedBox(
          height: sectionHeight,
          child: ListView.separated(
            padding: EdgeInsets.symmetric(
              horizontal: context.scaleSize(AppConstants.spacingLg),
            ),
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            // Perf: bound cacheExtent to limit offscreen image decodes during scroll.
            // ignore: deprecated_member_use
            cacheExtent: 100,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) => StaggeredEntrance(
              index: startIndex + 1 + index,
              child: SizedBox(
                width: cardWidth,
                child: _buildAlbumHorizontalCard(
                  context,
                  items[index],
                  cardWidth,
                ),
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
    // Perf: 320px is retina-sharp for ~140px cards and drops bandwidth/decode
    // CPU by ~75% compared to 640px.
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

    return PressScale(
      child: GestureDetector(
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
                        width: size,
                        height: size,
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
                if (isHiRes || isLossless) ...[
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
                if (album['explicit'] == true) ...[
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
