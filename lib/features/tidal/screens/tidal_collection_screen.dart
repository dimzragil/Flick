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
    await Future.wait([
      ref.refresh(tidalLikedSongsProvider.future),
      ref.refresh(tidalLikedAlbumsProvider.future),
      ref.refresh(tidalLikedArtistsProvider.future),
      ref.refresh(tidalUserPlaylistsProvider.future),
    ]);
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
            _buildCollectionTile(
              icon: LucideIcons.disc3,
              title: 'Albums',
              subtitle: _countSubtitle(
                ref.watch(tidalLikedAlbumsProvider),
                'album',
              ),
              screen: const TidalLikedAlbumsScreen(),
            ),
            SizedBox(height: context.scaleSize(AppConstants.spacingSm)),
            _buildCollectionTile(
              icon: LucideIcons.users,
              title: 'Artists',
              subtitle: _countSubtitle(
                ref.watch(tidalLikedArtistsProvider),
                'artist',
              ),
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
    return _buildCollectionTile(
      icon: LucideIcons.listMusic,
      title: 'Playlists',
      subtitle: playlistsAsync.when(
        data: (items) => _countText(items.length, 'playlist'),
        loading: () => 'Loading...',
        error: (_, _) => 'Could not load',
      ),
      screen: const TidalPlaylistsScreen(),
    );
  }

  String _countText(int count, String noun) =>
      '$count $noun${count == 1 ? '' : 's'}';

  String _countSubtitle(
    AsyncValue<List<Map<String, dynamic>>> value,
    String noun,
  ) => value.when(
    data: (items) => _countText(items.length, noun),
    loading: () => 'Loading...',
    error: (_, _) => 'Could not load',
  );

  Widget _buildCollectionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget screen,
  }) {
    return PressScale(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        leading: Icon(
          icon,
          color: AppColors.textSecondary,
          size: context.scaleSize(24),
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
        trailing: const Icon(
          LucideIcons.chevronRight,
          size: 18,
          color: AppColors.textSecondary,
        ),
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => screen)),
      ),
    );
  }

  /// Liked Songs is the first row of Collection and opens the TIDAL favorites.
  Widget _buildLikedSongsTile() {
    final likedAsync = ref.watch(tidalLikedSongsProvider);
    return _buildCollectionTile(
      icon: LucideIcons.heart,
      title: 'Liked Songs',
      subtitle: likedAsync.when(
        data: (songs) => _countText(songs.length, 'track'),
        loading: () => 'Loading...',
        error: (err, _) => isTidalRateLimitError(err)
            ? 'Rate limited — try again soon'
            : 'Could not load',
      ),
      screen: const TidalLikedSongsScreen(),
    );
  }
}
