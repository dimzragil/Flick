import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/player_service.dart';

/// Simulates the PlayerService handshake for a queue-item tap:
/// the generation is claimed synchronously at tap time, while the guarded
/// application runs later when the serialized playback queue reaches it.
class _QueueNavigationHarness {
  int generation = 0;
  final List<String> played = [];
  final List<QueueNavigationOutcome> outcomes = [];

  /// User tap: claim the generation immediately (what the public
  /// playFromQueueIndex / playFromUpNextIndex entry points now do).
  int tap() => ++generation;

  /// Later navigation (next/previous/play/another tap): supersedes everything
  /// that claimed the generation before it.
  int navigate() => ++generation;

  /// The queued action finally runs.
  Future<QueueNavigationOutcome> run(
    int tappedGeneration, {
    bool hasValidTarget = true,
    String track = 'tapped',
  }) async {
    final outcome = await runQueueNavigationForGeneration(
      generation: tappedGeneration,
      currentGeneration: () => generation,
      hasValidTarget: () => hasValidTarget,
      apply: () async {
        played.add(track);
      },
    );
    outcomes.add(outcome);
    return outcome;
  }
}

void main() {
  group('queue-item tap playback-generation guard', () {
    test('a tap that loses to a later next() is dropped', () async {
      final harness = _QueueNavigationHarness();

      final tapGeneration = harness.tap();
      // next() is pressed while the tap is still waiting in the queue.
      harness.navigate();

      final outcome = await harness.run(tapGeneration);

      expect(outcome, QueueNavigationOutcome.superseded);
      expect(harness.played, isEmpty);
    });

    test('a tap that is still current plays normally', () async {
      final harness = _QueueNavigationHarness();
      final tapGeneration = harness.tap();

      final outcome = await harness.run(tapGeneration);

      expect(outcome, QueueNavigationOutcome.started);
      expect(harness.played, ['tapped']);
    });

    test('rapid taps: only the last tap wins', () async {
      final harness = _QueueNavigationHarness();

      final firstTap = harness.tap();
      final secondTap = harness.tap();

      final firstOutcome = await harness.run(firstTap, track: 'first');
      final secondOutcome = await harness.run(secondTap, track: 'second');

      expect(firstOutcome, QueueNavigationOutcome.superseded);
      expect(secondOutcome, QueueNavigationOutcome.started);
      expect(harness.played, ['second']);
    });

    test('tap followed by next(): only next advances', () async {
      final harness = _QueueNavigationHarness();

      final tapGeneration = harness.tap();
      final nextGeneration = harness.navigate();

      // The tap's queued action runs after next() claimed the generation.
      await harness.run(tapGeneration);
      // next() itself is guarded by the same generation counter.
      await harness.run(nextGeneration, track: 'next');

      expect(harness.outcomes, [
        QueueNavigationOutcome.superseded,
        QueueNavigationOutcome.started,
      ]);
      expect(harness.played, ['next']);
    });

    test('a stale index is dropped without touching playback', () async {
      final harness = _QueueNavigationHarness();
      final tapGeneration = harness.tap();

      final outcome = await harness.run(tapGeneration, hasValidTarget: false);

      expect(outcome, QueueNavigationOutcome.invalidIndex);
      expect(harness.played, isEmpty);
    });
  });
}
