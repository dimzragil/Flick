import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/features/tidal/widgets/press_scale.dart';
import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host({
  required Widget child,
  VoidCallback? onTap,
  VoidCallback? onLongPress,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: PressScale(
          child: Material(
            color: Colors.blue,
            child: InkWell(
              onTap: onTap,
              onLongPress: onLongPress,
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
}

double _scaleTarget(WidgetTester tester) =>
    tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;

void main() {
  setUp(() {
    AppConstants.setAnimationsEnabled(true);
  });

  testWidgets('scales down while pressed and back on release', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      _host(
        onTap: () => tapped = true,
        child: const SizedBox(width: 120, height: 80, key: Key('card')),
      ),
    );

    expect(_scaleTarget(tester), 1.0);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('card'))),
    );
    await tester.pump();
    expect(_scaleTarget(tester), 0.97);

    await gesture.up();
    await tester.pump();
    expect(_scaleTarget(tester), 1.0);
    // The wrapped InkWell still receives its tap.
    expect(tapped, isTrue);

    await tester.pumpAndSettle();
  });

  testWidgets('releases the pressed look when the pointer becomes a drag', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(child: const SizedBox(width: 120, height: 80, key: Key('card'))),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('card'))),
    );
    await tester.pump();
    expect(_scaleTarget(tester), 0.97);

    await gesture.moveBy(const Offset(kTouchSlop + 12, 0));
    await tester.pump();
    expect(_scaleTarget(tester), 1.0);

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('releases the pressed look when a long-press takes over', (
    tester,
  ) async {
    var longPressed = false;
    await tester.pumpWidget(
      _host(
        onLongPress: () => longPressed = true,
        child: const SizedBox(width: 120, height: 80, key: Key('card')),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('card'))),
    );
    await tester.pump();
    expect(_scaleTarget(tester), 0.97);

    await tester.pump(const Duration(milliseconds: 700));
    expect(longPressed, isTrue);
    expect(_scaleTarget(tester), 1.0);

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('does not animate when animations are disabled', (tester) async {
    AppConstants.setAnimationsEnabled(false);
    addTearDown(() => AppConstants.setAnimationsEnabled(true));

    await tester.pumpWidget(
      _host(child: const SizedBox(width: 120, height: 80, key: Key('card'))),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('card'))),
    );
    await tester.pump();

    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).duration,
      Duration.zero,
    );
    expect(_scaleTarget(tester), 0.97);

    await gesture.up();
    await tester.pumpAndSettle();
  });
}
