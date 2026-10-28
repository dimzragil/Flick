import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/error_display.dart';
import '../../../core/utils/navigation_helper.dart';
import '../../../core/utils/responsive.dart';
import '../../../services/sources/tidal_service.dart';
import '../providers/tidal_providers.dart';
import '../widgets/press_scale.dart';
import '../widgets/tidal_error_widget.dart';
import '../widgets/tidal_import_playlist_dialog.dart';
import '../widgets/tidal_playlist_cover_widget.dart';
import '../widgets/tidal_shimmer.dart';
import 'tidal_playlist_screen.dart';

class TidalPlaylistsScreen extends ConsumerStatefulWidget {
  const TidalPlaylistsScreen({super.key});

  @override
  ConsumerState<TidalPlaylistsScreen> createState() =>
      _TidalPlaylistsScreenState();
}

class _TidalPlaylistsScreenState extends ConsumerState<TidalPlaylistsScreen> {
  Future<void> _refreshPlaylists() async {
    invalidateTidalPlaylistsCache();
    await ref.read(tidalPlaylistMutationsProvider).refreshUserPlaylists();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft, color: AppColors.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Playlists',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Import Playlist from JSON',
            icon: const Icon(
              LucideIcons.fileSpreadsheet,
              color: AppColors.textPrimary,
            ),
            onPressed: _importPlaylistFromJson,
          ),
          IconButton(
            tooltip: 'Create TIDAL Playlist',
            icon: const Icon(LucideIcons.plus, color: AppColors.textPrimary),
            onPressed: _showCreatePlaylistDialog,
          ),
        ],
      ),
      body: RefreshIndicator(
        color: const Color(0xD9FFFFFF),
        backgroundColor: AppColors.surface,
        onRefresh: _refreshPlaylists,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.all(context.scaleSize(AppConstants.spacingMd)),
          children: [_buildPlaylists()],
        ),
      ),
    );
  }

  Widget _buildPlaylists() {
    return ref
        .watch(tidalUserPlaylistsProvider)
        .when(
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
                          icon: const Icon(LucideIcons.plus, size: 16),
                          label: const Text('Create Playlist'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _importPlaylistFromJson,
                          icon: const Icon(
                            LucideIcons.fileSpreadsheet,
                            size: 16,
                          ),
                          label: const Text('Import JSON'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }
            return Column(
              children: [
                for (var i = 0; i < playlists.length; i++)
                  _buildPlaylistTile(playlists[i], index: i),
              ],
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
}
