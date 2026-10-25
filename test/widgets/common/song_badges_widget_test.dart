import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flick/widgets/common/song_badges.dart';

void main() {
  group('SongTitleRow widget tests', () {
    testWidgets('renders title text only when badges are null or false', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SongTitleRow(
              title: 'Clean Stereo Song',
              isExplicit: null,
              isAtmos: false,
            ),
          ),
        ),
      );

      expect(find.text('Clean Stereo Song'), findsOneWidget);
      expect(find.byType(ExplicitBadge), findsNothing);
      expect(find.byType(DolbyAtmosIcon), findsNothing);
    });

    testWidgets(
      'renders Atmos icon first and Explicit badge second when both apply',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: SongTitleRow(
                title: 'Atmos & Explicit Track',
                isExplicit: true,
                isAtmos: true,
              ),
            ),
          ),
        );

        expect(find.text('Atmos & Explicit Track'), findsOneWidget);
        expect(find.byType(DolbyAtmosIcon), findsOneWidget);
        expect(find.byType(ExplicitBadge), findsOneWidget);

        // Verify layout order: title on left, Atmos in middle, Explicit on right
        final titleTopLeft = tester.getTopLeft(
          find.text('Atmos & Explicit Track'),
        );
        final atmosTopLeft = tester.getTopLeft(find.byType(DolbyAtmosIcon));
        final explicitTopLeft = tester.getTopLeft(find.byType(ExplicitBadge));

        expect(atmosTopLeft.dx, greaterThan(titleTopLeft.dx));
        expect(explicitTopLeft.dx, greaterThan(atmosTopLeft.dx));
      },
    );

    testWidgets(
      'renders Atmos icon only when isAtmos is true and isExplicit is false',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: SongTitleRow(
                title: 'Atmos Only',
                isExplicit: false,
                isAtmos: true,
              ),
            ),
          ),
        );

        expect(find.byType(DolbyAtmosIcon), findsOneWidget);
        expect(find.byType(ExplicitBadge), findsNothing);
      },
    );

    testWidgets(
      'renders Explicit badge only when isExplicit is true and isAtmos is false',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: SongTitleRow(
                title: 'Explicit Only',
                isExplicit: true,
                isAtmos: false,
              ),
            ),
          ),
        );

        expect(find.byType(ExplicitBadge), findsOneWidget);
        expect(find.byType(DolbyAtmosIcon), findsNothing);
      },
    );

    testWidgets('does not push badges off screen on very long title', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 250,
              child: SongTitleRow(
                title:
                    'This is an extremely long song title that will definitely overflow unless it is constrained',
                isExplicit: true,
                isAtmos: true,
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(DolbyAtmosIcon), findsOneWidget);
      expect(find.byType(ExplicitBadge), findsOneWidget);

      // Verify badges remain within the 250px container boundary
      final atmosTopRight = tester.getTopRight(find.byType(DolbyAtmosIcon));
      final explicitTopRight = tester.getTopRight(find.byType(ExplicitBadge));

      expect(atmosTopRight.dx, lessThanOrEqualTo(250.0));
      expect(explicitTopRight.dx, lessThanOrEqualTo(250.0));
    });
  });
}
