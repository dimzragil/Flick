import 'package:flutter_test/flutter_test.dart';
import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/models/song.dart';
import 'package:flick/models/sources/tidal_models.dart';
import 'package:flick/services/sources/tidal_service.dart';

void main() {
  NetworkServerEntity server() => NetworkServerEntity()
    ..id = 9
    ..label = 'Tidal'
    ..protocol = 'tidal'
    ..baseUrl = TidalService.tidalBaseUrl;

  group('makeEphemeralSong - Explicit badge plumbing', () {
    test('marks isExplicit == true when trackJson explicit is true', () {
      final track = {
        'id': 1001,
        'title': 'Explicit Track',
        'duration': 180,
        'explicit': true,
        'artists': [
          {'name': 'Artist A'},
        ],
      };

      final song = TidalService.makeEphemeralSong(server(), track);
      expect(song.isExplicit, isTrue);
    });

    test('marks isExplicit == false when trackJson explicit is false', () {
      final track = {
        'id': 1002,
        'title': 'Clean Track',
        'duration': 180,
        'explicit': false,
        'artists': [
          {'name': 'Artist B'},
        ],
      };

      final song = TidalService.makeEphemeralSong(server(), track);
      expect(song.isExplicit, isFalse);
    });

    test('marks isExplicit == false when trackJson explicit is absent', () {
      final track = {
        'id': 1003,
        'title': 'Unknown Track',
        'duration': 180,
        'artists': [
          {'name': 'Artist C'},
        ],
      };

      final song = TidalService.makeEphemeralSong(server(), track);
      expect(song.isExplicit, isFalse);
    });

    test(
      'unwraps playlist item container and reads explicit from unwrapped track',
      () {
        final wrapped = {
          'type': 'track',
          'explicit': false, // raw map has false or absent
          'item': {
            'id': 1004,
            'title': 'Wrapped Explicit',
            'duration': 210,
            'explicit': true,
            'artists': [
              {'name': 'Artist D'},
            ],
          },
        };

        final song = TidalService.makeEphemeralSong(server(), wrapped);
        expect(song.isExplicit, isTrue);
      },
    );

    test(
      'ignores raw container explicit when unwrapped item explicit is absent',
      () {
        final wrapped = {
          'type': 'track',
          'explicit': true, // only container has it, track itself does not
          'item': {
            'id': 1005,
            'title': 'Wrapped Clean',
            'duration': 210,
            'artists': [
              {'name': 'Artist E'},
            ],
          },
        };

        final song = TidalService.makeEphemeralSong(server(), wrapped);
        expect(song.isExplicit, isFalse);
      },
    );
  });

  group('makeEphemeralSong - Dolby Atmos plumbing', () {
    test(
      'sets isAtmos == true when mediaMetadata.tags contains DOLBY_ATMOS',
      () {
        final track = {
          'id': 2001,
          'title': 'Atmos Track via Tags',
          'duration': 200,
          'mediaMetadata': {
            'tags': ['DOLBY_ATMOS', 'LOSSLESS'],
          },
          'artists': [
            {'name': 'Artist F'},
          ],
        };

        final song = TidalService.makeEphemeralSong(server(), track);
        expect(song.isAtmos, isTrue);
      },
    );

    test('sets isAtmos == true when track audioModes contains DOLBY_ATMOS', () {
      final track = {
        'id': 2002,
        'title': 'Atmos Track via track audioModes',
        'duration': 200,
        'audioModes': ['STEREO', 'DOLBY_ATMOS'],
        'artists': [
          {'name': 'Artist G'},
        ],
      };

      final song = TidalService.makeEphemeralSong(server(), track);
      expect(song.isAtmos, isTrue);
    });

    test(
      'sets isAtmos == true when raw container audioModes contains DOLBY_ATMOS',
      () {
        final wrapped = {
          'type': 'track',
          'audioModes': ['DOLBY_ATMOS'],
          'item': {
            'id': 2003,
            'title': 'Wrapped Atmos',
            'duration': 200,
            'artists': [
              {'name': 'Artist H'},
            ],
          },
        };

        final song = TidalService.makeEphemeralSong(server(), wrapped);
        expect(song.isAtmos, isTrue);
      },
    );

    test(
      'sets isAtmos == false when neither tags nor audioModes specify DOLBY_ATMOS',
      () {
        final track = {
          'id': 2004,
          'title': 'Stereo Track',
          'duration': 200,
          'audioModes': ['STEREO'],
          'mediaMetadata': {
            'tags': ['LOSSLESS'],
          },
          'artists': [
            {'name': 'Artist I'},
          ],
        };

        final song = TidalService.makeEphemeralSong(server(), track);
        expect(song.isAtmos, isFalse);
      },
    );

    test('supports tracks that are both explicit and Atmos', () {
      final track = {
        'id': 2005,
        'title': 'Explicit Atmos Track',
        'duration': 240,
        'explicit': true,
        'audioModes': ['DOLBY_ATMOS'],
        'artists': [
          {'name': 'Artist J'},
        ],
      };

      final song = TidalService.makeEphemeralSong(server(), track);
      expect(song.isExplicit, isTrue);
      expect(song.isAtmos, isTrue);
    });
  });

  group('Song model - isExplicit & isAtmos serialization and copyWith', () {
    test('toJson and fromJson preserves isExplicit and isAtmos', () {
      final original = Song(
        id: 'tidal_9_3001',
        title: 'Serialization Test',
        artist: 'Test Artist',
        fileType: 'flac',
        duration: const Duration(seconds: 150),
        filePath: 'tidal://9/3001',
        isExplicit: true,
        isAtmos: true,
      );

      final json = original.toJson();
      expect(json['isExplicit'], isTrue);
      expect(json['isAtmos'], isTrue);

      final restored = Song.fromJson(json);
      expect(restored.isExplicit, isTrue);
      expect(restored.isAtmos, isTrue);
    });

    test('toJson and fromJson handles null isExplicit and isAtmos', () {
      final original = Song(
        id: 'local_1',
        title: 'Local Track',
        artist: 'Local Artist',
        fileType: 'flac',
        duration: const Duration(seconds: 120),
        filePath: '/music/track.flac',
      );

      final json = original.toJson();
      expect(json['isExplicit'], isNull);
      expect(json['isAtmos'], isNull);

      final restored = Song.fromJson(json);
      expect(restored.isExplicit, isNull);
      expect(restored.isAtmos, isNull);
    });

    test('copyWith preserves and overrides isExplicit and isAtmos', () {
      final original = Song(
        id: 'tidal_9_3002',
        title: 'Copy Test',
        artist: 'Artist',
        fileType: 'flac',
        duration: const Duration(seconds: 100),
        filePath: 'tidal://9/3002',
        isExplicit: true,
        isAtmos: false,
      );

      final copiedUnchanged = original.copyWith();
      expect(copiedUnchanged.isExplicit, isTrue);
      expect(copiedUnchanged.isAtmos, isFalse);

      final copiedChanged = original.copyWith(isExplicit: false, isAtmos: true);
      expect(copiedChanged.isExplicit, isFalse);
      expect(copiedChanged.isAtmos, isTrue);
    });
  });

  group('TidalHomeItem - isExplicit and isAtmos getters', () {
    test('extracts explicit and atmos from raw track item', () {
      final item = TidalHomeItem(
        id: '4001',
        title: 'Home Track',
        type: 'TRACK',
        raw: {
          'explicit': true,
          'audioModes': ['DOLBY_ATMOS'],
        },
      );

      expect(item.isExplicit, isTrue);
      expect(item.isAtmos, isTrue);
    });

    test('extracts explicit and atmos from wrapped item', () {
      final item = TidalHomeItem(
        id: '4002',
        title: 'Home Wrapped Track',
        type: 'TRACK',
        raw: {
          'item': {
            'explicit': true,
            'mediaMetadata': {
              'tags': ['DOLBY_ATMOS'],
            },
          },
        },
      );

      expect(item.isExplicit, isTrue);
      expect(item.isAtmos, isTrue);
    });

    test('returns null when explicit or atmos are absent', () {
      final item = TidalHomeItem(
        id: '4003',
        title: 'Clean Home Track',
        type: 'TRACK',
        raw: {
          'audioModes': ['STEREO'],
        },
      );

      expect(item.isExplicit, isNull);
      expect(item.isAtmos, isNull);
    });
  });

  group('buildSongEntity - Explicit & Atmos mapping', () {
    test('populates isExplicit and isAtmos on SongEntity', () {
      final track = {
        'id': 5001,
        'title': 'Entity Track',
        'duration': 190,
        'explicit': true,
        'audioModes': ['DOLBY_ATMOS'],
        'artists': [
          {'name': 'Entity Artist'},
        ],
      };

      final entity = TidalService.buildSongEntity(server(), track);
      expect(entity, isNotNull);
      expect(entity!.isExplicit, isTrue);
      expect(entity.isAtmos, isTrue);
    });

    test('unwraps item when mapping to SongEntity', () {
      final wrapped = {
        'type': 'track',
        'item': {
          'id': 5002,
          'title': 'Wrapped Entity Track',
          'duration': 190,
          'explicit': true,
          'mediaMetadata': {
            'tags': ['DOLBY_ATMOS'],
          },
          'artists': [
            {'name': 'Entity Artist'},
          ],
        },
      };

      final entity = TidalService.buildSongEntity(server(), wrapped);
      expect(entity, isNotNull);
      expect(entity!.isExplicit, isTrue);
      expect(entity.isAtmos, isTrue);
    });
  });
}
