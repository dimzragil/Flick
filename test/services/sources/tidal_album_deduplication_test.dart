import 'package:flick/services/sources/tidal_album_deduplication.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TidalAlbumDeduplication.normalizeTitle', () {
    test('cleans parentheses and brackets', () {
      expect(
        TidalAlbumDeduplication.normalizeTitle('Awakening(2021 Remaster)'),
        'awakening',
      );
      expect(
        TidalAlbumDeduplication.normalizeTitle('Island (Deluxe Edition)'),
        'island',
      );
      expect(
        TidalAlbumDeduplication.normalizeTitle('Album [Remastered]'),
        'album',
      );
    });

    test('normalizes punctuation and whitespace', () {
      expect(
        TidalAlbumDeduplication.normalizeTitle('  Live Album:   Island in Full  '),
        'live album island in full',
      );
      expect(
        TidalAlbumDeduplication.normalizeTitle('Think of You'),
        'think of you',
      );
    });

    test('handles empty or special strings', () {
      expect(TidalAlbumDeduplication.normalizeTitle(''), '');
      expect(TidalAlbumDeduplication.normalizeTitle(null), '');
      expect(TidalAlbumDeduplication.normalizeTitle('(1999)'), '1999');
    });
  });

  group('TidalAlbumDeduplication.qualityScore', () {
    test('ranks Hi-Res higher than CD, and CD higher than AAC', () {
      final hiRes = {
        'id': 1,
        'audioQuality': 'HI_RES_LOSSLESS',
        'mediaMetadata': {
          'tags': ['LOSSLESS', 'HIRES_LOSSLESS'],
        },
      };
      final cd = {
        'id': 2,
        'audioQuality': 'LOSSLESS',
        'mediaMetadata': {
          'tags': ['LOSSLESS'],
        },
      };
      final aac = {
        'id': 3,
        'audioQuality': 'HIGH',
      };

      expect(
        TidalAlbumDeduplication.qualityScore(hiRes),
        greaterThan(TidalAlbumDeduplication.qualityScore(cd)),
      );
      expect(
        TidalAlbumDeduplication.qualityScore(cd),
        greaterThan(TidalAlbumDeduplication.qualityScore(aac)),
      );
    });

    test('explicit release scores higher when format is identical', () {
      final explicit = {
        'id': 1,
        'audioQuality': 'LOSSLESS',
        'explicit': true,
      };
      final clean = {
        'id': 1,
        'audioQuality': 'LOSSLESS',
        'explicit': false,
      };

      expect(
        TidalAlbumDeduplication.qualityScore(explicit),
        greaterThan(TidalAlbumDeduplication.qualityScore(clean)),
      );
    });
  });

  group('TidalAlbumDeduplication.deduplicate', () {
    test('deduplicates identical albums choosing the highest quality', () {
      final albums = [
        {
          'id': 101,
          'title': 'Awakening',
          'audioQuality': 'LOSSLESS',
          'artist': {'id': 99, 'name': 'Asunojokei'},
        },
        {
          'id': 102,
          'title': 'Awakening(2021 Remaster)',
          'audioQuality': 'HI_RES_LOSSLESS',
          'mediaMetadata': {
            'tags': ['LOSSLESS', 'HIRES_LOSSLESS'],
          },
          'artist': {'id': 99, 'name': 'Asunojokei'},
        },
        {
          'id': 201,
          'title': 'Island',
          'audioQuality': 'LOSSLESS',
          'artist': {'id': 99, 'name': 'Asunojokei'},
        },
        {
          'id': 202,
          'title': 'Island',
          'audioQuality': 'LOSSLESS',
          'artist': {'id': 99, 'name': 'Asunojokei'},
        },
      ];

      final result = TidalAlbumDeduplication.deduplicate(albums);

      expect(result.length, 2);
      // For Awakening, Hi-Res 2021 Remaster wins
      expect(result[0]['id'], 102);
      expect(result[0]['title'], 'Awakening(2021 Remaster)');
      // For Island, ID 202 wins as newer tiebreaker
      expect(result[1]['id'], 202);
    });

    test('does not merge albums with the same title from different artists', () {
      final albums = [
        {
          'id': 1,
          'title': '21',
          'artist': {'id': 10, 'name': 'Adele'},
          'audioQuality': 'LOSSLESS',
        },
        {
          'id': 2,
          'title': '21',
          'artist': {'id': 20, 'name': 'Other Artist'},
          'audioQuality': 'LOSSLESS',
        },
      ];

      final result = TidalAlbumDeduplication.deduplicate(albums);
      expect(result.length, 2);
    });
  });

  group('TidalAlbumDeduplication.findOtherVersions', () {
    test('finds alternative versions of an album by matching normalized title', () {
      final allReleases = [
        {
          'id': 101,
          'title': 'Awakening',
          'audioQuality': 'LOSSLESS',
          'artist': {'id': 99, 'name': 'Asunojokei'},
        },
        {
          'id': 102,
          'title': 'Awakening(2021 Remaster)',
          'audioQuality': 'HI_RES_LOSSLESS',
          'mediaMetadata': {
            'tags': ['LOSSLESS', 'HIRES_LOSSLESS'],
          },
          'artist': {'id': 99, 'name': 'Asunojokei'},
        },
        {
          'id': 201,
          'title': 'Island',
          'audioQuality': 'LOSSLESS',
          'artist': {'id': 99, 'name': 'Asunojokei'},
        },
      ];

      final current = allReleases[1]; // Awakening(2021 Remaster)
      final otherVersions = TidalAlbumDeduplication.findOtherVersions(
        current,
        allReleases,
      );

      expect(otherVersions.length, 1);
      expect(otherVersions.first['id'], 101);
      expect(otherVersions.first['title'], 'Awakening');
    });
  });

  group('TidalAlbumDeduplication.filterMoreFromArtist', () {
    test('excludes the current album and all other versions of it', () {
      final allReleases = [
        {
          'id': 101,
          'title': 'Awakening',
          'audioQuality': 'LOSSLESS',
          'artist': {'id': 99, 'name': 'Asunojokei'},
        },
        {
          'id': 102,
          'title': 'Awakening(2021 Remaster)',
          'audioQuality': 'HI_RES_LOSSLESS',
          'mediaMetadata': {
            'tags': ['LOSSLESS', 'HIRES_LOSSLESS'],
          },
          'artist': {'id': 99, 'name': 'Asunojokei'},
        },
        {
          'id': 201,
          'title': 'Island',
          'audioQuality': 'LOSSLESS',
          'artist': {'id': 99, 'name': 'Asunojokei'},
        },
      ];

      final current = allReleases[0]; // Awakening
      final moreFromArtist = TidalAlbumDeduplication.filterMoreFromArtist(
        current,
        allReleases,
      );

      expect(moreFromArtist.length, 1);
      expect(moreFromArtist.first['id'], 201);
      expect(moreFromArtist.first['title'], 'Island');
    });
  });
}
