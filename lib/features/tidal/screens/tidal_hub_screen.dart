import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_constants.dart';
import '../../../widgets/common/blurred_song_background.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/navigation_helper.dart';
import '../../../core/utils/responsive.dart';
import '../../../models/sources/tidal_models.dart';
import '../../../services/player_service.dart';
import '../../../services/sources/tidal_service.dart';
import '../../../widgets/common/cached_image_widget.dart';
import '../../../widgets/common/flick_artwork_placeholder.dart';
import '../providers/tidal_providers.dart';
import '../widgets/press_scale.dart';
import '../widgets/staggered_entrance.dart';
import '../widgets/tidal_error_widget.dart';
import '../widgets/tidal_now_playing_title.dart';
import '../widgets/tidal_shimmer.dart';
import '../widgets/tidal_tab_pill.dart';
import '../../player/widgets/add_to_playlist_sheet.dart';
import '../../favorites/screens/favorites_screen.dart';
import 'tidal_album_screen.dart';
import 'tidal_artist_screen.dart';
import 'tidal_mix_screen.dart';
import 'tidal_playlist_screen.dart';

class TidalHubScreen extends ConsumerStatefulWidget {
  const TidalHubScreen({super.key});

  @override
  ConsumerState<TidalHubScreen> createState() => _TidalHubScreenState();
}

class _TidalHubScreenState extends ConsumerState<TidalHubScreen> {
  static const double _kTidalSectionGap = AppConstants.spacingMd;
  static const double _kTidalTitleContentGap = 8;

  // 136px cover + its 6px internal gap + 15px (13px title line) +
  // 2px subtitle gap + 13px (11px subtitle line), measured with Flutter's
  // default text metrics for these styles. This fits the tallest carousel item.
  static const double _kTidalCarouselSectionHeight = 172;

  bool _isSigningIn = false;
  String? _verificationUri;
  String? _signInError;
  String _activeFeedSlug = 'static';

  Future<void> _signIn() async {
    setState(() {
      _isSigningIn = true;
      _verificationUri = null;
      _signInError = null;
    });

    try {
      final server = await ref
          .read(tidalServerProvider.notifier)
          .signIn(
            onVerificationLink: (uri) {
              if (mounted) {
                setState(() => _verificationUri = uri);
              }
            },
          );

      if (mounted) {
        setState(() {
          _isSigningIn = false;
          _verificationUri = null;
        });
        if (server != null) {
          ref.invalidate(tidalHomeFeedProvider(_activeFeedSlug));
          ref.invalidate(tidalUserPlaylistsProvider);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSigningIn = false;
          _signInError = e.toString();
        });
      }
    }
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Sign out of TIDAL?',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: const Text(
          'You will need to sign in again to browse and stream tracks from TIDAL.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(tidalServerProvider.notifier).signOut();
    }
  }

  /// Hero tag for a hub cover, derived from the ID that the destination
  /// screen receives in [_openHomeItem]. `scope` + `index` keep tags unique
  /// within the hub route (the same item may appear in more than one
  /// section, and duplicate tags within a route crash hero transitions).
  ///
  /// Returns null for items without a matching detail screen (tracks, My
  /// Tracks) — their covers are not hero-wrapped.
  String? _coverHeroTag(TidalHomeItem item, String scope, int index) {
    if (item.isMyTracks) return null;
    final String destId;
    // Same precedence as _openHomeItem.
    if (item.isMix) {
      destId = item.raw['mixId']?.toString() ?? item.id;
    } else if (item.isPlaylist) {
      destId =
          item.raw['uuid']?.toString() ??
          item.raw['artifactId']?.toString() ??
          item.id;
    } else if (item.isAlbum) {
      destId = item.raw['artifactId']?.toString() ?? item.id;
    } else if (item.isArtist) {
      destId = item.raw['artifactId']?.toString() ?? item.id;
    } else {
      return null;
    }
    if (destId.isEmpty) return null;
    return 'tidal-cover-$destId@$scope-$index';
  }

  void _openHomeItem(TidalHomeItem item, {String? heroTag}) {
    if (item.isMyTracks) {
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const FavoritesScreen()));
      return;
    }

    if (item.isMix) {
      final mixId = item.raw['mixId']?.toString() ?? item.id;
      if (mixId.isNotEmpty) {
        NavigationHelper.pushSharedAxis(
          context,
          (_) => TidalMixScreen(
            mixId: mixId,
            initialTitle: item.title,
            initialImageUrl: item.imageUrl,
            initialSubtitle: item.subtitle,
            heroTag: heroTag,
          ),
        );
        return;
      }
    }

    if (item.isPlaylist) {
      final plId =
          item.raw['uuid']?.toString() ??
          item.raw['artifactId']?.toString() ??
          item.id;
      if (plId.isNotEmpty) {
        NavigationHelper.pushSharedAxis(
          context,
          (_) => TidalPlaylistScreen(
            playlistId: plId,
            initialTitle: item.title,
            initialImageUrl: item.imageUrl,
            initialSubtitle: item.subtitle,
            initialTrackCount: (item.raw['numberOfTracks'] as num?)?.toInt(),
            heroTag: heroTag,
          ),
        );
        return;
      }
    }

    if (item.isAlbum) {
      final albId = item.raw['artifactId']?.toString() ?? item.id;
      if (albId.isNotEmpty) {
        NavigationHelper.pushSharedAxis(
          context,
          (_) => TidalAlbumScreen(
            albumId: albId,
            initialAlbumData: item.raw,
            heroTag: heroTag,
          ),
        );
        return;
      }
    }

    if (item.isArtist) {
      final artId = item.raw['artifactId']?.toString() ?? item.id;
      if (artId.isNotEmpty) {
        NavigationHelper.pushSharedAxis(
          context,
          (_) => TidalArtistScreen(
            artistId: artId,
            initialArtistData: item.raw,
            heroTag: heroTag,
          ),
        );
        return;
      }
    }

    if (item.isTrack) {
      _playTrackItem(item);
      return;
    }

    // Ultimate fallback based on identifier shape
    if (item.id.contains('-') && item.id.length >= 32) {
      NavigationHelper.pushSharedAxis(
        context,
        (_) => TidalPlaylistScreen(
          playlistId: item.id,
          initialTitle: item.title,
          initialImageUrl: item.imageUrl,
        ),
      );
      return;
    }

    if (item.id.isNotEmpty && int.tryParse(item.id) != null) {
      NavigationHelper.pushSharedAxis(
        context,
        (_) => TidalAlbumScreen(albumId: item.id, initialAlbumData: item.raw),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Cannot open ${item.title.isNotEmpty ? item.title : 'this item'}',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _playTrackItem(TidalHomeItem item) async {
    final server = await ref.read(tidalServerProvider.future);
    if (server == null) return;
    final song = TidalService.makeEphemeralSong(server, item.raw);
    PlayerService().play(song, playlist: [song]);
    if (mounted) {
      NavigationHelper.navigateToFullPlayer(
        context,
        heroTag: 'tidal_track_${item.id}',
      );
    }
  }

  void _showItemActionSheet(TidalHomeItem item) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppConstants.radiusLg),
        ),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: item.imageUrl != null
                        ? CachedImageWidget(
                            imagePath: item.imageUrl!,
                            fit: BoxFit.cover,
                            placeholder: const FlickArtworkPlaceholder(),
                            errorWidget: const FlickArtworkPlaceholder(),
                          )
                        : const FlickArtworkPlaceholder(),
                  ),
                ),
                title: Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(item.subtitle ?? item.type, maxLines: 1),
              ),
              const Divider(color: AppColors.glassBorder),
              ListTile(
                leading: const Icon(LucideIcons.play, color: Color(0xD9FFFFFF)),
                title: const Text('Open / Play'),
                onTap: () {
                  Navigator.pop(ctx);
                  _openHomeItem(item);
                },
              ),
              if (item.isTrack)
                ListTile(
                  leading: const Icon(
                    LucideIcons.listPlus,
                    color: Color(0xD9FFFFFF),
                  ),
                  title: const Text('Add to Playlist'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final server = await ref.read(tidalServerProvider.future);
                    if (server != null && context.mounted) {
                      final song = TidalService.makeEphemeralSong(
                        server,
                        item.raw,
                      );
                      AddToPlaylistSheet.show(context, song);
                    }
                  },
                ),
              if (item.isTrack ||
                  item.isArtist ||
                  item.isMix ||
                  item.raw['mixes'] != null)
                ListTile(
                  leading: const Icon(
                    LucideIcons.radio,
                    color: Color(0xD9FFFFFF),
                  ),
                  title: const Text('Start Radio'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final server = await ref.read(tidalServerProvider.future);
                    if (server == null || !context.mounted) return;

                    final mixId = await TidalService.instance.resolveRadioMixId(
                      server,
                      item,
                    );
                    if (!context.mounted) return;

                    if (mixId != null && mixId.isNotEmpty) {
                      NavigationHelper.pushSharedAxis(
                        context,
                        (_) => TidalMixScreen(
                          mixId: mixId,
                          initialTitle: '${item.title} Radio',
                          initialImageUrl: item.imageUrl,
                          initialSubtitle: item.subtitle,
                        ),
                      );
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Radio is not available for this item'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLoggedIn = ref.watch(tidalAuthStateProvider);

    return BlurredSongBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Row(
            children: [
              // Official TIDAL logo (vector): diamond mark + TIDAL text.
              // SVG viewBox is 960x960 with content vertically centered,
              // so nudge up slightly for optical alignment.
              Transform.translate(
                offset: const Offset(0, -1.5),
                child: SvgPicture.asset(
                  'assets/icons/tidal_logo.svg',
                  height: 22,
                  fit: BoxFit.contain,
                ),
              ),
            ],
          ),
          actions: [
            if (isLoggedIn) ...[
              IconButton(
                icon: const Icon(
                  LucideIcons.logOut,
                  color: AppColors.textSecondary,
                ),
                tooltip: 'Sign out',
                onPressed: _signOut,
              ),
            ],
          ],
        ),
        body: isLoggedIn ? _buildLoggedInView() : _buildSignInView(),
      ),
    );
  }

  Widget _buildSignInView() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(context.scaleSize(AppConstants.spacingLg)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(height: context.scaleSize(AppConstants.spacingXl)),
          Container(
            width: context.scaleSize(96),
            height: context.scaleSize(96),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF002233), Color(0xFF005577)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(AppConstants.radiusXl),
              border: Border.all(color: const Color(0x45FFFFFF), width: 1.5),
            ),
            child: Center(
              child: SvgPicture.asset(
                'assets/icons/tidal_logo.svg',
                width: 56,
                fit: BoxFit.contain,
              ),
            ),
          ),
          SizedBox(height: context.scaleSize(AppConstants.spacingLg)),
          const Text(
            'TIDAL HiFi & Master',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: context.scaleSize(AppConstants.spacingSm)),
          const Text(
            'Experience bit-perfect streaming directly to your USB DAC. '
            'Search millions of songs, browse albums, and stream lossless audio.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14,
              height: 1.4,
            ),
          ),
          SizedBox(height: context.scaleSize(AppConstants.spacingXl)),

          if (_isSigningIn) ...[
            const CircularProgressIndicator(color: Color(0xD9FFFFFF)),
            SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
            const Text(
              'Waiting for TIDAL authorization...',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
            if (_verificationUri != null) ...[
              SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
              Container(
                padding: EdgeInsets.all(
                  context.scaleSize(AppConstants.spacingMd),
                ),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                  border: Border.all(color: const Color(0x33FFFFFF)),
                ),
                child: Column(
                  children: [
                    const Text(
                      'If the browser did not open automatically:',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      _verificationUri!,
                      style: const TextStyle(
                        color: Color(0xD9FFFFFF),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () => launchUrl(
                        Uri.parse(_verificationUri!),
                        mode: LaunchMode.externalApplication,
                      ),
                      icon: const Icon(LucideIcons.externalLink, size: 16),
                      label: const Text('Open Browser'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xD9FFFFFF),
                        side: const BorderSide(color: Color(0xD9FFFFFF)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ] else ...[
            SizedBox(
              width: double.infinity,
              height: context.scaleSize(48),
              child: FilledButton.icon(
                onPressed: _signIn,
                icon: const Icon(LucideIcons.logIn, size: 20),
                label: const Text(
                  'Sign in with TIDAL',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF00A2C7),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                  ),
                ),
              ),
            ),
          ],

          if (_signInError != null) ...[
            SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
            Text(
              _signInError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLoggedInView() {
    // The playlist section below watches its own provider inside a scoped
    // Consumer, so a playlist update rebuilds only that section instead of the
    // whole screen. The feed is watched here because its sections have to be
    // siblings in the scroll view to stay lazily inflated.
    final feedAsync = ref.watch(tidalHomeFeedProvider(_activeFeedSlug));

    // Sections are direct children of the scroll view instead of a single
    // Column child. SliverChildListDelegate only inflates the children in (and
    // near) the viewport, so the old Column wrapper was what kept every
    // carousel, shortcut grid and compact grid alive for the whole session.
    //
    // A CustomScrollView would not change that: ListView already virtualizes
    // element inflation; the Column was the only thing defeating it.
    final Widget list = ListView(
      // Keeps the scroll offset across the loading/data swap below (and across
      // a vibes-tab switch), like the single stable ListView this replaced.
      key: const PageStorageKey<String>('tidal-hub-feed'),
      // Scroll-jank fix (Option A from the hub scroll diagnosis): the
      // default 250px cache covered barely one ~253px carousel section, so
      // every section entry paid a remount + cover decode on a scroll frame.
      // 1000px keeps ~4 sections inflated ahead, giving decode lead time.
      // Trade-off: a few more live sections/memory, still far below the
      // pre-virtualization whole-feed footprint.
      // ignore: deprecated_member_use
      cacheExtent: 1000,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.all(context.scaleSize(AppConstants.spacingMd)),
      children: [
        ...feedAsync.when(
          loading: () => const [TidalHubFeedSkeleton()],
          error: (err, _) => [
            TidalErrorWidget(
              error: err,
              contextLabel: 'Could not load TIDAL home feed',
              onRetry: () {
                invalidateTidalHubCache(feedSlug: _activeFeedSlug);
                ref.invalidate(tidalHomeFeedProvider(_activeFeedSlug));
              },
            ),
          ],
          data: _buildFeedSectionChildren,
        ),
        SizedBox(height: context.scaleSize(_kTidalSectionGap)),

        SizedBox(height: context.scaleSize(AppConstants.spacingXl * 2)),
      ],
    );

    return RefreshIndicator(
      color: const Color(0xD9FFFFFF),
      backgroundColor: AppColors.surface,
      onRefresh: () async {
        // Manual refresh reloads the active feed.
        invalidateTidalHubCache(feedSlug: _activeFeedSlug);
        final _ = await ref.refresh(
          tidalHomeFeedProvider(_activeFeedSlug).future,
        );
      },
      // The entrance window starts when the feed content first builds (not at
      // screen open), so the stagger still plays when the async feed resolves
      // after the screen has been opened.
      child: feedAsync.hasValue ? StaggeredEntranceWindow(child: list) : list,
    );
  }

  /// Builds the feed sections as individual scroll children, in display order.
  List<Widget> _buildFeedSectionChildren(TidalHomeFeed feed) {
    // The default 'static' feed ("For You") is not exposed as a
    // selectable tab by the API, so prepend a synthetic pill for it.
    const forYouTab = TidalHomeTab(
      name: 'For You',
      type: 'static',
      slug: 'static',
    );
    final displayTabs = [
      forYouTab,
      ...feed.tabs.where((tab) {
        final name = tab.name.trim().toLowerCase();
        final slug = tab.slug.trim().toLowerCase();
        return name != 'suggested' && slug != 'static' && slug != 'suggested';
      }),
    ];

    // One-shot staggered entrance across the feed sections; the
    // index counter drives the per-item delay, and the surrounding
    // StaggeredEntranceWindow (screen body) makes sure children
    // mounted later — scrolled into view — don't re-animate.
    var entranceIndex = 0;
    final entranceChildren = <Widget>[];
    final lastFeedSectionIndex = _lastFeedSectionIndex(feed);

    // Vibes Tabs Pills ('For You' first, then the API tabs)
    if (displayTabs.isNotEmpty) {
      entranceChildren.add(
        StaggeredEntrance(
          index: entranceIndex++,
          child: SizedBox(
            height: 38,
            child: ListView.builder(
              // Own PageStorage slot: without a key this row shared one
              // slot with every other keyless horizontal list under the
              // vertical feed's PageStorageKey, so a remount after scroll
              // restored another row's offset (see carousel/compact below).
              key: const PageStorageKey<String>('tidal-hub-tabs'),
              scrollDirection: Axis.horizontal,
              // Perf (2026-10-13): reduced cacheExtent to limit
              // offscreen image decodes during scroll.
              // ignore: deprecated_member_use
              cacheExtent: 100,
              itemCount: displayTabs.length,
              itemBuilder: (context, index) {
                final tab = displayTabs[index];
                final isActive = tab.slug == _activeFeedSlug;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: TidalTabPill(
                    label: tab.name,
                    selected: isActive,
                    onTap: () {
                      // Tapping the active pill toggles back to
                      // the default "For You" feed.
                      setState(() {
                        _activeFeedSlug = tab.slug == _activeFeedSlug
                            ? 'static'
                            : tab.slug;
                      });
                    },
                  ),
                );
              },
            ),
          ),
        ),
      );
      if (lastFeedSectionIndex >= 0) {
        entranceChildren.add(
          SizedBox(height: context.scaleSize(_kTidalSectionGap)),
        );
      }
    }

    // Quick-Access Shortcut Grid (SHORTCUT_LIST)
    for (var i = 0; i < feed.sections.length; i++) {
      final sec = feed.sections[i];
      if (!sec.isShortcutList) continue;
      entranceChildren.add(
        StaggeredEntrance(
          index: entranceIndex++,
          child: _buildShortcutGrid(
            sec,
            scope: 'sec$i',
            includeTrailingGap: i != lastFeedSectionIndex,
          ),
        ),
      );
    }

    // Adaptive Sections (Track list, Compact Grid for Recently played, or Carousel)
    for (var i = 0; i < feed.sections.length; i++) {
      final sec = feed.sections[i];
      if (sec.isShortcutList) continue;
      entranceChildren.add(
        StaggeredEntrance(
          index: entranceIndex++,
          child: _buildAdaptiveSection(
            sec,
            scope: 'sec$i',
            includeTrailingGap: i != lastFeedSectionIndex,
          ),
        ),
      );
    }

    return entranceChildren;
  }

  int _lastFeedSectionIndex(TidalHomeFeed feed) {
    final orderedSections = [
      ...feed.sections.where((section) => section.isShortcutList),
      ...feed.sections.where((section) => !section.isShortcutList),
    ];
    for (var i = orderedSections.length - 1; i >= 0; i--) {
      if (orderedSections[i].items.isNotEmpty) {
        return feed.sections.indexOf(orderedSections[i]);
      }
    }
    return -1;
  }

  Widget _buildShortcutGrid(
    TidalHomeSection section, {
    String scope = 'sc',
    bool includeTrailingGap = true,
  }) {
    if (section.items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (section.title.trim().isNotEmpty &&
            section.title != 'Shortcuts') ...[
          Text(
            section.title,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: _kTidalTitleContentGap),
        ],
        // Two-column shortcut layout built from Rows instead of a
        // `shrinkWrap` GridView: a never-scrolling nested viewport measures
        // every tile eagerly and adds a RenderViewport per section.
        _buildShortcutRows(section, scope),
        if (includeTrailingGap)
          SizedBox(height: context.scaleSize(_kTidalSectionGap)),
      ],
    );
  }

  /// Two columns, at most 8 tiles: Rows + Expanded reproduce the exact
  /// 56px-tile / 8px-gap grid without a nested viewport.
  Widget _buildShortcutRows(TidalHomeSection section, String scope) {
    final items = section.items.take(8).toList();
    const gap = 8.0;
    return Column(
      children: [
        for (var row = 0; row < items.length; row += 2)
          Padding(
            padding: EdgeInsets.only(bottom: row + 2 < items.length ? gap : 0),
            child: Row(
              children: [
                Expanded(child: _buildShortcutTile(scope, items[row], row)),
                const SizedBox(width: gap),
                Expanded(
                  child: row + 1 < items.length
                      ? _buildShortcutTile(scope, items[row + 1], row + 1)
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildShortcutTile(String scope, TidalHomeItem item, int index) {
    final effectiveImage = (item.imageUrl != null && item.imageUrl!.isNotEmpty)
        ? TidalService.resizedCoverUrl(item.imageUrl, 160)
        : null;
    final heroTag = _coverHeroTag(item, scope, index);
    final cover = (effectiveImage != null && effectiveImage.isNotEmpty)
        ? CachedImageWidget(
            imagePath: effectiveImage,
            width: 56,
            height: 56,
            useThumbnail: true,
            thumbnailWidth: 160,
            thumbnailHeight: 160,
            fit: BoxFit.cover,
            placeholder: const ColoredBox(
              color: AppColors.glassBackgroundStrong,
            ),
            errorWidget: const ColoredBox(
              color: AppColors.glassBackgroundStrong,
            ),
          )
        : null;
    return PressScale(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppConstants.radiusSm),
          onTap: () => _openHomeItem(item, heroTag: heroTag),
          onLongPress: () => _showItemActionSheet(item),
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.glassBackgroundStrong,
              borderRadius: BorderRadius.circular(AppConstants.radiusSm),
              border: Border.all(color: AppColors.glassBorder),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(AppConstants.radiusSm),
                  ),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: cover == null
                        ? const ColoredBox(
                            color: AppColors.glassBackgroundStrong,
                            child: Center(
                              child: Icon(
                                LucideIcons.music,
                                size: 24,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          )
                        : (heroTag == null
                              ? cover
                              : Hero(tag: heroTag, child: cover)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHorizontalCarousel(
    TidalHomeSection section, {
    String scope = 'c',
    bool includeTrailingGap = true,
  }) {
    if (section.items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (section.title.trim().isNotEmpty)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                section.title,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        if (section.title.trim().isNotEmpty)
          const SizedBox(height: _kTidalTitleContentGap),
        SizedBox(
          height: _kTidalCarouselSectionHeight,
          child: ListView.builder(
            // Own PageStorage slot per section (scope is 'sec$i'): without
            // this key, PageStorage computed the slot from the ancestor
            // vertical feed's PageStorageKey alone, so ALL carousels shared
            // one slot — a remounted carousel restored another carousel's
            // (or the feed's) offset, clamped to its own end.
            key: PageStorageKey<String>('tidal-hub-carousel-$scope'),
            scrollDirection: Axis.horizontal,
            // Perf (2026-10-13): reduced cacheExtent to limit
            // offscreen image decodes during scroll.
            // ignore: deprecated_member_use
            cacheExtent: 100,
            itemCount: section.items.length,
            itemBuilder: (context, index) {
              final item = section.items[index];
              final effectiveImage =
                  (item.imageUrl != null && item.imageUrl!.isNotEmpty)
                  ? TidalService.resizedCoverUrl(item.imageUrl, 320)
                  : null;
              final heroTag = _coverHeroTag(item, scope, index);
              final cover =
                  (effectiveImage != null && effectiveImage.isNotEmpty)
                  ? CachedImageWidget(
                      imagePath: effectiveImage,
                      width: 136,
                      height: 136,
                      useThumbnail: true,
                      thumbnailWidth: 320,
                      thumbnailHeight: 320,
                      fit: BoxFit.cover,
                      placeholder: const ColoredBox(
                        color: AppColors.glassBackgroundStrong,
                      ),
                      errorWidget: const ColoredBox(
                        color: AppColors.glassBackgroundStrong,
                      ),
                    )
                  : null;
              return PressScale(
                child: Container(
                  width: 136,
                  margin: const EdgeInsets.only(right: 12),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(
                        AppConstants.radiusMd,
                      ),
                      onTap: () => _openHomeItem(item, heroTag: heroTag),
                      onLongPress: () => _showItemActionSheet(item),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Artwork card with Play button overlay
                          Stack(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  AppConstants.radiusMd,
                                ),
                                child: SizedBox(
                                  width: 136,
                                  height: 136,
                                  child: cover == null
                                      ? const ColoredBox(
                                          color:
                                              AppColors.glassBackgroundStrong,
                                          child: Center(
                                            child: Icon(
                                              LucideIcons.music,
                                              size: 36,
                                              color: AppColors.textSecondary,
                                            ),
                                          ),
                                        )
                                      : (heroTag == null
                                            ? cover
                                            : Hero(tag: heroTag, child: cover)),
                                ),
                              ),
                              Positioned(
                                right: 6,
                                bottom: 6,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () =>
                                      _openHomeItem(item, heroTag: heroTag),
                                  child: const Icon(
                                    LucideIcons.play,
                                    size: 20,
                                    color: Color(0xD9FFFFFF),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (item.subtitle != null &&
                              item.subtitle!.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              item.subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        if (includeTrailingGap)
          SizedBox(height: context.scaleSize(_kTidalSectionGap)),
      ],
    );
  }

  Widget _buildAdaptiveSection(
    TidalHomeSection sec, {
    required String scope,
    bool includeTrailingGap = true,
  }) {
    if (sec.sectionType == 'TRACK_LIST') {
      return _buildTrackListSection(
        sec,
        includeTrailingGap: includeTrailingGap,
      );
    }
    if (sec.sectionType == 'COMPACT_GRID_CARD' ||
        sec.title.toLowerCase().contains('recently played')) {
      return _buildCompactGridSection(
        sec,
        scope: scope,
        includeTrailingGap: includeTrailingGap,
      );
    }
    return _buildHorizontalCarousel(
      sec,
      scope: scope,
      includeTrailingGap: includeTrailingGap,
    );
  }

  Widget _buildTrackListSection(
    TidalHomeSection section, {
    bool includeTrailingGap = true,
  }) {
    if (section.items.isEmpty) return const SizedBox.shrink();

    final displayItems = section.items.take(6).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (section.title.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: _kTidalTitleContentGap),
            child: Text(
              section.title,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        Container(
          decoration: BoxDecoration(
            color: AppColors.glassBackground,
            borderRadius: BorderRadius.circular(AppConstants.radiusMd),
            border: Border.all(color: AppColors.glassBorder),
          ),
          // Column instead of shrinkWrap ListView.separated: shrinkWrap
          // already defeats builder laziness, so a Column avoids the
          // nested Scrollable/Viewport overhead for these 6 items.
          child: Column(
            children: [
              for (int i = 0; i < displayItems.length; i++) ...[
                if (i > 0)
                  const Divider(
                    color: AppColors.glassBorder,
                    height: 1,
                    indent: 56,
                  ),
                _buildTrackListTile(displayItems[i]),
              ],
            ],
          ),
        ),
        if (includeTrailingGap)
          SizedBox(height: context.scaleSize(_kTidalSectionGap)),
      ],
    );
  }

  Widget _buildTrackListTile(TidalHomeItem item) {
    final img = (item.imageUrl != null && item.imageUrl!.isNotEmpty)
        ? TidalService.resizedCoverUrl(item.imageUrl, 160)
        : null;
    return PressScale(
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(AppConstants.radiusSm),
          child: SizedBox(
            width: 42,
            height: 42,
            child: (img != null && img.isNotEmpty)
                ? CachedImageWidget(
                    imagePath: img,
                    width: 42,
                    height: 42,
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
        title: TidalNowPlayingTitle(
          title: item.title,
          tidalTrackId: item.id,
          isExplicit: item.isExplicit,
          isAtmos: item.isAtmos,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          item.subtitle ?? item.type,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(
                LucideIcons.play,
                size: 16,
                color: Color(0xD9FFFFFF),
              ),
              onPressed: () => _playTrackItem(item),
            ),
            IconButton(
              icon: const Icon(
                LucideIcons.ellipsisVertical,
                size: 16,
                color: AppColors.textSecondary,
              ),
              onPressed: () => _showItemActionSheet(item),
            ),
          ],
        ),
        onTap: () => _playTrackItem(item),
        onLongPress: () => _showItemActionSheet(item),
      ),
    );
  }

  Widget _buildCompactGridSection(
    TidalHomeSection section, {
    String scope = 'g',
    bool includeTrailingGap = true,
  }) {
    if (section.items.isEmpty) return const SizedBox.shrink();

    final items = section.items;
    final pairCount = (items.length / 2).ceil();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (section.title.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: _kTidalTitleContentGap),
            child: Text(
              section.title,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        SizedBox(
          height: 124,
          child: ListView.builder(
            // Own PageStorage slot per section, same shared-slot bug as the
            // carousel above (keyless horizontal lists under the vertical
            // feed's PageStorageKey all restored one common offset).
            key: PageStorageKey<String>('tidal-hub-compact-$scope'),
            scrollDirection: Axis.horizontal,
            // Perf (2026-10-13): reduced cacheExtent to limit
            // offscreen image decodes during scroll.
            // ignore: deprecated_member_use
            cacheExtent: 100,
            itemCount: pairCount,
            itemBuilder: (context, colIndex) {
              final topIndex = colIndex * 2;
              final bottomIndex = topIndex + 1;
              final topItem = items[topIndex];
              final bottomItem = bottomIndex < items.length
                  ? items[bottomIndex]
                  : null;

              return Container(
                width: 220,
                margin: const EdgeInsets.only(right: 10),
                child: Column(
                  children: [
                    _buildCompactCard(topItem, scope: scope, index: topIndex),
                    const SizedBox(height: 8),
                    if (bottomItem != null)
                      _buildCompactCard(
                        bottomItem,
                        scope: scope,
                        index: bottomIndex,
                      )
                    else
                      const SizedBox(height: 56),
                  ],
                ),
              );
            },
          ),
        ),
        if (includeTrailingGap)
          SizedBox(height: context.scaleSize(_kTidalSectionGap)),
      ],
    );
  }

  Widget _buildCompactCard(
    TidalHomeItem item, {
    required String scope,
    required int index,
  }) {
    final img = (item.imageUrl != null && item.imageUrl!.isNotEmpty)
        ? TidalService.resizedCoverUrl(item.imageUrl, 160)
        : null;
    final heroTag = _coverHeroTag(item, scope, index);
    final cover = (img != null && img.isNotEmpty)
        ? CachedImageWidget(
            imagePath: img,
            width: 56,
            height: 56,
            useThumbnail: true,
            thumbnailWidth: 160,
            thumbnailHeight: 160,
            fit: BoxFit.cover,
            placeholder: const FlickArtworkPlaceholder(),
            errorWidget: const FlickArtworkPlaceholder(),
          )
        : null;
    return PressScale(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppConstants.radiusSm),
          onTap: () => _openHomeItem(item, heroTag: heroTag),
          onLongPress: () => _showItemActionSheet(item),
          child: Container(
            height: 56,
            decoration: BoxDecoration(
              color: AppColors.glassBackgroundStrong,
              borderRadius: BorderRadius.circular(AppConstants.radiusSm),
              border: Border.all(color: AppColors.glassBorder),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(AppConstants.radiusSm),
                  ),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: cover == null
                        ? const FlickArtworkPlaceholder()
                        : (heroTag == null
                              ? cover
                              : Hero(tag: heroTag, child: cover)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (item.subtitle != null &&
                          item.subtitle!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          item.subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(
                    LucideIcons.play,
                    size: 14,
                    color: const Color(0xCCFFFFFF),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
