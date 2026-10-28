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
import 'tidal_artist_screen.dart';

class TidalLikedArtistsScreen extends ConsumerWidget {
  const TidalLikedArtistsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artists = ref.watch(tidalLikedArtistsProvider);
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
          'Artists',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: RefreshIndicator(
        color: AppColors.textPrimary,
        backgroundColor: AppColors.surface,
        onRefresh: () => ref.refresh(tidalLikedArtistsProvider.future),
        child: artists.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: const [
              SizedBox(
                height: 280,
                child: Center(
                  child: Text(
                    'Could not load followed artists. Pull to retry.',
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
                            'No followed artists yet — tap Follow on any artist.',
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
                    final artist = items[index];
                    final id = artist['id']?.toString();
                    final name = artist['name']?.toString() ?? 'Unknown Artist';
                    final picture =
                        (artist['picture'] ??
                                artist['selectedAlbumCoverFallback'])
                            ?.toString();
                    final pictureUrl = picture == null || picture.isEmpty
                        ? null
                        : TidalService.artistPictureUrl(picture, size: 160);
                    final size = context.scaleSize(52);
                    return PressScale(
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        leading: ClipOval(
                          child: SizedBox(
                            width: size,
                            height: size,
                            child: pictureUrl == null
                                ? const FlickArtworkPlaceholder()
                                : CachedImageWidget(
                                    imagePath: pictureUrl,
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
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        onTap: id == null
                            ? null
                            : () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => TidalArtistScreen(
                                    artistId: id,
                                    initialArtistData: artist,
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
