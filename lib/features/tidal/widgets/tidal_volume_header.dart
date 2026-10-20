import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/responsive.dart';
import '../../../models/song.dart';

/// Width of the track-number gutter in the TIDAL album track list — the
/// fixed width of a track row's leading slot.
const double kTidalTrackNumberColumnWidth = 28;

/// A row of the TIDAL album track list: either a volume header or a track.
///
/// The list is flattened up front (headers interleaved with tracks) so the
/// sliver index maps 1:1 onto rendered rows — no index arithmetic is needed
/// to work out which track a row shows or where it sits in the album.
sealed class TidalAlbumListItem {
  const TidalAlbumListItem();
}

/// Header introducing one volume of a multi-disc TIDAL album.
class TidalVolumeHeaderItem extends TidalAlbumListItem {
  const TidalVolumeHeaderItem({required this.volume, required this.trackCount});

  /// 1-based volume number, as TIDAL reports it in `volumeNumber`.
  final int volume;

  /// Number of tracks in this volume.
  final int trackCount;
}

/// A track row, carrying the track's position in the *full* album list.
class TidalAlbumTrackItem extends TidalAlbumListItem {
  const TidalAlbumTrackItem({required this.song, required this.globalIndex});

  final Song song;

  /// Index of [song] in the album's full, API-ordered track list.
  ///
  /// Headers are display-only and never consume an index, so this stays the
  /// position playback starts from — a track after a "Volume 2" header still
  /// reports its real place in the album.
  final int globalIndex;
}

/// Effective volume number for [song].
///
/// TIDAL reports the disc as `volumeNumber` (1-based, parsed into
/// `Song.discNumber`). Missing or non-positive values mean "no disc info",
/// which is treated as volume 1 — the same convention the local artist and
/// search screens use when sorting by disc.
int tidalVolumeOf(Song song) {
  final disc = song.discNumber;
  return (disc != null && disc > 0) ? disc : 1;
}

/// Flattens [tracks] into the rows the TIDAL album screen renders.
///
/// Single-disc albums (every track on the same volume) come back as one
/// track per row — exactly the previous flat list, no header.
///
/// Multi-disc albums get a header before the first track of each volume.
/// Tracks are grouped by volume in the order the volumes first appear in the
/// API response, and the API order is preserved inside each volume. The
/// playlist handed to playback is unaffected: grouping is a display concern
/// only, and every track keeps its [TidalAlbumTrackItem.globalIndex] in the
/// untouched API list.
List<TidalAlbumListItem> buildTidalAlbumListItems(List<Song> tracks) {
  if (tracks.isEmpty) return const [];

  // Track indices per volume, plus the order the volumes first appear in.
  final indicesByVolume = <int, List<int>>{};
  final volumeOrder = <int>[];
  for (var i = 0; i < tracks.length; i++) {
    final volume = tidalVolumeOf(tracks[i]);
    final indices = indicesByVolume.putIfAbsent(volume, () {
      volumeOrder.add(volume);
      return <int>[];
    });
    indices.add(i);
  }

  // Single-disc album: exactly the current behaviour, no headers.
  if (volumeOrder.length <= 1) {
    return [
      for (var i = 0; i < tracks.length; i++)
        TidalAlbumTrackItem(song: tracks[i], globalIndex: i),
    ];
  }

  final items = <TidalAlbumListItem>[];
  for (final volume in volumeOrder) {
    final indices = indicesByVolume[volume]!;
    items.add(
      TidalVolumeHeaderItem(volume: volume, trackCount: indices.length),
    );
    for (final index in indices) {
      items.add(TidalAlbumTrackItem(song: tracks[index], globalIndex: index));
    }
  }
  return items;
}

/// Header row introducing a volume of a multi-disc TIDAL album.
///
/// TIDAL's own naming is "Volume N", so the label follows suit. The accent
/// bar is tinted with the album's dominant colour when one is available,
/// falling back to the app's neutral accent.
class TidalVolumeHeaderRow extends StatelessWidget {
  const TidalVolumeHeaderRow({
    super.key,
    required this.volume,
    required this.trackCount,
    this.accentColor,
  });

  /// 1-based volume number.
  final int volume;

  /// Number of tracks in this volume.
  final int trackCount;

  /// Album's dominant colour, used for the accent bar.
  final Color? accentColor;

  /// Width of the accent bar.
  static const double _barWidth = 3;

  /// Gap between the accent bar and the label.
  static const double _barGap = 6;

  @override
  Widget build(BuildContext context) {
    final accent = accentColor ?? AppColors.accentDim;
    // A track row pads its content by `spacingSm`, reserves the track-number
    // gutter and then leaves the list tile's title gap; the label lines up
    // with the track titles that follow.
    final titleGap = ListTileTheme.of(context).horizontalTitleGap ?? 16;
    final titleInset =
        context.scaleSize(AppConstants.spacingSm) +
        kTidalTrackNumberColumnWidth +
        titleGap;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        titleInset - _barWidth - _barGap,
        AppConstants.spacingMd,
        context.scaleSize(AppConstants.spacingSm),
        AppConstants.spacingXs,
      ),
      child: Row(
        children: [
          Container(
            width: _barWidth,
            height: 14,
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(AppConstants.radiusXs),
            ),
          ),
          const SizedBox(width: _barGap),
          Text(
            'Volume $volume',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
          const Spacer(),
          Text(
            trackCount == 1 ? '1 track' : '$trackCount tracks',
            style: const TextStyle(color: AppColors.textTertiary, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
