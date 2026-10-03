import 'package:flutter/material.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/services/sources/tidal_service.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flick/widgets/common/flick_artwork_placeholder.dart';

/// Cover artwork for a TIDAL playlist.
///
/// Renders the playlist's own cover art (squareImage preferred, wide `image`
/// via 3:2 URL) via [TidalService.extractPlaylistCover]. Playlists without any
/// cover metadata show the artwork placeholder — no extra API calls are made.
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

    if (directCover == null || directCover.isEmpty) {
      return fallback;
    }

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
          errorWidget: fallback,
        ),
      ),
    );
  }
}
