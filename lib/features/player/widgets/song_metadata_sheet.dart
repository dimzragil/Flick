import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/sources/network_source_service.dart';
import 'package:flick/services/sources/tidal_service.dart';
import 'package:flick/features/tidal/providers/tidal_providers.dart';

class SongMetadataSheet extends ConsumerStatefulWidget {
  final Song song;
  const SongMetadataSheet({super.key, required this.song});

  static Future<void> show(BuildContext context, Song song) {
    return showModalBottomSheet(
      useRootNavigator: true,
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => SongMetadataSheet(song: song),
    );
  }

  @override
  ConsumerState<SongMetadataSheet> createState() => _SongMetadataSheetState();
}

class _SongMetadataSheetState extends ConsumerState<SongMetadataSheet> {
  /// Cached so sheet rebuilds (theme, animations, provider updates) don't
  /// re-hit the API; replaced by the retry action after a failure.
  Future<List<Map<String, String>>>? _creditsFuture;

  Song get _song => widget.song;

  bool get _isTidal =>
      _song.sourceType == NetworkProtocol.tidal &&
      _song.remoteId != null &&
      _song.remoteId!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: AppColors.glassBorder),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: _isTidal
          ? _buildCreditsView(context)
          : _buildMetadataView(context),
    );
  }

  Future<List<Map<String, String>>> _fetchCredits(NetworkServerEntity server) {
    return TidalService.instance.getTrackCredits(server, _song.remoteId!);
  }

  /// TIDAL-style credits view: writers, composers, producers, etc.
  Widget _buildCreditsView(BuildContext context) {
    final serverAsync = ref.watch(tidalServerProvider);

    return serverAsync.when(
      data: (server) {
        if (server == null) {
          return _buildErrorView(context, 'Not signed in to TIDAL');
        }
        final future = _creditsFuture ??= _fetchCredits(server);
        return FutureBuilder<List<Map<String, String>>>(
          future: future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.accent),
                ),
              );
            }
            if (snapshot.hasError) {
              // API/network/parse failure — distinct from a genuinely
              // creditless track, which returns an empty list below.
              return _buildErrorView(
                context,
                'Failed to load credits',
                onRetry: () => setState(() {
                  _creditsFuture = _fetchCredits(server);
                }),
              );
            }
            final credits = snapshot.data ?? [];
            if (credits.isEmpty) {
              return _buildErrorView(
                context,
                'No credits available for this track',
              );
            }
            // Group by role type.
            final grouped = <String, List<String>>{};
            for (final c in credits) {
              final type = c['type'] ?? 'Contributor';
              grouped.putIfAbsent(type, () => []).add(c['name'] ?? '');
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(context, 'Credits', LucideIcons.users),
                const SizedBox(height: 16),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final entry in grouped.entries)
                          _buildCreditRow(
                            context,
                            entry.key,
                            entry.value.join(', '),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.all(32),
        child: Center(
          child: CircularProgressIndicator(color: AppColors.accent),
        ),
      ),
      error: (_, __) => _buildErrorView(context, 'Failed to load credits'),
    );
  }

  Widget _buildErrorView(
    BuildContext context,
    String message, {
    VoidCallback? onRetry,
  }) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHeader(context, 'Credits', LucideIcons.users),
          const SizedBox(height: 16),
          Text(
            message,
            style: TextStyle(
              color: context.adaptiveTextSecondary,
              fontSize: 14,
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(LucideIcons.refreshCw, size: 16),
              label: const Text('Retry'),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.accent,
                textStyle: const TextStyle(
                  fontFamily: 'ProductSans',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 20, color: context.adaptiveTextSecondary),
        const SizedBox(width: 10),
        Text(
          title,
          style: TextStyle(
            fontFamily: 'ProductSans',
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: context.adaptiveTextPrimary,
          ),
        ),
      ],
    );
  }

  Widget _buildCreditRow(BuildContext context, String role, String names) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              role,
              style: TextStyle(
                fontFamily: 'ProductSans',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.adaptiveTextSecondary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              names,
              style: TextStyle(
                fontFamily: 'ProductSans',
                fontSize: 13,
                color: context.adaptiveTextPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Local file metadata view (unchanged).
  Widget _buildMetadataView(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildHeader(context, 'Song Metadata', LucideIcons.info),
        const SizedBox(height: 16),
        _buildMetadataRow(context, 'Title', _song.title),
        _buildMetadataRow(context, 'Artist', _song.artist),
        if (_song.album != null)
          _buildMetadataRow(context, 'Album', _song.album!),
        _buildMetadataRow(context, 'Duration', _song.formattedDuration),
        _buildMetadataRow(
          context,
          'Format',
          _song.isDsd
              ? '${_song.fileType.toUpperCase()} (${_song.dsdRateLabel})'
              : _song.fileType.toUpperCase(),
        ),
        if (_song.resolution != null && !_song.isDsd)
          _buildMetadataRow(context, 'Resolution', _song.resolution!),
        if (_song.albumArtist != null)
          _buildMetadataRow(context, 'Album Artist', _song.albumArtist!),
        if (_song.genre != null)
          _buildMetadataRow(context, 'Genre', _song.genre!),
        if (_song.year != null)
          _buildMetadataRow(context, 'Year', _song.year!.toString()),
        if (_song.trackNumber != null)
          _buildMetadataRow(context, 'Track', _song.trackNumber!.toString()),
        if (_song.discNumber != null)
          _buildMetadataRow(context, 'Disc', _song.discNumber!.toString()),
        if (_song.filePath != null)
          _buildMetadataRow(context, 'File Path', _song.filePath!),
      ],
    );
  }

  Widget _buildMetadataRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'ProductSans',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.adaptiveTextSecondary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontFamily: 'ProductSans',
                fontSize: 13,
                color: context.adaptiveTextPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
