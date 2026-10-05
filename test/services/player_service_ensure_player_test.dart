import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as just_audio;

import 'package:flick/services/player_service.dart';

class _FakeAudioPlayer implements just_audio.AudioPlayer {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('PlayerService singleFlightEnsurePlayer', () {
    test('returns existing player immediately if already created without calling doEnsure', () async {
      final existingPlayer = _FakeAudioPlayer();
      var doEnsureCallCount = 0;
      Future<just_audio.AudioPlayer>? inFlight;

      final result = await PlayerService.singleFlightEnsurePlayer(
        getExisting: () => existingPlayer,
        getInFlight: () => inFlight,
        setInFlight: (f) => inFlight = f,
        doEnsure: () async {
          doEnsureCallCount++;
          return _FakeAudioPlayer();
        },
      );

      expect(identical(result, existingPlayer), isTrue);
      expect(doEnsureCallCount, 0);
      expect(inFlight, isNull);
    });

    test('concurrent calls await same in-flight future and doEnsure is called once', () async {
      just_audio.AudioPlayer? currentPlayer;
      Future<just_audio.AudioPlayer>? inFlight;
      var doEnsureCallCount = 0;
      final completer = Completer<just_audio.AudioPlayer>();

      Future<just_audio.AudioPlayer> callEnsure() {
        return PlayerService.singleFlightEnsurePlayer(
          getExisting: () => currentPlayer,
          getInFlight: () => inFlight,
          setInFlight: (f) => inFlight = f,
          doEnsure: () {
            doEnsureCallCount++;
            return completer.future.then((p) {
              currentPlayer = p;
              return p;
            });
          },
        );
      }

      final future1 = callEnsure();
      final future2 = callEnsure();

      expect(doEnsureCallCount, 1);
      expect(inFlight, isNotNull);

      final fakePlayer = _FakeAudioPlayer();
      completer.complete(fakePlayer);

      final player1 = await future1;
      final player2 = await future2;

      expect(identical(player1, fakePlayer), isTrue);
      expect(identical(player2, fakePlayer), isTrue);
      expect(inFlight, isNull);

      // Third call returns cached instance immediately
      final player3 = await callEnsure();
      expect(identical(player3, fakePlayer), isTrue);
      expect(doEnsureCallCount, 1);
    });

    test('factory error resets in-flight future and allows subsequent retry', () async {
      just_audio.AudioPlayer? currentPlayer;
      Future<just_audio.AudioPlayer>? inFlight;
      var doEnsureCallCount = 0;
      final completer = Completer<just_audio.AudioPlayer>();

      Future<just_audio.AudioPlayer> callEnsure() {
        return PlayerService.singleFlightEnsurePlayer(
          getExisting: () => currentPlayer,
          getInFlight: () => inFlight,
          setInFlight: (f) => inFlight = f,
          doEnsure: () {
            doEnsureCallCount++;
            return completer.future.then((p) {
              currentPlayer = p;
              return p;
            });
          },
        );
      }

      final future1 = callEnsure();
      expect(doEnsureCallCount, 1);
      expect(inFlight, isNotNull);

      completer.completeError(Exception('Failed to create audio player'));

      await expectLater(future1, throwsA(isA<Exception>()));
      expect(inFlight, isNull);

      // Next call after failure must be able to retry
      final retryPlayer = _FakeAudioPlayer();
      final retryResult = await PlayerService.singleFlightEnsurePlayer(
        getExisting: () => currentPlayer,
        getInFlight: () => inFlight,
        setInFlight: (f) => inFlight = f,
        doEnsure: () async {
          doEnsureCallCount++;
          currentPlayer = retryPlayer;
          return retryPlayer;
        },
      );

      expect(identical(retryResult, retryPlayer), isTrue);
      expect(doEnsureCallCount, 2);
      expect(inFlight, isNull);
    });
  });
}
