import 'dart:convert';

import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/last_played_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSongRepository implements SongRepository {
  _FakeSongRepository(this.songs);

  final List<Song> songs;
  int reads = 0;

  @override
  Future<List<Song>> getAllSongs() async {
    reads++;
    return songs;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Song JSON serialization', () {
    test('preserves all song fields, including TIDAL source metadata', () {
      final original = Song(
        id: 'tidal_9_12345678',
        title: 'Starboy',
        artist: 'The Weeknd',
        albumArt: 'https://resources.tidal.com/images/123/640x640.jpg',
        duration: const Duration(minutes: 3, seconds: 50),
        fileType: 'flac',
        resolution: '16-bit / 44.1kHz / 1411kbps',
        sampleRate: 44100,
        bitDepth: 16,
        replaygainTrackGain: -4.25,
        replaygainTrackPeak: 0.98,
        replaygainAlbumGain: -3.5,
        replaygainAlbumPeak: 0.99,
        startOffsetMs: 120,
        endOffsetMs: 180000,
        ripper: 'Exact Audio Copy',
        readMode: 'Secure',
        accurateRip: true,
        testCrc: 'ABCD1234',
        copyCrc: 'EF567890',
        album: 'Starboy',
        albumArtist: 'The Weeknd',
        trackNumber: 1,
        discNumber: 1,
        year: 2016,
        genre: 'Pop',
        filePath: 'tidal://9/12345678',
        folderUri: 'content://music',
        dateAdded: DateTime.utc(2024, 5, 6),
        isExternal: true,
        sourcePackage: 'com.example.source',
        sourceType: 'tidal',
        remoteId: '12345678',
        remoteServerId: 9,
      );

      final restored = Song.fromJson(jsonDecode(jsonEncode(original.toJson())));

      expect(restored.toJson(), original.toJson());
      expect(restored.isNetworkSource, isTrue);
    });

    test('uses safe defaults for absent or malformed optional values', () {
      final restored = Song.fromJson({
        'id': 'partial',
        'sampleRate': 'not-a-number',
        'dateAdded': 42,
        'isExternal': 'false',
      });

      expect(restored.id, 'partial');
      expect(restored.title, isEmpty);
      expect(restored.artist, isEmpty);
      expect(restored.duration, Duration.zero);
      expect(restored.fileType, 'flac');
      expect(restored.sampleRate, isNull);
      expect(restored.dateAdded, isNull);
      expect(restored.isExternal, isFalse);
    });
  });

  group('LastPlayedService restoration', () {
    test(
      'restores ephemeral TIDAL song and playlist without reading Isar',
      () async {
        const firstTrack = Song(
          id: 'tidal_9_999888',
          title: 'Blinding Lights',
          artist: 'The Weeknd',
          album: 'After Hours',
          albumArt: 'https://resources.tidal.com/images/456/640x640.jpg',
          duration: Duration(minutes: 3, seconds: 20),
          fileType: 'flac',
          filePath: 'tidal://9/999888',
          sourceType: 'tidal',
          remoteId: '999888',
          remoteServerId: 9,
        );
        const currentTrack = Song(
          id: 'tidal_9_999889',
          title: 'Save Your Tears',
          artist: 'The Weeknd',
          duration: Duration(minutes: 3, seconds: 35),
          fileType: 'flac',
          filePath: 'tidal://9/999889',
          sourceType: 'tidal',
          remoteId: '999889',
          remoteServerId: 9,
        );
        final repository = _FakeSongRepository(const []);
        final service = LastPlayedService(songRepository: repository);
        const position = Duration(minutes: 1, seconds: 45);

        await service.saveLastPlayed(
          currentTrack,
          position,
          playlist: const [firstTrack, currentTrack],
          currentIndex: 1,
          wasPlaying: true,
        );

        final result = await service.getLastPlayed();
        expect(result, isNotNull);
        expect(result!.song.id, currentTrack.id);
        expect(result.song.title, currentTrack.title);
        expect(result.song.filePath, currentTrack.filePath);
        expect(result.song.remoteId, currentTrack.remoteId);
        expect(result.song.remoteServerId, currentTrack.remoteServerId);
        expect(result.position, position);
        expect(result.wasPlaying, isTrue);
        expect(result.playlist!.map((song) => song.id), [
          firstTrack.id,
          currentTrack.id,
        ]);
        expect(result.playlistIndex, 1);
        expect(repository.reads, 0);
      },
    );

    test('falls back to legacy song and playlist IDs', () async {
      const localTrack = Song(
        id: 'local-track',
        title: 'Local Track',
        artist: 'Local Artist',
        duration: Duration(minutes: 2),
        fileType: 'flac',
      );
      const otherTrack = Song(
        id: 'other-track',
        title: 'Other Track',
        artist: 'Local Artist',
        duration: Duration(minutes: 3),
        fileType: 'flac',
      );
      final repository = _FakeSongRepository(const [localTrack, otherTrack]);
      final service = LastPlayedService(songRepository: repository);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_played_song_id', localTrack.id);
      await prefs.setInt('last_played_position_ms', 30000);
      await prefs.setString(
        'last_played_playlist_song_ids',
        jsonEncode([localTrack.id, otherTrack.id]),
      );
      await prefs.setInt('last_played_playlist_index', 0);
      await prefs.setBool('last_played_was_playing', false);

      final result = await service.getLastPlayed();

      expect(result!.song.id, localTrack.id);
      expect(result.position, const Duration(seconds: 30));
      expect(result.playlist!.map((song) => song.id), [
        localTrack.id,
        otherTrack.id,
      ]);
      expect(result.playlistIndex, 0);
      expect(repository.reads, 1);
    });

    test('clearLastPlayed removes JSON and legacy state', () async {
      final service = LastPlayedService();
      const song = Song(
        id: 'tidal_9_1',
        title: 'Test',
        artist: 'Test',
        duration: Duration(seconds: 180),
        fileType: 'flac',
      );

      await service.saveLastPlayed(song, const Duration(seconds: 30));
      expect(await service.getLastPlayed(), isNotNull);

      await service.clearLastPlayed();
      expect(await service.getLastPlayed(), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('last_played_song_data'), isFalse);
      expect(prefs.containsKey('last_played_playlist_data'), isFalse);
      expect(prefs.containsKey('last_played_song_id'), isFalse);
      expect(prefs.containsKey('last_played_playlist_song_ids'), isFalse);
    });
  });
}
