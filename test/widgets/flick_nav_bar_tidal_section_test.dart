import 'package:flick/features/tidal/providers/tidal_section_provider.dart';
import 'package:flick/models/nav_bar_config.dart';
import 'package:flick/widgets/navigation/flick_nav_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('TIDAL section items appear in order and report taps', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    TidalSection? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: FlickNavBar(
            currentIndex: NavBarButton.tidal.pageIndex,
            config: NavBarConfig.defaultConfig,
            tidalSectionActive: true,
            onTap: (_) {},
            onTidalSectionTap: (section) => selected = section,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));

    final labels = [
      find.text('Menu'),
      find.text('Songs'),
      find.text('Tidal'),
      find.text('TIDAL\nSearch'),
      find.text('Collection'),
      find.text('Settings'),
    ];
    final centers = labels
        .map((finder) => tester.getCenter(finder).dx)
        .toList();
    expect(centers, orderedEquals([...centers]..sort()));

    await tester.tap(find.text('TIDAL\nSearch'));
    expect(selected, TidalSection.search);
    await tester.tap(find.text('Collection'));
    expect(selected, TidalSection.collection);
  });

  testWidgets('TIDAL section items collapse when another tab is active', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: FlickNavBar(
            currentIndex: NavBarButton.songs.pageIndex,
            config: NavBarConfig.defaultConfig,
            tidalSectionActive: false,
            onTap: (_) {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));

    expect(
      tester
          .getSize(find.byKey(const ValueKey(NavBarButton.tidalSearch)))
          .width,
      0,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey(NavBarButton.collection))).width,
      0,
    );
  });
}
