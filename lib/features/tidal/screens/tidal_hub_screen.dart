import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animations/animations.dart';
import 'package:file_picker/file_picker.dart';
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
import '../../../widgets/common/song_badges.dart';
import '../providers/tidal_providers.dart';
import '../widgets/press_scale.dart';
import '../widgets/staggered_entrance.dart';
import '../widgets/tidal_error_widget.dart';
import '../widgets/tidal_import_playlist_dialog.dart';
import '../widgets/tidal_playlist_cover_widget.dart';
import '../widgets/tidal_shimmer.dart';
import '../widgets/tidal_tab_pill.dart';
import '../../player/widgets/add_to_playlist_sheet.dart';
import '../../favorites/screens/favorites_screen.dart';
import 'tidal_album_screen.dart';
import 'tidal_artist_screen.dart';
import 'tidal_mix_screen.dart';
import 'tidal_playlist_screen.dart';
import 'tidal_search_screen.dart';
import 'tidal_liked_songs_screen.dart';
import 'package:flick/core/utils/error_display.dart';

class TidalHubScreen extends ConsumerStatefulWidget {
  const TidalHubScreen({super.key});

  @override
  ConsumerState<TidalHubScreen> createState() => _TidalHubScreenState();
}

class _TidalHubScreenState extends ConsumerState<TidalHubScreen> {
  bool _isSigningIn = false;
  String? _verificationUri;
  String? _signInError;
  String _activeFeedSlug = 'static';

  // One-shot gate for the playlist entrance window: once the window closes,
  // later remounts of the playlist section (the virtualized feed disposes
  // scrolled-out sections) must render statically instead of replaying the
  // entrance on every scroll back up.
  bool _playlistEntranceClosed = false;

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

  void _openSearch() {
    NavigationHelper.pushSharedAxis(
      context,
      (_) => const TidalSearchScreen(),
      // Lateral move to a sibling top-level destination: horizontal axis.
      transitionType: SharedAxisTransitionType.horizontal,
    );
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

  void _openPlaylistTracks(Map<String, dynamic> pl, {String? heroTag}) {
    final playlistId = pl['uuid']?.toString() ?? pl['id']?.toString();
    if (playlistId == null) return;
    final imageUrl = TidalService.extractPlaylistCover(pl, size: 640);
    NavigationHelper.pushSharedAxis(
      context,
      (_) => TidalPlaylistScreen(
        playlistId: playlistId,
        initialTitle: pl['title'] as String?,
        initialImageUrl: (imageUrl != null && imageUrl.isNotEmpty)
            ? imageUrl
            : null,
        initialTrackCount:
            ((pl['numberOfTracks'] ?? pl['numberOfItems']) as num?)?.toInt(),
        heroTag: heroTag,
      ),
    );
  }

  Future<void> _showCreatePlaylistDialog() async {
    final titleController = TextEditingController();
    final descController = TextEditingController();

    try {
      await showDialog<bool>(
        context: context,
        builder: (ctx) {
          bool isSubmitting = false;
          String? errorText;

          return StatefulBuilder(
            builder: (dialogCtx, setDialogState) {
              return AlertDialog(
                backgroundColor: AppColors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                  side: const BorderSide(color: AppColors.glassBorder),
                ),
                title: const Row(
                  children: [
                    Icon(
                      LucideIcons.listPlus,
                      color: Color(0xD9FFFFFF),
                      size: 22,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'New TIDAL Playlist',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: titleController,
                      autofocus: true,
                      style: const TextStyle(color: AppColors.textPrimary),
                      decoration: InputDecoration(
                        hintText: 'Playlist title',
                        hintStyle: const TextStyle(
                          color: AppColors.textSecondary,
                        ),
                        filled: true,
                        fillColor: AppColors.surfaceLight,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(
                            AppConstants.radiusSm,
                          ),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(
                            AppConstants.radiusSm,
                          ),
                          borderSide: const BorderSide(
                            color: Color(0xD9FFFFFF),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: descController,
                      style: const TextStyle(color: AppColors.textPrimary),
                      maxLines: 2,
                      decoration: InputDecoration(
                        hintText: 'Description (optional)',
                        hintStyle: const TextStyle(
                          color: AppColors.textSecondary,
                        ),
                        filled: true,
                        fillColor: AppColors.surfaceLight,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(
                            AppConstants.radiusSm,
                          ),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(
                            AppConstants.radiusSm,
                          ),
                          borderSide: const BorderSide(
                            color: Color(0xD9FFFFFF),
                          ),
                        ),
                      ),
                    ),
                    if (errorText != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        errorText!,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: isSubmitting
                        ? null
                        : () => Navigator.pop(dialogCtx, false),
                    child: const Text(
                      'Cancel',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  ),
                  FilledButton(
                    onPressed: isSubmitting
                        ? null
                        : () async {
                            final title = titleController.text.trim();
                            if (title.isEmpty) {
                              setDialogState(
                                () => errorText = 'Title is required',
                              );
                              return;
                            }
                            setDialogState(() {
                              isSubmitting = true;
                              errorText = null;
                            });
                            try {
                              final server = await ref.read(
                                tidalServerProvider.future,
                              );
                              if (server == null) {
                                setDialogState(() {
                                  isSubmitting = false;
                                  errorText = 'Not logged in to TIDAL';
                                });
                                return;
                              }
                              final result = await ref
                                  .read(tidalPlaylistMutationsProvider)
                                  .createPlaylist(
                                    server,
                                    title: title,
                                    description: descController.text.trim(),
                                  );
                              if (dialogCtx.mounted) {
                                Navigator.pop(dialogCtx, true);
                              }

                              final plId =
                                  result['uuid']?.toString() ??
                                  result['id']?.toString() ??
                                  (result['data'] as Map?)?['id']?.toString();
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Playlist "$title" created on TIDAL!',
                                    ),
                                    backgroundColor: AppColors.surface,
                                  ),
                                );
                                if (plId != null && plId.isNotEmpty) {
                                  NavigationHelper.pushSharedAxis(
                                    context,
                                    (_) => TidalPlaylistScreen(
                                      playlistId: plId,
                                      initialTitle: title,
                                      initialSubtitle: descController.text
                                          .trim(),
                                      initialTrackCount: 0,
                                    ),
                                  );
                                }
                              }
                            } catch (e) {
                              setDialogState(() {
                                isSubmitting = false;
                                errorText = e.toString();
                              });
                            }
                          },
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF00A2C7),
                      foregroundColor: Colors.white,
                    ),
                    child: isSubmitting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Text('Create'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      titleController.dispose();
      descController.dispose();
    }
  }

  Future<void> _importPlaylistFromJson() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );

      if (result == null ||
          result.files.isEmpty ||
          result.files.single.path == null) {
        return;
      }

      final file = File(result.files.single.path!);
      final content = await file.readAsString();
      final decoded = jsonDecode(content);

      List<dynamic> items;
      if (decoded is List) {
        items = decoded;
      } else if (decoded is Map<String, dynamic> && decoded['tracks'] is List) {
        items = decoded['tracks'] as List;
      } else if (decoded is Map<String, dynamic> && decoded['items'] is List) {
        items = decoded['items'] as List;
      } else {
        throw const FormatException('Expected a JSON array of tracks.');
      }

      final parsedTracks = <JsonPlaylistTrack>[];
      for (final item in items) {
        if (item is Map<String, dynamic>) {
          parsedTracks.add(JsonPlaylistTrack.fromJson(item));
        }
      }

      if (parsedTracks.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No valid track metadata found in the JSON file.'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
        return;
      }

      // Derive clean default playlist name from file name
      String defaultName = result.files.single.name;
      if (defaultName.toLowerCase().endsWith('.json')) {
        defaultName = defaultName.substring(0, defaultName.length - 5);
      }
      defaultName = defaultName
          .replaceAll(RegExp(r'[\-_]'), ' ')
          .replaceAll(RegExp(r'\s*\([^)]*\)'), '')
          .trim();
      if (defaultName.isEmpty) defaultName = 'Imported Playlist';

      if (mounted) {
        await TidalImportPlaylistDialog.show(
          context,
          tracks: parsedTracks,
          defaultPlaylistName: defaultName,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to read JSON: ${friendlyErrorMessage(e)}'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
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
                  LucideIcons.search,
                  color: AppColors.textSecondary,
                ),
                tooltip: 'Search',
                onPressed: _openSearch,
              ),
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
        SizedBox(height: context.scaleSize(AppConstants.spacingMd)),

        // 4. My Playlists Section
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'My Playlists',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(
                    LucideIcons.fileSpreadsheet,
                    size: 19,
                    color: Color(0xD9FFFFFF),
                  ),
                  tooltip: 'Import Playlist from JSON',
                  onPressed: _importPlaylistFromJson,
                ),
                IconButton(
                  icon: const Icon(
                    LucideIcons.plus,
                    size: 20,
                    color: Color(0xD9FFFFFF),
                  ),
                  tooltip: 'Create TIDAL Playlist',
                  onPressed: _showCreatePlaylistDialog,
                ),
                IconButton(
                  icon: const Icon(
                    LucideIcons.refreshCw,
                    size: 16,
                    color: AppColors.textSecondary,
                  ),
                  tooltip: 'Refresh Playlists',
                  onPressed: () {
                    unawaited(
                      ref
                          .read(tidalPlaylistMutationsProvider)
                          .refreshUserPlaylists(),
                    );
                    ref.invalidate(tidalLikedSongsProvider);
                  },
                ),
              ],
            ),
          ],
        ),
        SizedBox(height: context.scaleSize(AppConstants.spacingSm)),

        // Scoped Consumer: playlist updates rebuild only this section.
        Consumer(
          builder: (context, ref, _) {
            final playlistsAsync = ref.watch(tidalUserPlaylistsProvider);
            return playlistsAsync.when(
              loading: () => const TidalListSkeleton(
                rows: 4,
                thumbSize: 52,
                trailingWidth: null,
              ),
              error: (err, _) => TidalErrorWidget(
                error: err,
                contextLabel: 'Could not load playlists',
                onRetry: () {
                  invalidateTidalPlaylistsCache();
                  ref.invalidate(tidalUserPlaylistsProvider);
                },
              ),
              data: (playlists) {
                // Column instead of shrinkWrap ListView: shrinkWrap already
                // defeats builder laziness (all items are laid out anyway),
                // so a Column avoids the nested Scrollable/Viewport overhead.
                // Liked Songs is always pinned first, then user playlists.
                var entranceIndex = 0;
                final children = <Widget>[
                  StaggeredEntrance(
                    index: entranceIndex++,
                    child: _buildLikedSongsTile(),
                  ),
                ];
                if (playlists.isEmpty) {
                  children.add(
                    StaggeredEntrance(
                      index: entranceIndex++,
                      child: Container(
                        padding: EdgeInsets.all(
                          context.scaleSize(AppConstants.spacingLg),
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.glassBackground,
                          borderRadius: BorderRadius.circular(
                            AppConstants.radiusMd,
                          ),
                          border: Border.all(color: AppColors.glassBorder),
                        ),
                        child: Column(
                          children: [
                            const Text(
                              'No playlists found in your TIDAL library.',
                              style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 10,
                              runSpacing: 8,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: _showCreatePlaylistDialog,
                                  icon: const Icon(
                                    LucideIcons.plus,
                                    size: 16,
                                    color: Color(0xD9FFFFFF),
                                  ),
                                  label: const Text(
                                    'Create Playlist',
                                    style: TextStyle(color: Color(0xD9FFFFFF)),
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    side: const BorderSide(
                                      color: Color(0xD9FFFFFF),
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(
                                        AppConstants.radiusSm,
                                      ),
                                    ),
                                  ),
                                ),
                                OutlinedButton.icon(
                                  onPressed: _importPlaylistFromJson,
                                  icon: const Icon(
                                    LucideIcons.fileSpreadsheet,
                                    size: 16,
                                    color: Color(0xD9FFFFFF),
                                  ),
                                  label: const Text(
                                    'Import JSON',
                                    style: TextStyle(color: Color(0xD9FFFFFF)),
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    side: const BorderSide(
                                      color: Color(0xD9FFFFFF),
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(
                                        AppConstants.radiusSm,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                } else {
                  for (var i = 0; i < playlists.length; i++) {
                    children.add(
                      StaggeredEntrance(
                        index: entranceIndex++,
                        child: _buildPlaylistTile(playlists[i], index: i),
                      ),
                    );
                  }
                }
                // Window anchored to the playlist content itself so the
                // entrance plays when this async section resolves. Once it
                // closes it stays closed for this screen visit, so scrolling
                // the section out and back in does not replay the entrance.
                return StaggeredEntranceWindow(
                  initiallyOpen: !_playlistEntranceClosed,
                  onClosed: () {
                    if (mounted) {
                      setState(() => _playlistEntranceClosed = true);
                    }
                  },
                  child: Column(children: children),
                );
              },
            );
          },
        ),
        SizedBox(height: context.scaleSize(AppConstants.spacingXl * 2)),
      ],
    );

    return RefreshIndicator(
      color: const Color(0xD9FFFFFF),
      backgroundColor: AppColors.surface,
      onRefresh: () async {
        // Manual refresh is an explicit request for fresh data: clear the
        // active feed's TTL entry and let the mutations helper bypass the
        // playlist cache before rebuilding.
        invalidateTidalHubCache(feedSlug: _activeFeedSlug);
        await Future.wait([
          ref.refresh(tidalHomeFeedProvider(_activeFeedSlug).future),
          ref.read(tidalPlaylistMutationsProvider).refreshUserPlaylists(),
          ref.refresh(tidalLikedSongsProvider.future),
        ]);
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
      entranceChildren.add(
        SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
      );
    }

    // Quick-Access Shortcut Grid (SHORTCUT_LIST)
    for (var i = 0; i < feed.sections.length; i++) {
      final sec = feed.sections[i];
      if (!sec.isShortcutList) continue;
      entranceChildren.add(
        StaggeredEntrance(
          index: entranceIndex++,
          child: _buildShortcutGrid(sec, scope: 'sec$i'),
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
          child: _buildAdaptiveSection(sec, scope: 'sec$i'),
        ),
      );
    }

    return entranceChildren;
  }

  Widget _buildPlaylistTile(Map<String, dynamic> pl, {required int index}) {
    final title = pl['title'] as String? ?? 'Playlist';
    final trackCount = (pl['numberOfTracks'] ?? pl['numberOfItems']) as num?;
    final size = context.scaleSize(52);
    final playlistId = pl['uuid']?.toString() ?? pl['id']?.toString();
    final heroTag = playlistId == null || playlistId.isEmpty
        ? null
        : 'tidal-cover-$playlistId@lib-$index';

    return PressScale(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(vertical: 4),
        leading: heroTag == null
            ? TidalPlaylistCoverWidget(playlist: pl, size: size)
            : Hero(
                tag: heroTag,
                child: TidalPlaylistCoverWidget(playlist: pl, size: size),
              ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: trackCount != null
            ? Text(
                '$trackCount tracks',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              )
            : null,
        trailing: const Icon(
          LucideIcons.chevronRight,
          size: 18,
          color: AppColors.textSecondary,
        ),
        onTap: () => _openPlaylistTracks(pl, heroTag: heroTag),
      ),
    );
  }

  Widget _buildShortcutGrid(TidalHomeSection section, {String scope = 'sc'}) {
    if (section.items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (section.title.isNotEmpty && section.title != 'Shortcuts') ...[
          Text(
            section.title,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
        ],
        // Two-column shortcut layout built from Rows instead of a
        // `shrinkWrap` GridView: a never-scrolling nested viewport measures
        // every tile eagerly and adds a RenderViewport per section.
        _buildShortcutRows(section, scope),
        SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
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
  }) {
    if (section.items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
        const SizedBox(height: 10),
        SizedBox(
          height: 205,
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
        SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
      ],
    );
  }

  Widget _buildAdaptiveSection(TidalHomeSection sec, {required String scope}) {
    if (sec.sectionType == 'TRACK_LIST') {
      return _buildTrackListSection(sec);
    }
    if (sec.sectionType == 'COMPACT_GRID_CARD' ||
        sec.title.toLowerCase().contains('recently played')) {
      return _buildCompactGridSection(sec, scope: scope);
    }
    return _buildHorizontalCarousel(sec, scope: scope);
  }

  Widget _buildTrackListSection(TidalHomeSection section) {
    if (section.items.isEmpty) return const SizedBox.shrink();

    final displayItems = section.items.take(6).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
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
        SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
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
        title: SongTitleRow(
          title: item.title,
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
  }) {
    if (section.items.isEmpty) return const SizedBox.shrink();

    final items = section.items;
    final pairCount = (items.length / 2).ceil();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
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
        SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
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

  /// "Liked Songs" tile — pinned as the first item in My Playlists.
  /// Opens the full TIDAL favorites collection.
  Widget _buildLikedSongsTile() {
    final likedAsync = ref.watch(tidalLikedSongsProvider);
    final size = context.scaleSize(52);

    return PressScale(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
        leading: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppConstants.radiusSm),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Colors.pinkAccent, Colors.purpleAccent],
            ),
          ),
          child: Icon(
            LucideIcons.heart,
            color: Colors.white,
            size: context.scaleSize(24),
          ),
        ),
        title: const Text(
          'Liked Songs',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: likedAsync.when(
          data: (songs) => Text(
            '${songs.length} tracks',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
          loading: () => const Text(
            'Loading...',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
          error: (err, _) => Text(
            isTidalRateLimitError(err)
                ? 'Rate limited — try again soon'
                : 'Could not load',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
        ),
        trailing: const Icon(
          LucideIcons.chevronRight,
          color: AppColors.textSecondary,
          size: 18,
        ),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const TidalLikedSongsScreen()),
          );
        },
      ),
    );
  }
}
