import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:video_player/video_player.dart';

import 'package:flick/features/player/widgets/motion_art_widget.dart';
import 'package:flick/services/motion_art/animated_artwork_service.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

// iTunes finds the album, but boidu only has static art: a final miss.
MockClient _definitiveMissClient() => MockClient((request) async {
  final url = request.url;
  if (url.host == 'itunes.apple.com') {
    return _json({
      'resultCount': 1,
      'results': [
        {
          'collectionId': 42,
          'collectionName': 'Anti-Hero',
          'artistName': 'Taylor Swift',
          'trackName': 'Anti-Hero',
        },
      ],
    });
  }
  if (url.host == 'artwork.boidu.dev') {
    return _json({
      'name': 'Anti-Hero',
      'artist': 'Taylor Swift',
      'albumId': '42',
      'static': 'https://cdn.example/42.jpg',
    });
  }
  return _json({'error': 'unexpected $url'}, 500);
});

// boidu is rate limiting: retryable.
MockClient _transientClient() => MockClient((request) async {
  final url = request.url;
  if (url.host == 'itunes.apple.com') {
    return _json({'resultCount': 0, 'results': []});
  }
  if (url.host == 'artwork.boidu.dev') {
    return _json({'error': 'busy'}, 503);
  }
  return _json({'error': 'unexpected $url'}, 500);
});

// Never answers, so the lookup stays in flight.
MockClient _pendingClient() =>
    MockClient((request) => Completer<http.Response>().future);

// Interleaves real async time with fake-clock pumps so the lookup can walk
// through its real disk/HTTP steps inside a widget test.
Future<void> _drainRealAsync(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
}

Widget _host(
  MockClient client, {
  bool enabled = true,
  ValueListenable<bool>? suppression,
}) => MaterialApp(
  home: Scaffold(
    body: MotionArtView(
      title: 'Anti-Hero',
      artist: 'Taylor Swift',
      fallback: const Text('fallback'),
      loadingFallback: const Text('loading'),
      enabled: enabled,
      suppressionOverride: suppression ?? ValueNotifier<bool>(false),
      serviceOverride: AnimatedArtworkService.create(client: client),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory cacheDir;

  setUp(() async {
    cacheDir = await Directory.systemTemp.createTemp('motion_art_widget_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => cacheDir.path,
        );
  });

  tearDown(() async {
    if (await cacheDir.exists()) {
      await cacheDir.delete(recursive: true);
    }
  });

  testWidgets('shows the loading fallback while the first lookup is pending', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_pendingClient()));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('loading'), findsOneWidget);
    expect(find.text('fallback'), findsNothing);
  });

  testWidgets('settles to the fallback on a definitive miss without retrying', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_definitiveMissClient()));
    await tester.pump(const Duration(milliseconds: 200));
    await _drainRealAsync(tester);

    expect(find.text('fallback'), findsOneWidget);
    expect(find.text('loading'), findsNothing);
    expect(find.byType(VideoPlayer), findsNothing);
  });

  testWidgets('settles to the fallback after transient retries are exhausted', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_transientClient()));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('loading'), findsOneWidget);

    // Let the first lookup fail for real (503); later retries are served by the
    // short-lived transient cache, so pumping the fake retry delay is enough.
    await _drainRealAsync(tester);

    // The view retries 4 times before giving up and settling on the fallback.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 36));
    }
    await tester.pump();

    expect(find.text('fallback'), findsOneWidget);
    expect(find.text('loading'), findsNothing);
    expect(find.byType(VideoPlayer), findsNothing);
  });

  testWidgets('disabled views never show the loading fallback', (tester) async {
    await tester.pumpWidget(_host(_pendingClient(), enabled: false));
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('fallback'), findsOneWidget);
    expect(find.text('loading'), findsNothing);
  });

  testWidgets('suppressed views never show the loading fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(_pendingClient(), suppression: ValueNotifier<bool>(true)),
    );
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('fallback'), findsOneWidget);
    expect(find.text('loading'), findsNothing);
  });
}
