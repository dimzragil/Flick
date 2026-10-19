import 'dart:async';

import 'package:flick/models/song.dart';
import 'package:flick/services/player_service.dart';
import 'package:flutter_test/flutter_test.dart';

Song _song(String id) => Song(
  id: id,
  title: 'Track $id',
  artist: 'Artist',
  duration: const Duration(minutes: 3),
  fileType: 'FLAC',
);

void main() {
  group('queue-end radio autoplay generation guard', () {
    test(
      'drops the orphaned radio result when the user navigates during the fetch',
      () async {
        var generation = 7;
        final fetch = Completer<List<Song>>();
        var playlist = <String>['current'];
        var playbackStarted = false;

        final result = runRadioAutoplayForQueueEnd(
          generation: generation,
          currentGeneration: () => generation,
          fetchRadio: () => fetch.future,
          playRadio: (radioSongs) async {
            playbackStarted = true;
            playlist = radioSongs.map((song) => song.id).toList();
          },
        );

        // User presses next() while the radio request is still in flight.
        generation++;

        fetch.complete([_song('radio-1'), _song('radio-2')]);

        expect(await result, QueueEndRadioOutcome.superseded);
        expect(playbackStarted, isFalse);
        expect(playlist, ['current']);
      },
    );

    test('starts radio autoplay when the generation did not change', () async {
      var playlist = <String>['current'];

      final result = await runRadioAutoplayForQueueEnd(
        generation: 3,
        currentGeneration: () => 3,
        fetchRadio: () async => [_song('radio-1'), _song('radio-2')],
        playRadio: (radioSongs) async {
          playlist = radioSongs.map((song) => song.id).toList();
        },
      );

      expect(result, QueueEndRadioOutcome.started);
      expect(playlist, ['radio-1', 'radio-2']);
    });

    test('does not fetch radio when the generation is already stale', () async {
      var fetched = false;

      final result = await runRadioAutoplayForQueueEnd(
        generation: 1,
        currentGeneration: () => 2,
        fetchRadio: () async {
          fetched = true;
          return [_song('radio-1')];
        },
        playRadio: (_) async {},
      );

      expect(result, QueueEndRadioOutcome.superseded);
      expect(fetched, isFalse);
    });

    test('reports unavailable when the fetch returns no tracks', () async {
      var playbackStarted = false;

      final result = await runRadioAutoplayForQueueEnd(
        generation: 4,
        currentGeneration: () => 4,
        fetchRadio: () async => [],
        playRadio: (_) async {
          playbackStarted = true;
        },
      );

      expect(result, QueueEndRadioOutcome.unavailable);
      expect(playbackStarted, isFalse);
    });
  });
}
