import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/navigation_helper.dart';
import '../../../core/utils/responsive.dart';
import '../../../services/sources/tidal_service.dart';
import '../../../widgets/common/cached_image_widget.dart';
import '../../../widgets/common/flick_artwork_placeholder.dart';
import '../widgets/press_scale.dart';
import 'tidal_album_screen.dart';

class TidalArtistReleasesScreen extends StatelessWidget {
  final String title;
  final List<Map<String, dynamic>> items;

  const TidalArtistReleasesScreen({
    super.key,
    required this.title,
    required this.items,
  });

  String get _countLabel {
    final count = items.length;
    final noun = switch (title) {
      'Albums' => count == 1 ? 'album' : 'albums',
      'Singles & EPs' => count == 1 ? 'single or EP' : 'singles & EPs',
      'Compilations' => count == 1 ? 'compilation' : 'compilations',
      _ => count == 1 ? title.toLowerCase() : title.toLowerCase(),
    };
    return '$count $noun';
  }

  void _openAlbum(BuildContext context, Map<String, dynamic> album) {
    final albumId = album['id']?.toString();
    if (albumId == null) return;
    NavigationHelper.pushSharedAxis(
      context,
      (_) => TidalAlbumScreen(albumId: albumId, initialAlbumData: album),
    );
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
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              _countLabel,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
      body: items.isEmpty
          ? const Center(
              child: Text(
                'No releases available.',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.symmetric(
                horizontal: context.scaleSize(AppConstants.spacingMd),
              ),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final album = items[index];
                final albumTitle =
                    album['title']?.toString() ?? 'Unknown Album';
                final cover = album['cover']?.toString();
                final coverUrl = cover == null || cover.isEmpty
                    ? null
                    : TidalService.coverUrl(cover, size: 320);
                final releaseDate = album['releaseDate']?.toString();
                final year = releaseDate != null && releaseDate.length >= 4
                    ? releaseDate.substring(0, 4)
                    : null;
                final size = context.scaleSize(52);

                return PressScale(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(
                        AppConstants.radiusSm,
                      ),
                      child: SizedBox(
                        width: size,
                        height: size,
                        child: coverUrl == null
                            ? const FlickArtworkPlaceholder()
                            : CachedImageWidget(
                                imagePath: coverUrl,
                                width: size,
                                height: size,
                                fit: BoxFit.cover,
                                placeholder: const FlickArtworkPlaceholder(),
                                errorWidget: const FlickArtworkPlaceholder(),
                              ),
                      ),
                    ),
                    title: Text(
                      albumTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    subtitle: year == null
                        ? null
                        : Text(
                            year,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                    onTap: () => _openAlbum(context, album),
                  ),
                );
              },
            ),
    );
  }
}
