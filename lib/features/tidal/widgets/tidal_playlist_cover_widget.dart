import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/services/sources/tidal_service.dart';
import 'package:flick/features/tidal/providers/tidal_providers.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flick/widgets/common/flick_artwork_placeholder.dart';

/// Cover artwork for a TIDAL playlist.
///
/// If the playlist defines direct cover art (squareImage, UUID, URL, images map, etc.),
/// it is rendered immediately via [CachedImageWidget].
/// If the direct cover fails or is missing, it lazily falls back to the cover art
/// of the first track in the playlist via [tidalPlaylistCoverProvider].
class TidalPlaylistCoverWidget extends StatelessWidget {
  final Map<String, dynamic> playlist;
  final double size;
  final double borderRadius;

  const TidalPlaylistCoverWidget({
    super.key,
    required this.playlist,
    required this.size,
    this.borderRadius = AppConstants.radiusSm,
  });

  @override
  Widget build(BuildContext context) {
    final directCover = TidalService.extractPlaylistCover(
      playlist,
      size: size > 160 ? 320 : 160,
    );
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: FlickArtworkPlaceholder(size: size * 0.45, opacity: 0.9),
    );

    final playlistId =
        playlist['uuid']?.toString() ?? playlist['id']?.toString() ?? '';

    final trackFallback = playlistId.isNotEmpty
        ? _PlaylistTrackCover(
            playlistId: playlistId,
            size: size,
            borderRadius: borderRadius,
            fallback: fallback,
          )
        : fallback;

    if (directCover != null && directCover.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: SizedBox(
          width: size,
          height: size,
          child: CachedImageWidget(
            imagePath: directCover,
            width: size,
            height: size,
            useThumbnail: true,
            thumbnailWidth: size > 160 ? 320 : 160,
            thumbnailHeight: size > 160 ? 320 : 160,
            fit: BoxFit.cover,
            placeholder: fallback,
            errorWidget: trackFallback,
          ),
        ),
      );
    }

    return trackFallback;
  }
}

class _PlaylistTrackCover extends ConsumerWidget {
  final String playlistId;
  final double size;
  final double borderRadius;
  final Widget fallback;

  const _PlaylistTrackCover({
    required this.playlistId,
    required this.size,
    required this.borderRadius,
    required this.fallback,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coverAsync = ref.watch(tidalPlaylistCoverProvider(playlistId));
    return coverAsync.when(
      data: (url) {
        if (url == null || url.isEmpty) {
          return fallback;
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: SizedBox(
            width: size,
            height: size,
            child: CachedImageWidget(
              imagePath: url,
              width: size,
              height: size,
              useThumbnail: true,
              thumbnailWidth: size > 160 ? 320 : 160,
              thumbnailHeight: size > 160 ? 320 : 160,
              fit: BoxFit.cover,
              placeholder: fallback,
              errorWidget: fallback,
            ),
          ),
        );
      },
      loading: () => fallback,
      error: (_, __) => fallback,
    );
  }
}
