import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/services/sources/network_source_service.dart';
import 'package:flick/widgets/common/flick_artwork_placeholder.dart';
import 'package:flick/widgets/common/flick_dialog.dart';
import '../../tidal/providers/tidal_providers.dart';
import '../../tidal/widgets/tidal_playlist_cover_widget.dart';

class AddToPlaylistSheet extends ConsumerStatefulWidget {
  final List<Song> songs;
  const AddToPlaylistSheet({super.key, required this.songs});

  Song get song => songs.first;

  static Future<void> show(BuildContext context, Song song) {
    return showSongs(context, [song]);
  }

  static Future<void> showSongs(BuildContext context, List<Song> songs) {
    return showModalBottomSheet(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => AddToPlaylistSheet(songs: songs),
    );
  }

  @override
  ConsumerState<AddToPlaylistSheet> createState() => _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends ConsumerState<AddToPlaylistSheet> {
  int _selectedTabIndex = 0; // 0 = TIDAL (if logged in), 1 = Local
  bool _isProcessing = false;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    final isTidalSong =
        widget.song.sourceType == NetworkProtocol.tidal ||
        (widget.song.remoteId != null && widget.song.remoteId!.isNotEmpty) ||
        widget.song.id.startsWith('tidal_');
    // Default to TIDAL tab if it's a TIDAL song, otherwise default to Local tab if not TIDAL
    _selectedTabIndex = isTidalSong ? 0 : 0;
  }

  Future<void> _addSongsToTidalPlaylist(
    String playlistId,
    String playlistTitle,
  ) async {
    setState(() {
      _isProcessing = true;
      _statusMessage = 'Adding to $playlistTitle...';
    });

    try {
      final server = await ref.read(tidalServerProvider.future);
      if (server == null) throw StateError('TIDAL session not found');

      final tidal = ref.read(tidalServiceProvider);
      for (final s in widget.songs) {
        final cleanTrackId = (s.remoteId != null && s.remoteId!.isNotEmpty)
            ? s.remoteId!
            : (s.id.contains('_') ? s.id.split('_').last : s.id);

        await tidal.addTrackToPlaylist(
          server,
          playlistId: playlistId,
          trackId: cleanTrackId,
        );
      }

      ref.invalidate(tidalUserPlaylistsProvider);
      ref.invalidate(tidalPlaylistDetailsProvider(playlistId));

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.songs.length == 1
                  ? 'Added "${widget.song.title}" to "$playlistTitle"'
                  : 'Added ${widget.songs.length} songs to "$playlistTitle"',
            ),
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

  Future<void> _showCreateTidalPlaylistDialog() async {
    final titleController = TextEditingController();
    final descController = TextEditingController();

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
            child: const Text('Create & Add'),
          ),
        ],
      ),
    );

    if (confirmed == true && titleController.text.trim().isNotEmpty) {
      final name = titleController.text.trim();
      final desc = descController.text.trim();

      setState(() {
        _isProcessing = true;
        _statusMessage = 'Creating "$name"...';
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
            created['id']?.toString() ??
            created['uuid']?.toString() ??
            (created['data'] as Map?)?['id']?.toString();

        ref.invalidate(tidalUserPlaylistsProvider);

        if (playlistId != null && playlistId.isNotEmpty) {
          await _addSongsToTidalPlaylist(playlistId, name);
        } else {
          if (mounted) Navigator.pop(context);
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
  }

  void _showCreateLocalPlaylistDialog(BuildContext context) {
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);

    unawaited(
      FlickDialogs.input(
        context,
        title: 'Create Local Playlist',
        hintText: 'Playlist name',
        confirmLabel: 'Create',
      ).then((name) async {
        if (name == null || name.isEmpty) return;

        final playlist = await container
            .read(playlistsProvider.notifier)
            .createPlaylist(name);

        if (playlist == null) {
          messenger.showSnackBar(
            const SnackBar(
              content: Text('A playlist with this name already exists'),
            ),
          );
          return;
        }

        for (final s in widget.songs) {
          await container
              .read(playlistsProvider.notifier)
              .addSongToPlaylist(playlist.id, s.id, song: s);
        }

        if (context.mounted) {
          Navigator.pop(context);
        }
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              widget.songs.length == 1
                  ? 'Created "${playlist.name}" and added song'
                  : 'Created "${playlist.name}" and added ${widget.songs.length} songs',
            ),
          ),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTidalLoggedIn = ref.watch(tidalAuthStateProvider);

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.glassBorderStrong,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Icon(
                LucideIcons.listPlus,
                color: AppColors.accent,
                size: 24,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.songs.length == 1
                      ? 'Add to Playlist'
                      : 'Add ${widget.songs.length} Songs to Playlist',
                  style: TextStyle(
                    fontFamily: 'ProductSans',
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: context.adaptiveTextPrimary,
                  ),
                ),
              ),
              if (isTidalLoggedIn && _selectedTabIndex == 0)
                IconButton(
                  icon: const Icon(LucideIcons.plus, color: Color(0xFF00FFFF)),
                  tooltip: 'Create TIDAL Playlist',
                  onPressed: _isProcessing
                      ? null
                      : _showCreateTidalPlaylistDialog,
                )
              else if (!isTidalLoggedIn || _selectedTabIndex == 1)
                IconButton(
                  icon: const Icon(LucideIcons.plus, color: AppColors.accent),
                  tooltip: 'Create Local Playlist',
                  onPressed: () => _showCreateLocalPlaylistDialog(context),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 36, bottom: 8),
            child: Text(
              widget.songs.length == 1
                  ? widget.song.title
                  : '${widget.songs.length} songs selected',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.adaptiveTextSecondary,
                fontSize: 13,
                fontFamily: 'ProductSans',
              ),
            ),
          ),
          if (isTidalLoggedIn) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ChoiceChip(
                    avatar: const Icon(LucideIcons.waves, size: 16),
                    label: const Text('TIDAL Playlists'),
                    selected: _selectedTabIndex == 0,
                    onSelected: (selected) {
                      if (selected) setState(() => _selectedTabIndex = 0);
                    },
                    selectedColor: const Color(
                      0xFF00FFFF,
                    ).withValues(alpha: 0.2),
                    side: BorderSide(
                      color: _selectedTabIndex == 0
                          ? const Color(0xFF00FFFF)
                          : AppColors.glassBorder,
                    ),
                    labelStyle: TextStyle(
                      fontFamily: 'ProductSans',
                      color: _selectedTabIndex == 0
                          ? const Color(0xFF00FFFF)
                          : context.adaptiveTextSecondary,
                      fontWeight: _selectedTabIndex == 0
                          ? FontWeight.bold
                          : FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ChoiceChip(
                    avatar: const Icon(LucideIcons.folder, size: 16),
                    label: const Text('Local Playlists'),
                    selected: _selectedTabIndex == 1,
                    onSelected: (selected) {
                      if (selected) setState(() => _selectedTabIndex = 1);
                    },
                    selectedColor: AppColors.accent.withValues(alpha: 0.2),
                    side: BorderSide(
                      color: _selectedTabIndex == 1
                          ? AppColors.accent
                          : AppColors.glassBorder,
                    ),
                    labelStyle: TextStyle(
                      fontFamily: 'ProductSans',
                      color: _selectedTabIndex == 1
                          ? AppColors.accent
                          : context.adaptiveTextSecondary,
                      fontWeight: _selectedTabIndex == 1
                          ? FontWeight.bold
                          : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          if (_statusMessage != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Center(
                child: Text(
                  _statusMessage!,
                  style: TextStyle(
                    color: _statusMessage!.startsWith('Error')
                        ? Colors.redAccent
                        : const Color(0xFF00FFFF),
                    fontSize: 13,
                    fontFamily: 'ProductSans',
                  ),
                ),
              ),
            ),
          ],
          if (_isProcessing)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(color: Color(0xFF00FFFF)),
              ),
            )
          else ...[
            if (isTidalLoggedIn && _selectedTabIndex == 0)
              _buildTidalPlaylistsList()
            else
              _buildLocalPlaylistsList(),
          ],
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildTidalPlaylistsList() {
    final playlistsAsync = ref.watch(tidalUserPlaylistsProvider);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.45,
      ),
      child: playlistsAsync.when(
        loading: () => const Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: CircularProgressIndicator(color: Color(0xFF00FFFF)),
          ),
        ),
        error: (err, _) => Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Failed to load TIDAL playlists: $err',
            style: TextStyle(color: context.adaptiveTextSecondary),
          ),
        ),
        data: (playlists) {
          if (playlists.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'No TIDAL playlists yet.\nCreate one to organize your music.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: context.adaptiveTextTertiary,
                      fontFamily: 'ProductSans',
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _showCreateTidalPlaylistDialog,
                    icon: const Icon(LucideIcons.plus, size: 16),
                    label: const Text('Create TIDAL Playlist'),
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
                  pl['uuid']?.toString() ?? pl['id']?.toString() ?? '';
              final title = pl['title'] as String? ?? 'Untitled Playlist';
              final trackCount =
                  (pl['numberOfTracks'] ?? pl['numberOfItems']) as num?;
              return ListTile(
                leading: TidalPlaylistCoverWidget(
                  playlist: pl,
                  size: 48,
                  borderRadius: 8,
                ),
                title: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.adaptiveTextPrimary,
                    fontFamily: 'ProductSans',
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  trackCount != null ? '$trackCount tracks' : 'TIDAL Playlist',
                  style: TextStyle(
                    color: context.adaptiveTextTertiary,
                    fontFamily: 'ProductSans',
                    fontSize: 12,
                  ),
                ),
                trailing: const Icon(
                  LucideIcons.plus,
                  color: Color(0xFF00FFFF),
                  size: 20,
                ),
                onTap: () => _addSongsToTidalPlaylist(playlistId, title),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildLocalPlaylistsList() {
    final playlistsAsync = ref.watch(playlistsProvider);

    return playlistsAsync.when(
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      ),
      error: (e, _) => Text(
        'Error loading playlists',
        style: TextStyle(color: context.adaptiveTextTertiary),
      ),
      data: (state) {
        if (state.playlists.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Text(
                    'No local playlists yet.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: context.adaptiveTextTertiary,
                      fontFamily: 'ProductSans',
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => _showCreateLocalPlaylistDialog(context),
                  icon: const Icon(LucideIcons.plus, size: 16),
                  label: const Text('Create Local Playlist'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                  ),
                ),
              ],
            ),
          );
        }

        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.45,
          ),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: state.playlists.length,
            itemBuilder: (context, index) {
              final playlist = state.playlists[index];
              final songIds = widget.songs.map((s) => s.id).toSet();
              final isAlreadyAdded =
                  playlist.songIds.where((id) => songIds.contains(id)).length >=
                  widget.songs.length;

              return ListTile(
                leading: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceLight,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const FlickArtworkPlaceholder(size: 22, opacity: 0.9),
                ),
                title: Text(
                  playlist.name,
                  style: TextStyle(
                    color: context.adaptiveTextPrimary,
                    fontFamily: 'ProductSans',
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  '${playlist.songIds.length} songs',
                  style: TextStyle(
                    color: context.adaptiveTextTertiary,
                    fontFamily: 'ProductSans',
                    fontSize: 12,
                  ),
                ),
                trailing: isAlreadyAdded
                    ? const Icon(LucideIcons.check, color: AppColors.accent)
                    : const Icon(
                        LucideIcons.plus,
                        color: AppColors.accent,
                        size: 20,
                      ),
                onTap: isAlreadyAdded
                    ? null
                    : () async {
                        final notifier = ref.read(playlistsProvider.notifier);
                        for (final s in widget.songs) {
                          await notifier.addSongToPlaylist(
                            playlist.id,
                            s.id,
                            song: s,
                          );
                        }
                        if (context.mounted) {
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                widget.songs.length == 1
                                    ? 'Added to "${playlist.name}"'
                                    : 'Added ${widget.songs.length} songs to "${playlist.name}"',
                              ),
                            ),
                          );
                        }
                      },
              );
            },
          ),
        );
      },
    );
  }
}
