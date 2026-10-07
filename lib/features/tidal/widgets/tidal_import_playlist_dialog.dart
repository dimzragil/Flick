import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../providers/tidal_providers.dart';

/// Representation of a track entry parsed from an external playlist JSON dump.
class JsonPlaylistTrack {
  final String title;
  final String artist;
  final String? album;
  final String? isrc;
  final int? durationInMillis;

  const JsonPlaylistTrack({
    required this.title,
    required this.artist,
    this.album,
    this.isrc,
    this.durationInMillis,
  });

  factory JsonPlaylistTrack.fromJson(Map<String, dynamic> json) {
    return JsonPlaylistTrack(
      title: json['title']?.toString() ?? 'Unknown Title',
      artist: json['artist']?.toString() ?? 'Unknown Artist',
      album: json['album']?.toString(),
      isrc: json['isrc']?.toString(),
      durationInMillis: (json['durationInMillis'] as num?)?.toInt(),
    );
  }
}

enum _ImportStep { ready, importing, completed, error }

/// Dialog that handles importing an external JSON playlist into the user's TIDAL account.
class TidalImportPlaylistDialog extends ConsumerStatefulWidget {
  final List<JsonPlaylistTrack> tracks;
  final String defaultPlaylistName;

  const TidalImportPlaylistDialog({
    super.key,
    required this.tracks,
    required this.defaultPlaylistName,
  });

  /// Static helper to display the modal dialog.
  static Future<bool?> show(
    BuildContext context, {
    required List<JsonPlaylistTrack> tracks,
    required String defaultPlaylistName,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => TidalImportPlaylistDialog(
        tracks: tracks,
        defaultPlaylistName: defaultPlaylistName,
      ),
    );
  }

  @override
  ConsumerState<TidalImportPlaylistDialog> createState() =>
      _TidalImportPlaylistDialogState();
}

class _TidalImportPlaylistDialogState
    extends ConsumerState<TidalImportPlaylistDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _descController;

  _ImportStep _step = _ImportStep.ready;
  bool _isCancelled = false;

  int _currentIndex = 0;
  String _currentTrackText = '';
  final List<String> _matchedTrackIds = [];
  final List<JsonPlaylistTrack> _unmatchedTracks = [];
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.defaultPlaylistName);
    _descController = TextEditingController(
      text: 'Imported from JSON playlist',
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descController.dispose();
    super.dispose();
  }

  Future<void> _startImport() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() {
        _errorMessage = 'Playlist title cannot be empty';
      });
      return;
    }

    setState(() {
      _step = _ImportStep.importing;
      _currentIndex = 0;
      _currentTrackText = 'Initializing matching...';
      _matchedTrackIds.clear();
      _unmatchedTracks.clear();
      _errorMessage = null;
      _isCancelled = false;
    });

    try {
      final server = await ref.read(tidalServerProvider.future);
      if (server == null || server.token == null || server.token!.isEmpty) {
        throw StateError('TIDAL session is not authenticated. Please log in.');
      }

      final tidal = ref.read(tidalServiceProvider);

      // 1. Match each track against TIDAL catalog
      for (int i = 0; i < widget.tracks.length; i++) {
        if (!mounted || _isCancelled) break;

        final track = widget.tracks[i];
        setState(() {
          _currentIndex = i + 1;
          _currentTrackText = '${track.title} • ${track.artist}';
        });

        final tidalId = await tidal.searchTrackByIsrcOrText(
          server,
          isrc: track.isrc,
          title: track.title,
          artist: track.artist,
          expectedDurationMs: track.durationInMillis,
        );

        if (tidalId != null && tidalId.isNotEmpty) {
          _matchedTrackIds.add(tidalId);
        } else {
          _unmatchedTracks.add(track);
        }

        // Polite delay to protect against TIDAL API rate limiting
        await Future.delayed(const Duration(milliseconds: 40));
      }

      if (_isCancelled) {
        if (mounted) {
          Navigator.of(context).pop(false);
        }
        return;
      }

      if (_matchedTrackIds.isEmpty) {
        setState(() {
          _step = _ImportStep.error;
          _errorMessage = 'No matching tracks were found on TIDAL.';
        });
        return;
      }

      // 2. Create the playlist in TIDAL
      setState(() {
        _currentTrackText =
            'Creating playlist "${_titleController.text.trim()}"...';
      });

      final created = await tidal.createPlaylist(
        server,
        title: _titleController.text.trim(),
        description: _descController.text.trim(),
      );

      final playlistId =
          created['id']?.toString() ?? created['uuid']?.toString();
      if (playlistId == null || playlistId.isEmpty) {
        throw StateError('Could not retrieve new TIDAL playlist ID.');
      }

      // 3. Batch add matched tracks to playlist
      setState(() {
        _currentTrackText =
            'Adding ${_matchedTrackIds.length} tracks to TIDAL...';
      });

      await tidal.addTracksToPlaylist(
        server,
        playlistId: playlistId,
        trackIds: _matchedTrackIds,
      );

      // Invalidate playlist provider so it updates immediately in UI
      ref.invalidate(tidalUserPlaylistsProvider);

      if (mounted) {
        setState(() {
          _step = _ImportStep.completed;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _step = _ImportStep.error;
          _errorMessage = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
        side: const BorderSide(color: AppColors.glassBorder),
      ),
      title: _buildTitle(),
      content: _buildContent(),
      actions: _buildActions(),
    );
  }

  Widget _buildTitle() {
    return Row(
      children: [
        Icon(
          _step == _ImportStep.completed
              ? LucideIcons.circleCheck
              : (_step == _ImportStep.error
                    ? LucideIcons.circleAlert
                    : LucideIcons.fileSpreadsheet),
          color: _step == _ImportStep.completed
              ? const Color(0xD9FFFFFF)
              : (_step == _ImportStep.error
                    ? Colors.redAccent
                    : const Color(0xD9FFFFFF)),
          size: 22,
        ),
        const SizedBox(width: 10),
        Text(
          _step == _ImportStep.completed
              ? 'Import Completed'
              : (_step == _ImportStep.importing
                    ? 'Importing Playlist...'
                    : (_step == _ImportStep.error
                          ? 'Import Error'
                          : 'Import from JSON')),
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildContent() {
    switch (_step) {
      case _ImportStep.ready:
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                  border: Border.all(color: AppColors.glassBorder),
                ),
                child: Row(
                  children: [
                    const Icon(
                      LucideIcons.music,
                      color: Color(0xD9FFFFFF),
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Found ${widget.tracks.length} tracks in JSON file with ISRC metadata.',
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Playlist Name',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _titleController,
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Enter playlist name',
                  hintStyle: const TextStyle(color: AppColors.textSecondary),
                  filled: true,
                  fillColor: AppColors.surfaceLight,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                    borderSide: const BorderSide(color: Color(0xD9FFFFFF)),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Description (optional)',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _descController,
                maxLines: 2,
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Enter description',
                  hintStyle: const TextStyle(color: AppColors.textSecondary),
                  filled: true,
                  fillColor: AppColors.surfaceLight,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                    borderSide: const BorderSide(color: Color(0xD9FFFFFF)),
                  ),
                ),
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 10),
                Text(
                  _errorMessage!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
              ],
            ],
          ),
        );

      case _ImportStep.importing:
        final progress = widget.tracks.isNotEmpty
            ? (_currentIndex / widget.tracks.length).clamp(0.0, 1.0)
            : 0.0;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Matching: $_currentIndex / ${widget.tracks.length}',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${(progress * 100).toInt()}%',
                  style: const TextStyle(
                    color: Color(0xD9FFFFFF),
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: AppColors.surfaceLight,
                valueColor: const AlwaysStoppedAnimation<Color>(
                  Color(0xD9FFFFFF),
                ),
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              _currentTrackText,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Matched: ${_matchedTrackIds.length}  •  Unmatched: ${_unmatchedTracks.length}',
              style: const TextStyle(color: Color(0xD9FFFFFF), fontSize: 12),
            ),
          ],
        );

      case _ImportStep.completed:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Successfully added ${_matchedTrackIds.length} of ${widget.tracks.length} tracks to "${_titleController.text.trim()}".',
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14,
                height: 1.4,
              ),
            ),
            if (_unmatchedTracks.isNotEmpty) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_unmatchedTracks.length} tracks not found on TIDAL:',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 100,
                      child: ListView.builder(
                        itemCount: _unmatchedTracks.length,
                        itemBuilder: (context, idx) {
                          final t = _unmatchedTracks[idx];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              '• ${t.title} - ${t.artist}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 11,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        );

      case _ImportStep.error:
        return Text(
          _errorMessage ?? 'An error occurred during import.',
          style: const TextStyle(
            color: Colors.redAccent,
            fontSize: 13,
            height: 1.4,
          ),
        );
    }
  }

  List<Widget> _buildActions() {
    switch (_step) {
      case _ImportStep.ready:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          FilledButton(
            onPressed: _startImport,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xD9FFFFFF),
              foregroundColor: Colors.black,
            ),
            child: const Text('Start Import'),
          ),
        ];

      case _ImportStep.importing:
        return [
          TextButton(
            onPressed: () {
              setState(() {
                _isCancelled = true;
              });
            },
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ];

      case _ImportStep.completed:
        return [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xD9FFFFFF),
              foregroundColor: Colors.black,
            ),
            child: const Text('Done'),
          ),
        ];

      case _ImportStep.error:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(
              'Close',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          FilledButton(
            onPressed: () {
              setState(() {
                _step = _ImportStep.ready;
                _errorMessage = null;
              });
            },
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xD9FFFFFF),
              foregroundColor: Colors.black,
            ),
            child: const Text('Retry'),
          ),
        ];
    }
  }
}
