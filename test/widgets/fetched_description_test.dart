import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flick/widgets/common/fetched_description.dart';

const _longText =
    'This album reframes the band as a widescreen pop machine, trading the '
    'garage-basement grit of its early records for a wall of synths, '
    'stadium-sized hooks, and a restlessness that never quite resolves. '
    'Every chorus arrives like a dare, and the quieter moments in between '
    'carry just as much weight.';

void main() {
  testWidgets('collapses the preview to three lines', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: FetchedDescription(text: _longText)),
      ),
    );

    final preview = tester.widget<Text>(find.text(_longText));
    expect(preview.maxLines, 3);
    expect(preview.overflow, TextOverflow.ellipsis);
  });

  testWidgets('Show more opens the full text in a sheet, not inline', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: FetchedDescription(
            text: _longText,
            sheetTitle: 'About this album',
          ),
        ),
      ),
    );

    await tester.tap(find.text('Show more'));
    await tester.pumpAndSettle();

    expect(find.text('About this album'), findsOneWidget);
    expect(find.text('From Apple Music'), findsNWidgets(2));
    final fullTexts = tester
        .widgetList<Text>(find.text(_longText))
        .where((text) => text.maxLines == null);
    expect(fullTexts, isNotEmpty);
  });

  testWidgets('renders nothing for empty text', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: FetchedDescription(text: '  '))),
    );

    expect(find.byType(Text), findsNothing);
  });
}
