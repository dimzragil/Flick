import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/features/tidal/widgets/tidal_shimmer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shimmer/shimmer.dart';

Widget _host(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  setUp(() {
    AppConstants.setAnimationsEnabled(true);
  });

  testWidgets('list skeleton renders one row per requested row', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const TidalListSkeleton(rows: 2)));

    // 2 thumbnails + 2 rows x (title + subtitle + trailing) text bars.
    expect(find.byType(TidalSkeletonBox), findsNWidgets(8));
    expect(find.byType(Shimmer), findsOneWidget);
    expect(tester.widget<Shimmer>(find.byType(Shimmer)).enabled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shimmer is static when app-wide animations are disabled', (
    tester,
  ) async {
    AppConstants.setAnimationsEnabled(false);
    addTearDown(() => AppConstants.setAnimationsEnabled(true));

    await tester.pumpWidget(_host(const TidalListSkeleton(rows: 1)));

    expect(tester.widget<Shimmer>(find.byType(Shimmer)).enabled, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hub feed skeleton fits a narrow screen without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _host(const SingleChildScrollView(child: TidalHubFeedSkeleton())),
    );

    expect(find.byType(TidalSkeletonBox), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail, banner, carousel and search skeletons render', (
    tester,
  ) async {
    for (final skeleton in const [
      TidalDetailBodySkeleton(),
      TidalDetailBodySkeleton(artSize: 140, circle: true),
      TidalBannerBodySkeleton(),
      TidalCarouselSkeleton(),
      TidalSearchSkeleton(),
    ]) {
      await tester.pumpWidget(_host(skeleton));
      expect(tester.takeException(), isNull);
    }
  });
}
