import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/responsive.dart';
import '../../../services/sources/tidal_service.dart';
import '../../../widgets/common/cached_image_widget.dart';
import '../../../widgets/common/flick_artwork_placeholder.dart';
import '../providers/tidal_providers.dart';
import '../widgets/press_scale.dart';
import 'tidal_album_screen.dart';

class TidalLikedAlbumsScreen extends ConsumerWidget {
  const TidalLikedAlbumsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(tidalLikedAlbumsProvider);
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
          'Albums',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: RefreshIndicator(
        color: AppColors.textPrimary,
        backgroundColor: AppColors.surface,
        onRefresh: () => ref.refresh(tidalLikedAlbumsProvider.future),
        child: albums.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: const [
              SizedBox(
                height: 280,
                child: Center(
                  child: Text(
                    'Could not load loved albums. Pull to retry.',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                ),
              ),
            ],
          ),
          data: (items) => items.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const [
                    SizedBox(
                      height: 280,
                      child: Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'No loved albums yet — tap the heart on any album.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.textSecondary),
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.symmetric(
                    horizontal: context.scaleSize(AppConstants.spacingMd),
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final album = items[index];
                    final id = album['id']?.toString();
                    final title = album['title']?.toString() ?? 'Unknown Album';
                    final artist = album['artist'];
                    final artistName = artist is Map
                        ? artist['name']?.toString() ?? ''
                        : artist?.toString() ?? '';
                    final cover = album['cover']?.toString();
                    final coverUrl = cover == null || cover.isEmpty
                        ? null
                        : TidalService.coverUrl(cover, size: 320);
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
                                    placeholder:
                                        const FlickArtworkPlaceholder(),
                                    errorWidget:
                                        const FlickArtworkPlaceholder(),
                                  ),
                          ),
                        ),
                        title: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        subtitle: Text(
                          artistName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                        onTap: id == null
                            ? null
                            : () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => TidalAlbumScreen(
                                    albumId: id,
                                    initialAlbumData: album,
                                  ),
                                ),
                              ),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
