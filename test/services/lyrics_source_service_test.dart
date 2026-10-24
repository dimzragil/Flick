import 'package:flick/models/song.dart';
import 'package:flick/models/sources/tidal_lyrics.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flick/services/lyrics_source_service.dart';
import 'package:flick/services/online_lyrics_service.dart';
import 'package:flick/services/sources/network_source_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeLyricsService extends LyricsService {
  _FakeLyricsService({this.localResult});

  LyricsData? localResult;
  int localLoads = 0;

  @override
  Future<LyricsData?> loadLyricsForSong(
    Song song, {
    bool forceRefresh = false,
  }) async {
    localLoads++;
    return localResult;
  }
}

class _FakeOnlineLyricsService extends OnlineLyricsService {
  _FakeOnlineLyricsService({this.exact});

  OnlineLyricsResult? exact;
  int exactCalls = 0;

  @override
  Future<OnlineLyricsResult?> fetchExact({
    required String artist,
    required String title,
    String? album,
    Duration? duration,
  }) async {
    exactCalls++;
    return exact;
  }
}

Song _tidalSong({String remoteId = '39249713'}) => Song(
  id: 'tidal_1_$remoteId',
  title: 'Get Lucky',
  artist: 'Daft Punk',
  album: 'Random Access Memories',
  duration: const Duration(minutes: 6),
  fileType: 'flac',
  filePath: 'tidal://1/$remoteId',
  sourceType: NetworkProtocol.tidal,
  remoteId: remoteId,
  remoteServerId: 1,
);

Song _localSong() => const Song(
  id: 'local_1',
  title: 'Local Track',
  artist: 'Someone',
  duration: Duration(minutes: 3),
  fileType: 'flac',
  filePath: '/music/local.flac',
);

OnlineLyricsResult _lrclibSynced() => const OnlineLyricsResult(
  id: 1,
  trackName: 'Get Lucky',
  artistName: 'Daft Punk',
  instrumental: false,
  syncedLyrics: '[00:10.00] lrclib line one\n[00:20.00] lrclib line two',
);

void main() {
  group('LyricsSourceService', () {
    test('TIDAL subtitles win and lrclib is never consulted', () async {
      var tidalCalls = 0;
      final online = _FakeOnlineLyricsService(exact: _lrclibSynced());
      final service = LyricsSourceService(
        localLyrics: _FakeLyricsService(),
        onlineLyrics: online,
        tidalLyricsLoader: (song) async {
          tidalCalls++;
          return const TidalLyrics(
            trackId: '39249713',
            subtitles: '[00:12.34] Hello\n[00:15.00] World',
          );
        },
      );

      final lyrics = await service.loadForSong(_tidalSong());

      expect(lyrics, isNotNull);
      expect(lyrics!.isSynchronized, isTrue);
      expect(lyrics.source, 'TIDAL');
      expect(lyrics.lines.length, 2);
      expect(lyrics.lines.first.timestamp, const Duration(milliseconds: 12340));
      expect(lyrics.lines.first.text, 'Hello');
      // Line-level LRC: no per-word timings are invented.
      expect(lyrics.lines.first.words, isNull);
      expect(tidalCalls, 1);
      expect(online.exactCalls, 0);
    });

    test('TIDAL 404 (null payload) falls back to lrclib', () async {
      final online = _FakeOnlineLyricsService(exact: _lrclibSynced());
      final service = LyricsSourceService(
        localLyrics: _FakeLyricsService(),
        onlineLyrics: online,
        tidalLyricsLoader: (song) async => null,
      );

      final lyrics = await service.loadForSong(_tidalSong());

      expect(lyrics, isNotNull);
      expect(lyrics!.source, 'lrclib');
      expect(lyrics.isSynchronized, isTrue);
      expect(lyrics.lines.first.text, 'lrclib line one');
      expect(online.exactCalls, 1);
    });

    test(
      'a TIDAL failure falls through to lrclib instead of surfacing',
      () async {
        final online = _FakeOnlineLyricsService(exact: _lrclibSynced());
        final service = LyricsSourceService(
          localLyrics: _FakeLyricsService(),
          onlineLyrics: online,
          tidalLyricsLoader: (song) async => throw Exception('boom'),
        );

        final lyrics = await service.loadForSong(_tidalSong());

        expect(lyrics?.source, 'lrclib');
        expect(online.exactCalls, 1);
      },
    );

    test('both sources empty → null (existing empty state)', () async {
      final online = _FakeOnlineLyricsService();
      final service = LyricsSourceService(
        localLyrics: _FakeLyricsService(),
        onlineLyrics: online,
        tidalLyricsLoader: (song) async => null,
      );

      expect(await service.loadForSong(_tidalSong()), isNull);
      expect(online.exactCalls, 1);
    });

    test('TIDAL plain lyrics only → unsynchronized lines', () async {
      final service = LyricsSourceService(
        localLyrics: _FakeLyricsService(),
        onlineLyrics: _FakeOnlineLyricsService(),
        tidalLyricsLoader: (song) async => const TidalLyrics(
          trackId: '39249713',
          lyrics: 'plain one\nplain two',
        ),
      );

      final lyrics = await service.loadForSong(_tidalSong());

      expect(lyrics, isNotNull);
      expect(lyrics!.isSynchronized, isFalse);
      expect(lyrics.lines.map((l) => l.text), ['plain one', 'plain two']);
      expect(lyrics.lines.first.words, isNull);
    });

    test('isRightToLeft reaches the parsed lyrics', () async {
      final service = LyricsSourceService(
        localLyrics: _FakeLyricsService(),
        onlineLyrics: _FakeOnlineLyricsService(),
        tidalLyricsLoader: (song) async => const TidalLyrics(
          trackId: '39249713',
          subtitles: '[00:01.00] مرحبا',
          isRightToLeft: true,
        ),
      );

      final lyrics = await service.loadForSong(_tidalSong());

      expect(lyrics!.isRightToLeft, isTrue);
    });

    test('non-TIDAL songs keep the local-only behaviour', () async {
      var tidalCalls = 0;
      final online = _FakeOnlineLyricsService(exact: _lrclibSynced());
      final service = LyricsSourceService(
        localLyrics: _FakeLyricsService(),
        onlineLyrics: online,
        tidalLyricsLoader: (song) async {
          tidalCalls++;
          return null;
        },
      );

      expect(await service.loadForSong(_localSong()), isNull);
      expect(
        tidalCalls,
        0,
        reason: 'TIDAL must not be asked about local files',
      );
      expect(
        online.exactCalls,
        0,
        reason: 'non-TIDAL songs keep the lrclib sheet, not an auto lookup',
      );
    });

    test('locally stored lyrics win over TIDAL', () async {
      var tidalCalls = 0;
      final local = _FakeLyricsService(
        localResult: const LyricsData(
          lines: [LyricsLine(timestamp: Duration.zero, text: 'mine')],
          isSynchronized: false,
          source: '/music/custom.lrc',
          rawContent: 'mine',
        ),
      );
      final service = LyricsSourceService(
        localLyrics: local,
        onlineLyrics: _FakeOnlineLyricsService(),
        tidalLyricsLoader: (song) async {
          tidalCalls++;
          return const TidalLyrics(trackId: 'x', subtitles: '[00:01.00] other');
        },
      );

      final lyrics = await service.loadForSong(_tidalSong());

      expect(lyrics!.source, '/music/custom.lrc');
      expect(lyrics.lines.single.text, 'mine');
      expect(tidalCalls, 0);
    });

    test('session cache: reopening does not refetch TIDAL', () async {
      var tidalCalls = 0;
      final service = LyricsSourceService(
        localLyrics: _FakeLyricsService(),
        onlineLyrics: _FakeOnlineLyricsService(),
        tidalLyricsLoader: (song) async {
          tidalCalls++;
          return const TidalLyrics(
            trackId: '39249713',
            subtitles: '[00:01.00] cached',
          );
        },
      );

      final song = _tidalSong();
      await service.loadForSong(song);
      await service.loadForSong(song);

      expect(tidalCalls, 1);
      expect(service.sessionCacheSize, 1);
    });

    test(
      'forceRefreshLocal re-reads local lyrics but keeps the cache',
      () async {
        var tidalCalls = 0;
        final local = _FakeLyricsService();
        final service = LyricsSourceService(
          localLyrics: local,
          onlineLyrics: _FakeOnlineLyricsService(),
          tidalLyricsLoader: (song) async {
            tidalCalls++;
            return const TidalLyrics(
              trackId: '39249713',
              subtitles: '[00:01.00] cached',
            );
          },
        );

        final song = _tidalSong();
        await service.loadForSong(song);
        await service.loadForSong(song, forceRefreshLocal: true);

        expect(local.localLoads, 2);
        expect(tidalCalls, 1);
      },
    );

    test('a null TIDAL result is cached too (no repeat requests)', () async {
      var tidalCalls = 0;
      final service = LyricsSourceService(
        localLyrics: _FakeLyricsService(),
        onlineLyrics: _FakeOnlineLyricsService(),
        tidalLyricsLoader: (song) async {
          tidalCalls++;
          return null;
        },
      );

      final song = _tidalSong();
      expect(await service.loadForSong(song), isNull);
      expect(await service.loadForSong(song), isNull);
      expect(tidalCalls, 1);
    });
  });
}
