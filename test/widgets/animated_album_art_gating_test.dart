import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flick/widgets/common/animated_album_art.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The covered-route test makes the home route offstage — default finders
  // skip offstage subtrees, so read them here.
  final kenBurnsTransformFinder = find.descendant(
    of: find.byType(AnimatedAlbumArt, skipOffstage: false),
    matching: find.byType(Transform, skipOffstage: false),
    skipOffstage: false,
  );

  double kenBurnsScale(WidgetTester tester) {
    final transforms = tester
        .widgetList<Transform>(kenBurnsTransformFinder)
        .toList();
    expect(transforms, hasLength(1), reason: 'exactly one Ken Burns transform');
    return transforms.single.transform.getMaxScaleOnAxis();
  }

  Widget subject(ValueNotifier<bool> playing) => MaterialApp(
    home: Scaffold(
      body: AnimatedAlbumArt(
        dominantColor: const Color(0xFF336699),
        playingOverride: playing,
      ),
    ),
  );

  testWidgets('RepaintBoundary wraps the animated Ken Burns content', (
    tester,
  ) async {
    final playing = ValueNotifier<bool>(true);
    addTearDown(playing.dispose);

    await tester.pumpWidget(subject(playing));
    await tester.pump();

    expect(
      find.descendant(
        of: find.byType(AnimatedAlbumArt),
        matching: find.byType(RepaintBoundary),
      ),
      findsWidgets,
    );
  });

  testWidgets('animates while playing with the route current', (tester) async {
    final playing = ValueNotifier<bool>(true);
    addTearDown(playing.dispose);

    await tester.pumpWidget(subject(playing));
    await tester.pump(); // applies the gate post-frame

    final s0 = kenBurnsScale(tester);
    await tester.pump(const Duration(milliseconds: 400));
    final s1 = kenBurnsScale(tester);
    expect(s1, isNot(s0), reason: 'Ken Burns must tick while playing');

    await tester.pump(const Duration(milliseconds: 400));
    final s2 = kenBurnsScale(tester);
    expect(s2, isNot(s1), reason: 'Ken Burns must keep ticking');
  });

  testWidgets('freezes (static frame) when audio is not playing', (
    tester,
  ) async {
    final playing = ValueNotifier<bool>(true);
    addTearDown(playing.dispose);

    await tester.pumpWidget(subject(playing));
    await tester.pump(const Duration(milliseconds: 400));

    playing.value = false;
    await tester.pump(); // gate re-applied on the next frame

    final frozen = kenBurnsScale(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(kenBurnsScale(tester), frozen, reason: 'paused audio must freeze');
    await tester.pump(const Duration(milliseconds: 400));
    expect(kenBurnsScale(tester), frozen, reason: 'stays frozen while paused');

    // Resume callers repeat from the frozen value instead of restarting.
    playing.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      kenBurnsScale(tester),
      isNot(frozen),
      reason: 'resume must animate again from the frozen value',
    );
  });

  testWidgets('pauses when another route covers this one, resumes on pop', (
    tester,
  ) async {
    final playing = ValueNotifier<bool>(true);
    addTearDown(playing.dispose);

    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: Scaffold(
          body: AnimatedAlbumArt(
            dominantColor: const Color(0xFF336699),
            playingOverride: playing,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('top')),
      ),
    );
    // Mirror MotionArtView's gating test: listeners re-evaluate via the
    // ModalScopeStatus dependency after each push/pop.
    await tester.pump(); // dependency update + post-frame gate sync
    await tester.pump(const Duration(milliseconds: 400)); // finish transition

    final covered = kenBurnsScale(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(kenBurnsScale(tester), covered, reason: 'covered route must pause');
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      kenBurnsScale(tester),
      covered,
      reason: 'stays paused under the covering route',
    );

    navigatorKey.currentState!.pop();
    await tester.pump(); // dependency update + post-frame gate sync
    await tester.pump(const Duration(milliseconds: 500)); // pop transition
    final resumed = kenBurnsScale(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      kenBurnsScale(tester),
      isNot(resumed),
      reason: 'uncovered route resumes the Ken Burns loop',
    );
  });

  testWidgets('reduced motion never animates', (tester) async {
    final playing = ValueNotifier<bool>(true);
    addTearDown(playing.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: AnimatedAlbumArt(
              dominantColor: const Color(0xFF336699),
              playingOverride: playing,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final frozen = kenBurnsScale(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      kenBurnsScale(tester),
      frozen,
      reason: 'reduced motion must never animate the Ken Burns',
    );
  });
}
