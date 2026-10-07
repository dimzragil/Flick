import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/sources/network_source_service.dart';
import 'package:flick/services/sources/tidal_service.dart';
import 'package:flick/features/tidal/providers/tidal_providers.dart';

class SongMetadataSheet extends ConsumerWidget {
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

  bool get _isTidal =>
      song.sourceType == NetworkProtocol.tidal &&
      song.remoteId != null &&
      song.remoteId!.isNotEmpty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: AppColors.glassBorder),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: _isTidal
          ? _buildCreditsView(context, ref)
          : _buildMetadataView(context),
    );
  }

  /// TIDAL-style credits view: writers, composers, producers, etc.
  Widget _buildCreditsView(BuildContext context, WidgetRef ref) {
    final serverAsync = ref.watch(tidalServerProvider);

    return serverAsync.when(
      data: (server) {
        if (server == null) {
          return _buildErrorView(context, 'Not signed in to TIDAL');
        }
        return FutureBuilder<List<Map<String, String>>>(
          future: TidalService.instance.getTrackCredits(server, song.remoteId!),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.accent),
                ),
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

  Widget _buildErrorView(BuildContext context, String message) {
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
        _buildMetadataRow(context, 'Title', song.title),
        _buildMetadataRow(context, 'Artist', song.artist),
        if (song.album != null)
          _buildMetadataRow(context, 'Album', song.album!),
        _buildMetadataRow(context, 'Duration', song.formattedDuration),
        _buildMetadataRow(
          context,
          'Format',
          song.isDsd
              ? '${song.fileType.toUpperCase()} (${song.dsdRateLabel})'
              : song.fileType.toUpperCase(),
        ),
        if (song.resolution != null && !song.isDsd)
          _buildMetadataRow(context, 'Resolution', song.resolution!),
        if (song.albumArtist != null)
          _buildMetadataRow(context, 'Album Artist', song.albumArtist!),
        if (song.genre != null)
          _buildMetadataRow(context, 'Genre', song.genre!),
        if (song.year != null)
          _buildMetadataRow(context, 'Year', song.year!.toString()),
        if (song.trackNumber != null)
          _buildMetadataRow(context, 'Track', song.trackNumber!.toString()),
        if (song.discNumber != null)
          _buildMetadataRow(context, 'Disc', song.discNumber!.toString()),
        if (song.filePath != null)
          _buildMetadataRow(context, 'File Path', song.filePath!),
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
