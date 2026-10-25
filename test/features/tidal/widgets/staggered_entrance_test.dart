import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/features/tidal/widgets/staggered_entrance.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

double _fadeValue(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find.descendant(
        of: find.byType(StaggeredEntrance),
        matching: find.byType(FadeTransition),
      ),
    )
    .opacity
    .value;

Offset _slideTarget(WidgetTester tester) =>
    tester.widget<AnimatedSlide>(find.byType(AnimatedSlide)).offset;

void main() {
  setUp(() {
    AppConstants.setAnimationsEnabled(true);
  });

  testWidgets('fades and slides in after index * delay when window is open', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const StaggeredEntranceWindow(
          child: StaggeredEntrance(index: 2, child: Text('row')),
        ),
      ),
    );

    // Starts hidden below its final position.
    expect(_fadeValue(tester), 0.0);
    expect(_slideTarget(tester), const Offset(0, 0.15));

    // Still hidden before the staggered delay elapses (2 * 30ms).
    await tester.pump(const Duration(milliseconds: 40));
    expect(_fadeValue(tester), 0.0);

    // Delay elapsed: entrance starts and completes over 200ms.
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pump(const Duration(milliseconds: 100));
    final mid = _fadeValue(tester);
    expect(mid, greaterThan(0.0));
    expect(mid, lessThan(1.0));

    await tester.pump(const Duration(milliseconds: 200));
    expect(_fadeValue(tester), 1.0);
    expect(_slideTarget(tester), Offset.zero);

    await tester.pumpAndSettle();
  });

  testWidgets(
    'renders instantly for children mounted after the window closed',
    (tester) async {
      var showRow = false;
      late StateSetter setState;

      await tester.pumpWidget(
        _host(
          StaggeredEntranceWindow(
            child: StatefulBuilder(
              builder: (context, setter) {
                setState = setter;
                return showRow
                    ? const StaggeredEntrance(index: 3, child: Text('late row'))
                    : const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      // Let the entrance window close.
      await tester.pump(const Duration(milliseconds: 700));

      setState(() => showRow = true);
      await tester.pump();

      // No entrance: fully visible (and in place) right away.
      expect(_fadeValue(tester), 1.0);
      expect(_slideTarget(tester), Offset.zero);
    },
  );

  testWidgets('stays closed when initiallyOpen is false', (tester) async {
    await tester.pumpWidget(
      _host(
        const StaggeredEntranceWindow(
          initiallyOpen: false,
          child: StaggeredEntrance(index: 2, child: Text('row')),
        ),
      ),
    );
    await tester.pump();

    // No entrance: fully visible (and in place) right away, even though the
    // window never opened — this is what a remounted window must do so a
    // lazily inflated section does not replay its entrance on scroll back.
    expect(_fadeValue(tester), 1.0);
    expect(_slideTarget(tester), Offset.zero);
  });

  testWidgets('calls onClosed when the window closes', (tester) async {
    var closed = false;
    await tester.pumpWidget(
      _host(
        StaggeredEntranceWindow(
          duration: const Duration(milliseconds: 100),
          onClosed: () => closed = true,
          child: const StaggeredEntrance(index: 0, child: Text('row')),
        ),
      ),
    );

    expect(closed, isFalse);
    await tester.pump(const Duration(milliseconds: 150));
    expect(closed, isTrue);
  });

  testWidgets('renders instantly when animations are disabled', (tester) async {
    AppConstants.setAnimationsEnabled(false);
    addTearDown(() => AppConstants.setAnimationsEnabled(true));

    await tester.pumpWidget(
      _host(
        const StaggeredEntranceWindow(
          child: StaggeredEntrance(index: 5, child: Text('row')),
        ),
      ),
    );

    await tester.pump();
    expect(_fadeValue(tester), 1.0);
    expect(_slideTarget(tester), Offset.zero);
  });
}
