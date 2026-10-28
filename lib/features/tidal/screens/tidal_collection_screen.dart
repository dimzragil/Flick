import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/responsive.dart';
import '../providers/tidal_providers.dart';
import '../widgets/press_scale.dart';
import '../widgets/tidal_error_widget.dart';
import 'tidal_liked_albums_screen.dart';
import 'tidal_liked_artists_screen.dart';
import 'tidal_liked_songs_screen.dart';
import 'tidal_playlists_screen.dart';

class TidalCollectionScreen extends ConsumerStatefulWidget {
  const TidalCollectionScreen({super.key});

  @override
  ConsumerState<TidalCollectionScreen> createState() =>
      _TidalCollectionScreenState();
}

class _TidalCollectionScreenState extends ConsumerState<TidalCollectionScreen> {
  Future<void> _refreshCollection() async {
    final _ = await ref.refresh(tidalLikedSongsProvider.future);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: const Text('Collection'),
      ),
      body: RefreshIndicator(
        color: const Color(0xD9FFFFFF),
        backgroundColor: AppColors.surface,
        onRefresh: _refreshCollection,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.all(context.scaleSize(AppConstants.spacingMd)),
          children: [
            _buildLikedSongsTile(),
            SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
            _buildPlaylistsTile(),
            SizedBox(height: context.scaleSize(AppConstants.spacingMd)),
            _buildPlaceholder(
              icon: LucideIcons.disc3,
              title: 'Albums',
              message:
                  'Albums you love will appear here once album liking lands.',
              screen: const TidalLikedAlbumsScreen(),
            ),
            SizedBox(height: context.scaleSize(AppConstants.spacingSm)),
            _buildPlaceholder(
              icon: LucideIcons.users,
              title: 'Artists',
              message:
                  'Artists you love will appear here once artist liking lands.',
              screen: const TidalLikedArtistsScreen(),
            ),
            SizedBox(height: context.scaleSize(AppConstants.spacingXl * 2)),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaylistsTile() {
    final playlistsAsync = ref.watch(tidalUserPlaylistsProvider);

    return PressScale(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
        leading: Icon(
          LucideIcons.listMusic,
          size: context.scaleSize(24),
          color: AppColors.textSecondary,
        ),
        title: const Text(
          'Playlists',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: playlistsAsync.when(
          data: (playlists) => Text(
            '${playlists.length} playlists',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
          loading: () => const Text(
            'Loading...',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
          error: (_, _) => const Text(
            'Could not load',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
        ),
        trailing: const Icon(
          LucideIcons.chevronRight,
          color: AppColors.textSecondary,
          size: 18,
        ),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const TidalPlaylistsScreen()),
          );
        },
      ),
    );
  }

  Widget _buildPlaceholder({
    required IconData icon,
    required String title,
    required String message,
    required Widget screen,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      leading: Icon(icon, color: AppColors.textSecondary, size: 24),
      title: Text(title, style: const TextStyle(color: AppColors.textPrimary)),
      subtitle: Text(
        message,
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
      ),
      trailing: const Icon(
        LucideIcons.chevronRight,
        size: 18,
        color: AppColors.textSecondary,
      ),
      onTap: () {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
      },
    );
  }

  /// Liked Songs is the first row of Collection and opens the TIDAL favorites.
  Widget _buildLikedSongsTile() {
    final likedAsync = ref.watch(tidalLikedSongsProvider);
    final size = context.scaleSize(52);

    return PressScale(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
        leading: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppConstants.radiusSm),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Colors.pinkAccent, Colors.purpleAccent],
            ),
          ),
          child: Icon(
            LucideIcons.heart,
            color: Colors.white,
            size: context.scaleSize(24),
          ),
        ),
        title: const Text(
          'Liked Songs',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: likedAsync.when(
          data: (songs) => Text(
            '${songs.length} tracks',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
          loading: () => const Text(
            'Loading...',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
          error: (err, _) => Text(
            isTidalRateLimitError(err)
                ? 'Rate limited — try again soon'
                : 'Could not load',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
        ),
        trailing: const Icon(
          LucideIcons.chevronRight,
          color: AppColors.textSecondary,
          size: 18,
        ),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const TidalLikedSongsScreen()),
          );
        },
      ),
    );
  }
}
