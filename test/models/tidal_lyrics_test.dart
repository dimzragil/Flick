import 'package:flick/models/sources/tidal_lyrics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TidalLyrics.fromJson', () {
    const requestTrackId = '39249713';

    test('parses the documented top-level payload', () {
      final lyrics = TidalLyrics.fromJson(requestTrackId, {
        'trackId': 39249713,
        'lyricsProvider': 'MUSIXMATCH',
        'providerCommontrackId': '190482820',
        'providerLyricsId': '37850929',
        'lyrics': 'Doh\nDoh-doh-doh',
        'subtitles': '[00:00.04] Doh\n[00:01.98] Doh-doh-doh',
        'isRightToLeft': false,
      });

      expect(lyrics.trackId, '39249713');
      expect(lyrics.lyricsProvider, 'MUSIXMATCH');
      expect(lyrics.providerCommontrackId, '190482820');
      expect(lyrics.providerLyricsId, '37850929');
      expect(lyrics.isRightToLeft, isFalse);
      expect(lyrics.lyrics, 'Doh\nDoh-doh-doh');
      expect(lyrics.subtitles, '[00:00.04] Doh\n[00:01.98] Doh-doh-doh');
      expect(lyrics.hasSubtitles, isTrue);
      expect(lyrics.hasPlainLyrics, isTrue);
      expect(lyrics.isEmpty, isFalse);
    });

    test('missing subtitles leaves only plain lyrics', () {
      final lyrics = TidalLyrics.fromJson(requestTrackId, {
        'lyrics': 'Only plain text',
        'isRightToLeft': false,
      });

      expect(lyrics.subtitles, isNull);
      expect(lyrics.hasSubtitles, isFalse);
      expect(lyrics.hasPlainLyrics, isTrue);
      expect(lyrics.isEmpty, isFalse);
    });

    test('missing plain lyrics leaves only subtitles', () {
      final lyrics = TidalLyrics.fromJson(requestTrackId, {
        'subtitles': '[00:01.00] Line',
      });

      expect(lyrics.lyrics, isNull);
      expect(lyrics.hasPlainLyrics, isFalse);
      expect(lyrics.hasSubtitles, isTrue);
      expect(lyrics.isEmpty, isFalse);
    });

    test('honours isRightToLeft', () {
      final lyrics = TidalLyrics.fromJson(requestTrackId, {
        'subtitles': '[00:01.00] مرحبا',
        'isRightToLeft': true,
      });

      expect(lyrics.isRightToLeft, isTrue);
    });

    test('falls back to the requested id when the payload omits it', () {
      final lyrics = TidalLyrics.fromJson(requestTrackId, {
        'subtitles': '[00:01.00] Line',
      });

      expect(lyrics.trackId, requestTrackId);
    });

    test('accepts a proxy envelope that nests the fields under lyrics', () {
      final lyrics = TidalLyrics.fromJson(requestTrackId, {
        'version': '2.6',
        'lyrics': {
          'trackId': 39249713,
          'lyricsProvider': 'TIDAL',
          'subtitles': '[00:02.00] Nested',
          'isRightToLeft': false,
        },
      });

      expect(lyrics.lyricsProvider, 'TIDAL');
      expect(lyrics.subtitles, '[00:02.00] Nested');
    });

    test('string ids and int ids both parse', () {
      final lyrics = TidalLyrics.fromJson(requestTrackId, {
        'trackId': '39249713',
        'providerCommontrackId': 190482820,
        'subtitles': '[00:01.00] Line',
      });

      expect(lyrics.trackId, '39249713');
      expect(lyrics.providerCommontrackId, '190482820');
    });

    test('an empty payload is empty, not a silent blank track', () {
      final lyrics = TidalLyrics.fromJson(requestTrackId, const {});

      expect(lyrics.subtitles, isNull);
      expect(lyrics.lyrics, isNull);
      expect(lyrics.isEmpty, isTrue);
    });

    test('whitespace-only text counts as absent', () {
      final lyrics = TidalLyrics.fromJson(requestTrackId, {
        'lyrics': '   \n ',
        'subtitles': '\n',
      });

      expect(lyrics.lyrics, isNull);
      expect(lyrics.subtitles, isNull);
      expect(lyrics.isEmpty, isTrue);
    });
  });
}
