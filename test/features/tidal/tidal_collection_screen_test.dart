import 'package:flick/features/tidal/screens/tidal_collection_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Collection placeholder renders its title and message', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: TidalCollectionScreen()));

    expect(find.text('Collection'), findsOneWidget);
    expect(find.text('Your TIDAL collection will live here.'), findsOneWidget);
  });
}
