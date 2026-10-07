import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/responsive.dart';
import '../providers/tidal_providers.dart';
import 'tidal_playlist_cover_widget.dart';

class TidalAddToPlaylistDialog extends ConsumerStatefulWidget {
  final String trackId;
  final String trackTitle;

  const TidalAddToPlaylistDialog({
    super.key,
    required this.trackId,
    required this.trackTitle,
  });

  /// Static helper to display the sheet.
  static Future<void> show(
    BuildContext context, {
    required String trackId,
    required String trackTitle,
  }) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.background,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppConstants.radiusLg),
        ),
      ),
      builder: (_) =>
          TidalAddToPlaylistDialog(trackId: trackId, trackTitle: trackTitle),
    );
  }

  @override
  ConsumerState<TidalAddToPlaylistDialog> createState() =>
      _TidalAddToPlaylistDialogState();
}

class _TidalAddToPlaylistDialogState
    extends ConsumerState<TidalAddToPlaylistDialog> {
  bool _isProcessing = false;
  String? _statusMessage;

  Future<void> _addToPlaylist(String playlistId, String playlistTitle) async {
    setState(() {
      _isProcessing = true;
      _statusMessage = 'Adding to $playlistTitle...';
    });

    try {
      final server = await ref.read(tidalServerProvider.future);
      if (server == null) throw StateError('TIDAL session not found');

      final tidal = ref.read(tidalServiceProvider);
      await tidal.addTrackToPlaylist(
        server,
        playlistId: playlistId,
        trackId: widget.trackId,
      );

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added "${widget.trackTitle}" to $playlistTitle'),
            backgroundColor: const Color(0xFF00A2C7),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _statusMessage = 'Error: $e';
        });
      }
    }
  }

  Future<void> _showCreatePlaylistDialog() async {
    final titleController = TextEditingController();
    final descController = TextEditingController();

    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text(
            'New TIDAL Playlist',
            style: TextStyle(color: AppColors.textPrimary),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                autofocus: true,
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: const InputDecoration(
                  labelText: 'Playlist Name',
                  labelStyle: TextStyle(color: AppColors.textSecondary),
                  hintText: 'My Awesome Playlist',
                  hintStyle: TextStyle(color: AppColors.textSecondary),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descController,
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                  labelStyle: TextStyle(color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text(
                'Cancel',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF00A2C7),
              ),
              child: const Text('Create'),
            ),
          ],
        ),
      );

      if (confirmed == true && titleController.text.trim().isNotEmpty) {
        final name = titleController.text.trim();
        final desc = descController.text.trim();

        setState(() {
          _isProcessing = true;
          _statusMessage = 'Creating playlist "$name"...';
        });

        try {
          final server = await ref.read(tidalServerProvider.future);
          if (server == null) throw StateError('TIDAL session not found');

          final tidal = ref.read(tidalServiceProvider);
          final created = await tidal.createPlaylist(
            server,
            title: name,
            description: desc,
          );
          final playlistId =
              created['id']?.toString() ?? created['uuid']?.toString();

          ref.invalidate(tidalUserPlaylistsProvider);

          if (playlistId != null && playlistId.isNotEmpty) {
            await _addToPlaylist(playlistId, name);
          } else {
            if (mounted) Navigator.of(context).pop();
          }
        } catch (e) {
          if (mounted) {
            setState(() {
              _isProcessing = false;
              _statusMessage = 'Could not create playlist: $e';
            });
          }
        }
      }
    } finally {
      titleController.dispose();
      descController.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final playlistsAsync = ref.watch(tidalUserPlaylistsProvider);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(context.scaleSize(AppConstants.spacingMd)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.glassBorderStrong,
                  borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                ),
              ),
            ),
            SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
            Row(
              children: [
                const Icon(
                  LucideIcons.listMusic,
                  color: Color(0xD9FFFFFF),
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Add to TIDAL Playlist',
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(LucideIcons.plus, color: Color(0xD9FFFFFF)),
                  tooltip: 'Create Playlist',
                  onPressed: _isProcessing ? null : _showCreatePlaylistDialog,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 32, bottom: 8),
              child: Text(
                widget.trackTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ),
            const Divider(color: AppColors.glassBorder),
            if (_statusMessage != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _statusMessage!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _statusMessage!.startsWith('Error')
                        ? Colors.redAccent
                        : const Color(0xD9FFFFFF),
                    fontSize: 13,
                  ),
                ),
              ),
            ],
            if (_isProcessing)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(color: Color(0xD9FFFFFF)),
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.45,
                ),
                child: playlistsAsync.when(
                  loading: () => const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: CircularProgressIndicator(
                        color: Color(0xD9FFFFFF),
                      ),
                    ),
                  ),
                  error: (err, _) => Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Failed to load playlists: $err',
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                  ),
                  data: (playlists) {
                    if (playlists.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'No TIDAL playlists yet.',
                              style: TextStyle(color: AppColors.textSecondary),
                            ),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: _showCreatePlaylistDialog,
                              icon: const Icon(LucideIcons.plus, size: 16),
                              label: const Text('Create New Playlist'),
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF00A2C7),
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    return ListView.builder(
                      shrinkWrap: true,
                      itemCount: playlists.length,
                      itemBuilder: (context, index) {
                        final pl = playlists[index];
                        final playlistId =
                            pl['uuid']?.toString() ??
                            pl['id']?.toString() ??
                            '';
                        final title =
                            pl['title'] as String? ?? 'Untitled Playlist';
                        final trackCount =
                            (pl['numberOfTracks'] ?? pl['numberOfItems'])
                                as num?;
                        final size = context.scaleSize(44);

                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 2,
                          ),
                          leading: TidalPlaylistCoverWidget(
                            playlist: pl,
                            size: size,
                          ),
                          title: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
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
                          onTap: () => _addToPlaylist(playlistId, title),
                        );
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
