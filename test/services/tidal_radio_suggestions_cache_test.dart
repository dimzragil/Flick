import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/tidal_radio_suggestions_cache.dart';

void main() {
  group('TidalRadioSuggestionsCache', () {
    test(
      'shares one fetch for the active seed and replaces it on seed change',
      () async {
        final cache = TidalRadioSuggestionsCache();
        var activeSeed = 'tidal:one';
        var fetchCount = 0;
        final first = _song('first');

        Future<List<Song>> load(String seed) => cache.get(
          seedKey: seed,
          isSeedCurrent: () => activeSeed == seed,
          fetch: () async {
            fetchCount++;
            return [first];
          },
        );

        final results = await Future.wait([
          load('tidal:one'),
          load('tidal:one'),
        ]);
        expect(fetchCount, 1);
        expect(results, [
          [first],
          [first],
        ]);

        activeSeed = 'tidal:two';
        final second = _song('second');
        final replaced = await cache.get(
          seedKey: activeSeed,
          isSeedCurrent: () => activeSeed == 'tidal:two',
          fetch: () async {
            fetchCount++;
            return [second];
          },
        );
        expect(fetchCount, 2);
        expect(replaced, [second]);
      },
    );

    test('drops a stale in-flight result after the seed changes', () async {
      final cache = TidalRadioSuggestionsCache();
      var activeSeed = 'tidal:one';
      final response = Completer<List<Song>>();
      final stale = cache.get(
        seedKey: 'tidal:one',
        isSeedCurrent: () => activeSeed == 'tidal:one',
        fetch: () => response.future,
      );

      activeSeed = 'tidal:two';
      await cache.get(
        seedKey: activeSeed,
        isSeedCurrent: () => activeSeed == 'tidal:two',
        fetch: () async => [_song('current')],
      );
      response.complete([_song('stale')]);

      expect(await stale, isEmpty);
    });
  });

  test('filters played and queued tracks and caps results at 15', () {
    final tracks = List.generate(18, (index) => _song('$index'));

    final visible = filterSuggestedRadioTracks(tracks, {'0', '1', '2'});

    expect(
      visible.map((song) => song.id),
      List.generate(15, (index) => '${index + 3}'),
    );
  });
}

Song _song(String id) => Song(
  id: id,
  title: id,
  artist: 'Artist',
  duration: Duration.zero,
  fileType: 'FLAC',
  remoteId: id,
);
