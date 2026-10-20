/// Utility for deduplicating TIDAL albums and singles while preserving the
/// highest available audio quality (Hi-Res Lossless > CD Lossless > High/AAC).
///
/// Mirrors official TIDAL client behavior:
/// - In discographies and search results, identical releases by the same artist
///   are collapsed to the single highest-fidelity release.
/// - In album detail views, alternate versions (e.g. standard vs deluxe,
///   remastered vs original, or alternate distributor releases) are grouped
///   and surfaced under an "Other releases" section.
class TidalAlbumDeduplication {
  TidalAlbumDeduplication._();

  /// Normalizes an album title for comparison by removing edition/version
  /// suffixes in parentheses/brackets (e.g., "(2021 Remaster)", "[Deluxe]"),
  /// stripping punctuation, and normalizing whitespace and casing.
  static String normalizeTitle(String? title) {
    if (title == null || title.isEmpty) return '';
    // Strip parenthesized/bracketed descriptors like (2021 Remaster), (Deluxe Edition), [Remastered]
    var cleaned = title.replaceAll(RegExp(r'[\(\[\{].*?[\)\]\}]'), '');
    cleaned = cleaned.replaceAll(RegExp(r'[^\w\s]'), '').trim().toLowerCase();
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ');
    if (cleaned.isNotEmpty) return cleaned;
    final fallback =
        title.replaceAll(RegExp(r'[^\w\s]'), '').trim().toLowerCase();
    return fallback.isNotEmpty ? fallback : title.trim().toLowerCase();
  }

  /// Calculates a quality priority score for a TIDAL album.
  /// Higher score = preferred release to display.
  ///
  /// Ranking:
  /// 1. Audio Quality (Hi-Res Lossless > Hi-Res MQA > CD Lossless > AAC High > AAC Low)
  /// 2. Explicit over Clean
  /// 3. Release Date (newer preferred)
  /// 4. Numeric album ID tiebreaker (newer catalog entries have higher IDs)
  static double qualityScore(Map<String, dynamic> album) {
    double score = 0.0;

    final mediaMeta = album['mediaMetadata'] as Map<String, dynamic>?;
    final tags =
        (mediaMeta?['tags'] as List<dynamic>?)?.cast<String>() ?? const [];
    final audioQuality = album['audioQuality'] as String?;

    if (tags.contains('HIRES_LOSSLESS')) {
      score += 1000.0;
    } else if (tags.contains('HIRES_LOSSLESS_MQA')) {
      score += 900.0;
    } else if (tags.contains('LOSSLESS') || audioQuality == 'LOSSLESS') {
      score += 500.0;
    } else if (audioQuality == 'HIGH') {
      score += 200.0;
    } else if (audioQuality == 'LOW') {
      score += 100.0;
    } else {
      score += 50.0;
    }

    if (album['explicit'] == true) {
      score += 50.0;
    }

    // Release date tiebreaker
    final releaseDate = album['releaseDate'] as String?;
    if (releaseDate != null && releaseDate.isNotEmpty) {
      final parsedDate = DateTime.tryParse(releaseDate);
      if (parsedDate != null) {
        score += (parsedDate.millisecondsSinceEpoch / 1e13);
      }
    }

    // Numeric ID tiebreaker (newer entries in TIDAL have larger IDs)
    final idNum = num.tryParse(album['id']?.toString() ?? '0')?.toInt() ?? 0;
    score += (idNum % 10000) / 10000.0;

    return score;
  }

  /// Generates a deduplication key incorporating artist identity and normalized title.
  static String albumGroupKey(Map<String, dynamic> album) {
    final artistMap = album['artist'] as Map<String, dynamic>?;
    final artistId = artistMap?['id']?.toString();
    final artistName = (artistMap?['name'] as String?)?.trim().toLowerCase();
    final artistKey = artistId ?? artistName ?? '';
    final titleKey = normalizeTitle(album['title'] as String?);
    return '${artistKey}_$titleKey';
  }

  /// Deduplicates a list of albums by grouping identical releases by the same
  /// artist and choosing the highest-quality release in each group.
  ///
  /// Preserves the original list order of the winning items.
  static List<Map<String, dynamic>> deduplicate(
    List<Map<String, dynamic>> albums,
  ) {
    if (albums.length <= 1) return albums;

    final groups = <String, List<Map<String, dynamic>>>{};
    final groupOrder = <String>[];

    for (final album in albums) {
      final key = albumGroupKey(album);
      if (!groups.containsKey(key)) {
        groups[key] = [];
        groupOrder.add(key);
      }
      groups[key]!.add(album);
    }

    final results = <Map<String, dynamic>>[];
    for (final key in groupOrder) {
      final group = groups[key]!;
      if (group.length == 1) {
        results.add(group.first);
      } else {
        group.sort((a, b) => qualityScore(b).compareTo(qualityScore(a)));
        results.add(group.first);
      }
    }

    return results;
  }

  /// Finds all other releases/versions of [currentAlbum] among [allArtistAlbums].
  ///
  /// Matches albums that share the same artist and normalized title, but have
  /// a different album ID. Returns them sorted by quality score descending.
  static List<Map<String, dynamic>> findOtherVersions(
    Map<String, dynamic> currentAlbum,
    List<Map<String, dynamic>> allArtistAlbums,
  ) {
    final currentId = currentAlbum['id']?.toString();
    if (currentId == null || allArtistAlbums.isEmpty) return const [];

    final targetKey = albumGroupKey(currentAlbum);
    final targetNormTitle = normalizeTitle(currentAlbum['title'] as String?);

    final matches = <Map<String, dynamic>>[];
    final seenIds = <String>{currentId};

    for (final alb in allArtistAlbums) {
      final id = alb['id']?.toString();
      if (id == null || seenIds.contains(id)) continue;

      final key = albumGroupKey(alb);
      final normTitle = normalizeTitle(alb['title'] as String?);

      if (key == targetKey || normTitle == targetNormTitle) {
        seenIds.add(id);
        matches.add(alb);
      }
    }

    matches.sort((a, b) => qualityScore(b).compareTo(qualityScore(a)));
    return matches;
  }

  /// Filters [allArtistAlbums] for the "More from artist" rail by deduplicating
  /// the albums and removing the [currentAlbum] as well as any other version of it.
  static List<Map<String, dynamic>> filterMoreFromArtist(
    Map<String, dynamic> currentAlbum,
    List<Map<String, dynamic>> allArtistAlbums,
  ) {
    if (allArtistAlbums.isEmpty) return const [];

    final currentId = currentAlbum['id']?.toString();
    final targetNormTitle = normalizeTitle(currentAlbum['title'] as String?);
    final targetKey = albumGroupKey(currentAlbum);

    final deduped = deduplicate(allArtistAlbums);

    return deduped.where((alb) {
      final id = alb['id']?.toString();
      if (id == currentId) return false;
      final key = albumGroupKey(alb);
      final normTitle = normalizeTitle(alb['title'] as String?);
      if (key == targetKey || normTitle == targetNormTitle) return false;
      return true;
    }).toList();
  }
}
