import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/song.dart';
import '../../../providers/player_provider.dart';
import '../../../services/sources/network_source_service.dart';
import '../../../services/sources/tidal_service.dart';
import '../../../widgets/common/song_badges.dart';

/// Maps a track's *delivered* TIDAL stream quality to the now-playing title
/// color used in TIDAL lists.
///
/// Gold = Hi-Res, cyan = CD quality or below, null = default title color.
///
/// The tier always wins over a conflicting bit depth: a Hi-Res tier that
/// delivers 16-bit samples is still Hi-Res, because the tier describes the
/// stream that actually plays. Only when the resolved tier is not one of the
/// known tiers do we fall back to the delivered bit depth. An unknown bit
/// depth never produces a color.
Color? tidalNowPlayingTitleColor(TidalStreamResolution? resolution) {
  if (resolution == null) return null;

  switch (resolution.audioQuality.toUpperCase()) {
    case 'HI_RES':
    case 'HI_RES_LOSSLESS':
      // Tier wins on tier/bitDepth disagreement: a Hi-Res tier delivering
      // 16-bit samples still reads as Hi-Res (gold), matching the delivered
      // tier that actually plays instead of the observed sample format.
      return AppColors.nowPlayingHiRes;
    case 'LOSSLESS':
    case 'HIGH':
      return AppColors.nowPlayingCdAndBelow;
  }

  // The resolved tier is unknown (for example DOLBY_ATMOS, which is neither
  // a Hi-Res nor a CD tier). Fall back to the delivered bit depth, and only
  // when that depth is known — never guess a color from unknown data.
  if (!resolution.isBitDepthExplicit) return null;
  if (resolution.bitDepth >= 24) return AppColors.nowPlayingHiRes;
  if (resolution.bitDepth > 0) return AppColors.nowPlayingCdAndBelow;
  return null;
}

/// A [SongTitleRow] whose title is tinted when [songId] (or [tidalTrackId])
/// is the player's current track.
///
/// Only the title color changes. Badges, subtitle, artwork, and layout are
/// rendered exactly as before, and this widget has no effect at all for
/// local/non-TIDAL tracks or when no delivered quality is known yet.
///
/// The tint follows the delivered playback quality, read from the TIDAL
/// service's cached stream resolution. [TidalService.streamResolutionVersion]
/// fires when a stream finishes resolving, so a row stays at the default
/// color while its track is resolving and colors as soon as the resolve
/// completes. Position updates are deliberately not observed.
class TidalNowPlayingTitle extends ConsumerWidget {
  /// Title text, forwarded unchanged to [SongTitleRow].
  final String title;

  /// Identity of a TIDAL list row, matched against the current song's id.
  final String? songId;

  /// Identity of a TIDAL Hub row, matched against the current song's remote
  /// track id (Hub items carry only the catalog track id, not the local
  /// `tidal_<server>_<track>` song id).
  final String? tidalTrackId;

  final TextStyle? style;
  final bool? isExplicit;
  final bool? isAtmos;
  final bool? isHiRes;
  final TextAlign? textAlign;
  final Color? badgeColor;
  final Color? badgeBackgroundColor;

  /// Test seams for the delivered-resolution lookup. Production call sites
  /// leave these null so the shared TIDAL service cache is used.
  final TidalStreamResolution? Function(String trackId)? resolutionLookup;
  final ValueListenable<int>? resolutionVersionListenable;

  const TidalNowPlayingTitle({
    super.key,
    required this.title,
    this.songId,
    this.tidalTrackId,
    this.style,
    this.isExplicit,
    this.isAtmos,
    this.isHiRes,
    this.textAlign,
    this.badgeColor,
    this.badgeBackgroundColor,
    this.resolutionLookup,
    this.resolutionVersionListenable,
  }) : assert(
         (songId == null) != (tidalTrackId == null),
         'Provide exactly one row identity: songId or tidalTrackId.',
       );

  /// Returns the current row's identity only when it is the current track.
  ///
  /// Keeping this as a `select` means unrelated rows do not rebuild when the
  /// current track changes: only the old and the new current row see their
  /// selected value change.
  ({bool isCurrent, String? trackId}) _selectNowPlaying(Song? song) {
    if (song == null || !_isCurrentSong(song)) {
      return (isCurrent: false, trackId: null);
    }
    return (isCurrent: true, trackId: song.remoteId);
  }

  bool _isCurrentSong(Song song) {
    // Local/other-source rows must keep their default color. The queue
    // screen shares this widget between TIDAL and local tracks.
    final isTidal =
        song.sourceType == NetworkProtocol.tidal ||
        (song.filePath?.startsWith('tidal://') ?? false) ||
        song.id.startsWith('tidal_');
    if (!isTidal) return false;

    final rowSongId = songId;
    if (rowSongId != null) return song.id == rowSongId;
    return song.remoteId != null && song.remoteId == tidalTrackId;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nowPlaying = ref.watch(currentSongProvider.select(_selectNowPlaying));

    final trackId = nowPlaying.trackId;
    if (!nowPlaying.isCurrent || trackId == null) {
      return _buildTitle(null);
    }

    final version =
        resolutionVersionListenable ??
        TidalService.instance.streamResolutionVersion;
    return ValueListenableBuilder<int>(
      valueListenable: version,
      builder: (context, _, _) {
        final lookup =
            resolutionLookup ?? TidalService.instance.getResolvedStream;
        return _buildTitle(tidalNowPlayingTitleColor(lookup(trackId)));
      },
    );
  }

  Widget _buildTitle(Color? tint) {
    final effectiveStyle = tint == null
        ? style
        : (style ?? const TextStyle()).copyWith(color: tint);
    return SongTitleRow(
      title: title,
      style: effectiveStyle,
      isExplicit: isExplicit,
      isAtmos: isAtmos,
      isHiRes: isHiRes,
      textAlign: textAlign,
      badgeColor: badgeColor,
      badgeBackgroundColor: badgeBackgroundColor,
    );
  }
}
