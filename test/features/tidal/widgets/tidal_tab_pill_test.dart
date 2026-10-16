import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/features/tidal/widgets/tidal_tab_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host({required bool selected, VoidCallback? onTap}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: TidalTabPill(
          label: 'Vibes',
          selected: selected,
          onTap: onTap ?? () {},
        ),
      ),
    ),
  );
}

Duration _containerDuration(WidgetTester tester) => tester
    .widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(TidalTabPill),
        matching: find.byType(AnimatedContainer),
      ),
    )
    .duration;

/// The decoration currently being painted — [AnimatedContainer]'s own field
/// stays at the target value while its inner [Container] gets the
/// interpolated one each tick.
BoxDecoration _paintedDecoration(WidgetTester tester) {
  final container = tester.widget<Container>(
    find
        .descendant(
          of: find.descendant(
            of: find.byType(TidalTabPill),
            matching: find.byType(AnimatedContainer),
          ),
          matching: find.byType(Container),
        )
        .first,
  );
  return container.decoration! as BoxDecoration;
}

/// The style actually rendered for the label (after the animated
/// [DefaultTextStyle] merge), i.e. what the user sees mid-animation.
TextStyle _resolvedStyle(WidgetTester tester) =>
    tester.renderObject<RenderParagraph>(find.text('Vibes')).text.style!;

void main() {
  setUp(() {
    AppConstants.setAnimationsEnabled(true);
  });

  testWidgets('renders the label and forwards taps', (tester) async {
    var tapped = false;
    await tester.pumpWidget(_host(selected: false, onTap: () => tapped = true));

    expect(find.text('Vibes'), findsOneWidget);
    // Ripple behavior is preserved via the InkWell.
    expect(find.byType(InkWell), findsOneWidget);

    await tester.tap(find.text('Vibes'));
    expect(tapped, isTrue);
  });

  testWidgets('uses the 200ms easeInOut indicator animation', (tester) async {
    await tester.pumpWidget(_host(selected: false));

    final container = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(TidalTabPill),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect(container.duration, const Duration(milliseconds: 200));
    expect(container.curve, Curves.easeInOut);

    final style = _resolvedStyle(tester);
    expect(style.fontWeight, FontWeight.w500);
    expect(style.color, AppColors.textPrimary);
  });

  testWidgets('animates fill and border between selection states', (
    tester,
  ) async {
    await tester.pumpWidget(_host(selected: false));
    expect(_paintedDecoration(tester).color, AppColors.glassBackgroundStrong);

    await tester.pumpWidget(_host(selected: true));
    await tester.pump(const Duration(milliseconds: 100));

    // Halfway through the animation the fill is between the two states.
    final midColor = _paintedDecoration(tester).color;
    expect(midColor, isNot(AppColors.glassBackgroundStrong));
    expect(midColor, isNot(const Color(0x66FFFFFF)));

    await tester.pumpAndSettle();
    final settled = _paintedDecoration(tester);
    expect(settled.color, const Color(0x66FFFFFF));
    expect(settled.border!.top.color, const Color(0xD9FFFFFF));

    final style = _resolvedStyle(tester);
    expect(style.fontWeight, FontWeight.bold);
    expect(style.color, const Color(0xD9FFFFFF));
  });

  testWidgets('is instant when app-wide animations are disabled', (
    tester,
  ) async {
    AppConstants.setAnimationsEnabled(false);
    addTearDown(() => AppConstants.setAnimationsEnabled(true));

    await tester.pumpWidget(_host(selected: true));
    expect(_containerDuration(tester), Duration.zero);
  });
}
