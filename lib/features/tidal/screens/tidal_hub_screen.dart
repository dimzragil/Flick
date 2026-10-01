import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import '../widgets/tidal_import_playlist_dialog.dart';
import '../../player/widgets/add_to_playlist_sheet.dart';
import '../../favorites/screens/favorites_screen.dart';
import 'tidal_album_screen.dart';
import 'tidal_artist_screen.dart';
import 'tidal_mix_screen.dart';
import 'tidal_playlist_screen.dart';
import 'tidal_search_screen.dart';

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
          ref.invalidate(tidalFavoriteMixesProvider);
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
    NavigationHelper.pushFade(context, (_) => const TidalSearchScreen());
  }

  void _openHomeItem(TidalHomeItem item) {
    if (item.isMyTracks) {
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const FavoritesScreen()));
      return;
    }

    if (item.isMix) {
      final mixId = item.raw['mixId']?.toString() ?? item.id;
      if (mixId.isNotEmpty) {
        NavigationHelper.pushFade(
          context,
          (_) => TidalMixScreen(
            mixId: mixId,
            initialTitle: item.title,
            initialImageUrl: item.imageUrl,
            initialSubtitle: item.subtitle,
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
        NavigationHelper.pushFade(
          context,
          (_) => TidalPlaylistScreen(
            playlistId: plId,
            initialTitle: item.title,
            initialImageUrl: item.imageUrl,
            initialSubtitle: item.subtitle,
            initialTrackCount: (item.raw['numberOfTracks'] as num?)?.toInt(),
          ),
        );
        return;
      }
    }

    if (item.isAlbum) {
      final albId = item.raw['artifactId']?.toString() ?? item.id;
      if (albId.isNotEmpty) {
        NavigationHelper.pushFade(
          context,
          (_) => TidalAlbumScreen(albumId: albId, initialAlbumData: item.raw),
        );
        return;
      }
    }

    if (item.isArtist) {
      final artId = item.raw['artifactId']?.toString() ?? item.id;
      if (artId.isNotEmpty) {
        NavigationHelper.pushFade(
          context,
          (_) =>
              TidalArtistScreen(artistId: artId, initialArtistData: item.raw),
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
      NavigationHelper.pushFade(
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
      NavigationHelper.pushFade(
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
                leading: const Icon(LucideIcons.play, color: Color(0xFF00FFFF)),
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
                    color: Color(0xFF00FFFF),
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
                    color: Color(0xFF00FFFF),
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
                      NavigationHelper.pushFade(
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

  void _openPlaylistTracks(Map<String, dynamic> pl) {
    final playlistId = pl['uuid']?.toString() ?? pl['id']?.toString();
    if (playlistId == null) return;
    final imageUuid =
        (pl['image'] as String?) ?? (pl['squareImage'] as String?);
    final imageUrl = (imageUuid != null && imageUuid.isNotEmpty)
        ? TidalService.coverUrl(imageUuid, size: 640)
        : null;
    NavigationHelper.pushFade(
      context,
      (_) => TidalPlaylistScreen(
        playlistId: playlistId,
        initialTitle: pl['title'] as String?,
        initialImageUrl: (imageUrl != null && imageUrl.isNotEmpty)
            ? imageUrl
            : null,
        initialTrackCount:
            ((pl['numberOfTracks'] ?? pl['numberOfItems']) as num?)?.toInt(),
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
                      color: Color(0xFF00FFFF),
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
                            color: Color(0xFF00FFFF),
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
                            color: Color(0xFF00FFFF),
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
                                  .read(tidalServiceProvider)
                                  .createPlaylist(
                                    server,
                                    title: title,
                                    description: descController.text.trim(),
                                  );
                              if (dialogCtx.mounted) {
                                Navigator.pop(dialogCtx, true);
                              }
                              ref.invalidate(tidalUserPlaylistsProvider);

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
                                  NavigationHelper.pushFade(
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
        final success = await TidalImportPlaylistDialog.show(
          context,
          tracks: parsedTracks,
          defaultPlaylistName: defaultName,
        );
        if (success == true && mounted) {
          ref.invalidate(tidalUserPlaylistsProvider);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to read JSON: $e'),
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
              const Icon(LucideIcons.waves, color: Color(0xFF00FFFF), size: 24),
              const SizedBox(width: 8),
              const Text(
                'TIDAL',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0x3300FFFF),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'HiFi',
                  style: TextStyle(
                    color: Color(0xFF00FFFF),
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
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
              border: Border.all(color: const Color(0x4400FFFF), width: 1.5),
            ),
            child: const Center(
              child: Icon(
                LucideIcons.waves,
                size: 48,
                color: Color(0xFF00FFFF),
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
            const CircularProgressIndicator(color: Color(0xFF00FFFF)),
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
                  border: Border.all(color: const Color(0x3300FFFF)),
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
                        color: Color(0xFF00FFFF),
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
                        foregroundColor: const Color(0xFF00FFFF),
                        side: const BorderSide(color: Color(0xFF00FFFF)),
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
    final feedAsync = ref.watch(tidalHomeFeedProvider(_activeFeedSlug));
    final playlistsAsync = ref.watch(tidalUserPlaylistsProvider);
    final mixesAsync = ref.watch(tidalFavoriteMixesProvider);

    return RefreshIndicator(
      color: const Color(0xFF00FFFF),
      backgroundColor: AppColors.surface,
      onRefresh: () async {
        await Future.wait([
          ref.refresh(tidalHomeFeedProvider(_activeFeedSlug).future),
          ref.refresh(tidalUserPlaylistsProvider.future),
          ref.refresh(tidalFavoriteMixesProvider.future),
        ]);
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.all(context.scaleSize(AppConstants.spacingMd)),
        children: [
          // 3. Feed Content (Vibes Tab Bar + Shortcuts + Horizontal Sections)
          feedAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(40),
              child: Center(
                child: CircularProgressIndicator(color: Color(0xFF00FFFF)),
              ),
            ),
            error: (err, _) => Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Could not load TIDAL home feed: $err',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ),
            data: (feed) {
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
                  return name != 'suggested' &&
                      slug != 'static' &&
                      slug != 'suggested';
                }),
              ];

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Vibes Tabs Pills ('For You' first, then the API tabs)
                  if (displayTabs.isNotEmpty) ...[
                    SizedBox(
                      height: 38,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: displayTabs.length,
                        itemBuilder: (context, index) {
                          final tab = displayTabs[index];
                          final isActive = tab.slug == _activeFeedSlug;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(19),
                              child: BackdropFilter(
                                filter: ImageFilter.blur(
                                  sigmaX: AppConstants.glassBlurSigmaLight,
                                  sigmaY: AppConstants.glassBlurSigmaLight,
                                ),
                                child: ChoiceChip(
                                  label: Text(tab.name),
                                  selected: isActive,
                                  onSelected: (_) {
                                    // Tapping the active pill toggles back to
                                    // the default "For You" feed.
                                    setState(() {
                                      _activeFeedSlug =
                                          tab.slug == _activeFeedSlug
                                          ? 'static'
                                          : tab.slug;
                                    });
                                  },
                                  selectedColor: const Color(0x4000FFFF),
                                  backgroundColor:
                                      AppColors.glassBackgroundStrong,
                                  labelStyle: TextStyle(
                                    color: isActive
                                        ? const Color(0xFF00FFFF)
                                        : AppColors.textPrimary,
                                    fontWeight: isActive
                                        ? FontWeight.bold
                                        : FontWeight.w500,
                                    fontSize: 13,
                                  ),
                                  side: BorderSide(
                                    color: isActive
                                        ? const Color(0xFF00FFFF)
                                        : AppColors.glassBorder,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(19),
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

                  // Quick-Access Shortcut Grid (SHORTCUT_LIST)
                  for (final sec in feed.sections.where(
                    (s) => s.isShortcutList,
                  ))
                    _buildShortcutGrid(sec),

                  // Custom Mixes & Daily Discovery (from /v2/favorites/mixes)
                  if (_activeFeedSlug == 'static')
                    _buildCustomMixesSection(mixesAsync),

                  // Adaptive Sections (Track list, Compact Grid for Recently played, or Carousel)
                  for (final sec in feed.sections.where(
                    (s) => !s.isShortcutList,
                  ))
                    _buildAdaptiveSection(sec),
                ],
              );
            },
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
                      color: Color(0xFF00FFFF),
                    ),
                    tooltip: 'Import Playlist from JSON',
                    onPressed: _importPlaylistFromJson,
                  ),
                  IconButton(
                    icon: const Icon(
                      LucideIcons.plus,
                      size: 20,
                      color: Color(0xFF00FFFF),
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
                    onPressed: () =>
                        ref.refresh(tidalUserPlaylistsProvider.future),
                  ),
                ],
              ),
            ],
          ),
          SizedBox(height: context.scaleSize(AppConstants.spacingSm)),

          playlistsAsync.when(
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(color: Color(0xFF00FFFF)),
              ),
            ),
            error: (err, _) => Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Could not load playlists: $err',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ),
            data: (playlists) {
              if (playlists.isEmpty) {
                return Container(
                  padding: EdgeInsets.all(
                    context.scaleSize(AppConstants.spacingLg),
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.glassBackground,
                    borderRadius: BorderRadius.circular(AppConstants.radiusMd),
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
                              color: Color(0xFF00FFFF),
                            ),
                            label: const Text(
                              'Create Playlist',
                              style: TextStyle(color: Color(0xFF00FFFF)),
                            ),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Color(0xFF00FFFF)),
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
                              color: Color(0xFF00FFFF),
                            ),
                            label: const Text(
                              'Import JSON',
                              style: TextStyle(color: Color(0xFF00FFFF)),
                            ),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Color(0xFF00FFFF)),
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
                );
              }

              return ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: playlists.length,
                itemBuilder: (context, index) {
                  final pl = playlists[index];
                  final title = pl['title'] as String? ?? 'Playlist';
                  final trackCount =
                      (pl['numberOfTracks'] ?? pl['numberOfItems']) as num?;
                  final imageUuid =
                      (pl['image'] as String?) ??
                      (pl['squareImage'] as String?);
                  final imageUrl = (imageUuid != null && imageUuid.isNotEmpty)
                      ? TidalService.coverUrl(imageUuid, size: 320)
                      : null;
                  final size = context.scaleSize(52);

                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(vertical: 4),
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(
                        AppConstants.radiusSm,
                      ),
                      child: SizedBox(
                        width: size,
                        height: size,
                        child: (imageUrl != null && imageUrl.isNotEmpty)
                            ? CachedImageWidget(
                                imagePath: imageUrl,
                                width: size,
                                height: size,
                                fit: BoxFit.cover,
                                placeholder: const FlickArtworkPlaceholder(),
                                errorWidget: const FlickArtworkPlaceholder(),
                              )
                            : const FlickArtworkPlaceholder(),
                      ),
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
                    onTap: () => _openPlaylistTracks(pl),
                  );
                },
              );
            },
          ),
          SizedBox(height: context.scaleSize(AppConstants.spacingXl * 2)),
        ],
      ),
    );
  }

  Widget _buildShortcutGrid(TidalHomeSection section) {
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
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisExtent: 56,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: section.items.length.clamp(0, 8),
          itemBuilder: (context, index) {
            final item = section.items[index];
            final effectiveImage =
                (item.imageUrl != null && item.imageUrl!.isNotEmpty)
                ? item.imageUrl
                : null;
            return Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                onTap: () => _openHomeItem(item),
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
                          child:
                              (effectiveImage != null &&
                                  effectiveImage.isNotEmpty)
                              ? CachedImageWidget(
                                  imagePath: effectiveImage,
                                  width: 56,
                                  height: 56,
                                  fit: BoxFit.cover,
                                  placeholder: const ColoredBox(
                                    color: AppColors.glassBackgroundStrong,
                                  ),
                                  errorWidget: const ColoredBox(
                                    color: AppColors.glassBackgroundStrong,
                                  ),
                                )
                              : const ColoredBox(
                                  color: AppColors.glassBackgroundStrong,
                                  child: Center(
                                    child: Icon(
                                      LucideIcons.music,
                                      size: 24,
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                ),
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
            );
          },
        ),
        SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
      ],
    );
  }

  Widget _buildHorizontalCarousel(TidalHomeSection section) {
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
            scrollDirection: Axis.horizontal,
            itemCount: section.items.length,
            itemBuilder: (context, index) {
              final item = section.items[index];
              final effectiveImage =
                  (item.imageUrl != null && item.imageUrl!.isNotEmpty)
                  ? item.imageUrl
                  : null;
              return Container(
                width: 136,
                margin: const EdgeInsets.only(right: 12),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                    onTap: () => _openHomeItem(item),
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
                                child:
                                    (effectiveImage != null &&
                                        effectiveImage.isNotEmpty)
                                    ? CachedImageWidget(
                                        imagePath: effectiveImage,
                                        width: 136,
                                        height: 136,
                                        fit: BoxFit.cover,
                                        placeholder: const ColoredBox(
                                          color:
                                              AppColors.glassBackgroundStrong,
                                        ),
                                        errorWidget: const ColoredBox(
                                          color:
                                              AppColors.glassBackgroundStrong,
                                        ),
                                      )
                                    : const ColoredBox(
                                        color: AppColors.glassBackgroundStrong,
                                        child: Center(
                                          child: Icon(
                                            LucideIcons.music,
                                            size: 36,
                                            color: AppColors.textSecondary,
                                          ),
                                        ),
                                      ),
                              ),
                            ),
                            Positioned(
                              right: 6,
                              bottom: 6,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _openHomeItem(item),
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.7),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: const Color(0x6600FFFF),
                                    ),
                                  ),
                                  child: const Icon(
                                    LucideIcons.play,
                                    size: 14,
                                    color: Color(0xFF00FFFF),
                                  ),
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
              );
            },
          ),
        ),
        SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
      ],
    );
  }

  Widget _buildAdaptiveSection(TidalHomeSection sec) {
    if (sec.sectionType == 'TRACK_LIST') {
      return _buildTrackListSection(sec);
    }
    if (sec.sectionType == 'COMPACT_GRID_CARD' ||
        sec.title.toLowerCase().contains('recently played')) {
      return _buildCompactGridSection(sec);
    }
    return _buildHorizontalCarousel(sec);
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
          child: ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: displayItems.length,
            separatorBuilder: (_, __) => const Divider(
              color: AppColors.glassBorder,
              height: 1,
              indent: 56,
            ),
            itemBuilder: (context, index) {
              final item = displayItems[index];
              final img = item.imageUrl;
              return ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 2,
                ),
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
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(
                        LucideIcons.play,
                        size: 16,
                        color: Color(0xFF00FFFF),
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
              );
            },
          ),
        ),
        SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
      ],
    );
  }

  Widget _buildCompactGridSection(TidalHomeSection section) {
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
            scrollDirection: Axis.horizontal,
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
                    _buildCompactCard(topItem),
                    const SizedBox(height: 8),
                    if (bottomItem != null)
                      _buildCompactCard(bottomItem)
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

  Widget _buildCompactCard(TidalHomeItem item) {
    final img = item.imageUrl;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppConstants.radiusSm),
        onTap: () => _openHomeItem(item),
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
                  child: (img != null && img.isNotEmpty)
                      ? CachedImageWidget(
                          imagePath: img,
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                          placeholder: const FlickArtworkPlaceholder(),
                          errorWidget: const FlickArtworkPlaceholder(),
                        )
                      : const FlickArtworkPlaceholder(),
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
                    if (item.subtitle != null && item.subtitle!.isNotEmpty) ...[
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
                  color: const Color(0xFF00FFFF).withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCustomMixesSection(AsyncValue<List<TidalHomeItem>> mixesAsync) {
    return mixesAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (mixes) {
        if (mixes.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(LucideIcons.sparkles, size: 18, color: Color(0xFF00FFFF)),
                SizedBox(width: 6),
                Text(
                  'Custom Mixes & Daily Discovery',
                  style: TextStyle(
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
                scrollDirection: Axis.horizontal,
                itemCount: mixes.length,
                itemBuilder: (context, index) {
                  final item = mixes[index];
                  final effectiveImage = item.imageUrl;
                  return Container(
                    width: 136,
                    margin: const EdgeInsets.only(right: 12),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(
                          AppConstants.radiusMd,
                        ),
                        onTap: () => _openHomeItem(item),
                        onLongPress: () => _showItemActionSheet(item),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Stack(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(
                                    AppConstants.radiusMd,
                                  ),
                                  child: SizedBox(
                                    width: 136,
                                    height: 136,
                                    child:
                                        (effectiveImage != null &&
                                            effectiveImage.isNotEmpty)
                                        ? CachedImageWidget(
                                            imagePath: effectiveImage,
                                            width: 136,
                                            height: 136,
                                            fit: BoxFit.cover,
                                            placeholder:
                                                const FlickArtworkPlaceholder(),
                                            errorWidget:
                                                const FlickArtworkPlaceholder(),
                                          )
                                        : const FlickArtworkPlaceholder(),
                                  ),
                                ),
                                Positioned(
                                  right: 6,
                                  bottom: 6,
                                  child: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(
                                        alpha: 0.7,
                                      ),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: const Color(0x6600FFFF),
                                      ),
                                    ),
                                    child: const Icon(
                                      LucideIcons.play,
                                      size: 14,
                                      color: Color(0xFF00FFFF),
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
                  );
                },
              ),
            ),
            SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
          ],
        );
      },
    );
  }
}
