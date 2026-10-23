import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/services/network_cache_service.dart';
import 'package:flick/services/sources/tidal_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

NetworkServerEntity _server({String? token}) {
  return NetworkServerEntity()
    ..id = 9
    ..label = 'Tidal'
    ..protocol = 'tidal'
    ..baseUrl = TidalService.tidalBaseUrl
    ..username = null
    ..token = token;
}

String _validToken() => jsonEncode({
  'access_token': 'acc-xyz',
  'refresh_token': 'ref-xyz',
  'user_id': 'user-1',
  'country_code': 'NO',
  'expires_at_ms': DateTime.now()
      .add(const Duration(hours: 1))
      .millisecondsSinceEpoch,
});

String _btsManifest() => base64Encode(
  utf8.encode(
    jsonEncode({
      'mimeType': 'audio/flac',
      'codecs': 'flac',
      'encryptionType': 'NONE',
      'urls': ['https://cdn.tidal.com/track/flac/silent-hang'],
      'sampleRate': 44100,
      'bitDepth': 16,
    }),
  ),
);

/// A response future that never completes: TIDAL accepted the request and
/// never answered.
Future<http.Response> _hang() => Completer<http.Response>().future;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NetworkCacheService cache;

  setUp(() async {
    cache = NetworkCacheService(
      rootDirectory: await Directory.systemTemp.createTemp('tidal_hang_test'),
    );
  });

  tearDown(() {});

  group('TIDAL silent-hang mitigation', () {
    test(
      'default resolution timeout is 8s and segment timeouts are untouched',
      () {
        final service = TidalService.create();
        expect(
          service.streamResolveTimeoutForTesting,
          const Duration(seconds: 8),
        );
        expect(
          TidalService.defaultStreamResolveTimeout,
          const Duration(seconds: 8),
        );
        expect(service.dashSegmentTimeoutsForTesting, (
          header: const Duration(seconds: 15),
          idle: const Duration(seconds: 20),
        ));
      },
    );

    test(
      'one hang is shared by the descriptor path and the ensureLocal fallback',
      () async {
        var calls = 0;
        final client = MockClient((request) async {
          if (request.url.path.contains('/playbackinfopostpaywall')) {
            calls++;
            return _hang();
          }
          return http.Response('not found', 404);
        });
        final service = TidalService.create(
          client: client,
          networkCache: cache,
          streamResolveTimeout: const Duration(milliseconds: 120),
          resolveFailureTtl: const Duration(seconds: 5),
        );
        final server = _server(token: _validToken());

        await expectLater(
          service.streamDescriptor(server, 'hang-1'),
          throwsA(isA<TidalUnavailableException>()),
        );
        expect(calls, 1);
        expect(service.resolutionFailureCountForTesting, 1);

        // ensureLocal falls back to stream() on the same service instance.
        // It must replay the failure instead of paying a second full hang.
        final stopwatch = Stopwatch()..start();
        await expectLater(
          service.stream(server, 'hang-1', extension: 'flac'),
          throwsA(isA<TidalUnavailableException>()),
        );
        stopwatch.stop();
        expect(calls, 1, reason: 'the fallback must not touch the network');
        expect(
          stopwatch.elapsed,
          lessThan(const Duration(milliseconds: 60)),
          reason: 'the fallback must fail fast, not re-hang',
        );
      },
    );

    test(
      'the failure record expires and a real attempt happens again',
      () async {
        var calls = 0;
        final client = MockClient((request) async {
          if (request.url.path.contains('/playbackinfopostpaywall')) {
            calls++;
            return _hang();
          }
          return http.Response('not found', 404);
        });
        final service = TidalService.create(
          client: client,
          networkCache: cache,
          streamResolveTimeout: const Duration(milliseconds: 60),
          resolveFailureTtl: const Duration(milliseconds: 150),
        );
        final server = _server(token: _validToken());

        await expectLater(
          service.streamDescriptor(server, 'hang-expire'),
          throwsA(isA<TidalUnavailableException>()),
        );
        expect(calls, 1);

        await Future<void>.delayed(const Duration(milliseconds: 200));

        await expectLater(
          service.streamDescriptor(server, 'hang-expire'),
          throwsA(isA<TidalUnavailableException>()),
        );
        expect(
          calls,
          2,
          reason: 'the expired record must not suppress retries',
        );
      },
    );

    test('a successful resolution clears the failure record', () async {
      var hang = true;
      final client = MockClient((request) async {
        if (request.url.path.contains('/playbackinfopostpaywall')) {
          return hang
              ? _hang()
              : http.Response(
                  jsonEncode({
                    'manifest': _btsManifest(),
                    'manifestMimeType': 'application/vnd.tidal.bts',
                    'audioQuality': 'LOSSLESS',
                  }),
                  200,
                );
        }
        if (request.url.host == 'cdn.tidal.com') {
          return http.Response.bytes([1, 2, 3], 200);
        }
        return http.Response('not found', 404);
      });
      final service = TidalService.create(
        client: client,
        networkCache: cache,
        streamResolveTimeout: const Duration(milliseconds: 60),
        resolveFailureTtl: const Duration(milliseconds: 150),
      );
      final server = _server(token: _validToken());

      await expectLater(
        service.streamDescriptor(server, 'recovers'),
        throwsA(isA<TidalUnavailableException>()),
      );
      expect(service.resolutionFailureCountForTesting, 1);

      await Future<void>.delayed(const Duration(milliseconds: 200));
      hang = false;

      final desc = await service.streamDescriptor(server, 'recovers');
      expect(desc, isNotNull);
      expect(service.getResolvedStream('recovers'), isNotNull);
      expect(service.resolutionFailureCountForTesting, 0);
    });

    test(
      'breaker opens after three timeouts and blocks during cooldown',
      () async {
        var calls = 0;
        final client = MockClient((request) async {
          if (request.url.path.contains('/playbackinfopostpaywall')) {
            calls++;
            return _hang();
          }
          return http.Response('not found', 404);
        });
        final service = TidalService.create(
          client: client,
          networkCache: cache,
          streamResolveTimeout: const Duration(milliseconds: 40),
          resolveFailureTtl: const Duration(milliseconds: 1),
          resolveBreakerCooldown: const Duration(milliseconds: 200),
        );
        final server = _server(token: _validToken());

        for (var i = 0; i < 3; i++) {
          await expectLater(
            service.streamDescriptor(server, 'hang-$i'),
            throwsA(isA<TidalUnavailableException>()),
          );
        }
        expect(calls, 3);

        final stopwatch = Stopwatch()..start();
        await expectLater(
          service.streamDescriptor(server, 'blocked-track'),
          throwsA(
            isA<TidalUnavailableException>().having(
              (e) => e.message,
              'message',
              contains('TIDAL is not responding'),
            ),
          ),
        );
        stopwatch.stop();
        expect(calls, 3, reason: 'open breaker must not touch the network');
        expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 50)));
      },
    );

    test('half-open probe closes the breaker on success', () async {
      var calls = 0;
      var hang = true;
      final client = MockClient((request) async {
        if (request.url.path.contains('/playbackinfopostpaywall')) {
          calls++;
          return hang
              ? _hang()
              : http.Response(
                  jsonEncode({
                    'manifest': _btsManifest(),
                    'manifestMimeType': 'application/vnd.tidal.bts',
                    'audioQuality': 'LOSSLESS',
                  }),
                  200,
                );
        }
        if (request.url.host == 'cdn.tidal.com') {
          return http.Response.bytes([1, 2, 3], 200);
        }
        return http.Response('not found', 404);
      });
      final service = TidalService.create(
        client: client,
        networkCache: cache,
        streamResolveTimeout: const Duration(milliseconds: 40),
        resolveFailureTtl: const Duration(milliseconds: 1),
        resolveBreakerCooldown: const Duration(milliseconds: 120),
      );
      final server = _server(token: _validToken());

      for (var i = 0; i < 3; i++) {
        await expectLater(
          service.streamDescriptor(server, 'open-$i'),
          throwsA(isA<TidalUnavailableException>()),
        );
      }
      expect(calls, 3);

      await Future<void>.delayed(const Duration(milliseconds: 160));
      hang = false;

      final desc = await service.streamDescriptor(server, 'probe-ok');
      expect(desc, isNotNull);
      expect(calls, 4, reason: 'half-open must allow exactly one probe');

      // Breaker closed: the next (hanging) track gets a real attempt again.
      hang = true;
      await expectLater(
        service.streamDescriptor(server, 'after-close'),
        throwsA(isA<TidalUnavailableException>()),
      );
      expect(calls, 5);
    });

    test('half-open probe failure re-opens the breaker', () async {
      var calls = 0;
      final client = MockClient((request) async {
        if (request.url.path.contains('/playbackinfopostpaywall')) {
          calls++;
          return _hang();
        }
        return http.Response('not found', 404);
      });
      final service = TidalService.create(
        client: client,
        networkCache: cache,
        streamResolveTimeout: const Duration(milliseconds: 40),
        resolveFailureTtl: const Duration(milliseconds: 1),
        resolveBreakerCooldown: const Duration(milliseconds: 120),
      );
      final server = _server(token: _validToken());

      for (var i = 0; i < 3; i++) {
        await expectLater(
          service.streamDescriptor(server, 'open-$i'),
          throwsA(isA<TidalUnavailableException>()),
        );
      }
      expect(calls, 3);

      await Future<void>.delayed(const Duration(milliseconds: 160));

      final stopwatch = Stopwatch()..start();
      await expectLater(
        service.streamDescriptor(server, 'probe-fails'),
        throwsA(isA<TidalUnavailableException>()),
      );
      stopwatch.stop();
      expect(calls, 4, reason: 'the probe is allowed to touch the network');
      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 30)),
        reason: 'the probe must actually attempt the network',
      );

      await expectLater(
        service.streamDescriptor(server, 'blocked-again'),
        throwsA(isA<TidalUnavailableException>()),
      );
      expect(calls, 4, reason: 'a failed probe must re-open the breaker');
    });

    test('a success resets the consecutive timeout counter', () async {
      var calls = 0;
      var hang = true;
      final client = MockClient((request) async {
        if (request.url.path.contains('/playbackinfopostpaywall')) {
          calls++;
          return hang
              ? _hang()
              : http.Response(
                  jsonEncode({
                    'manifest': _btsManifest(),
                    'manifestMimeType': 'application/vnd.tidal.bts',
                    'audioQuality': 'LOSSLESS',
                  }),
                  200,
                );
        }
        if (request.url.host == 'cdn.tidal.com') {
          return http.Response.bytes([1, 2, 3], 200);
        }
        return http.Response('not found', 404);
      });
      final service = TidalService.create(
        client: client,
        networkCache: cache,
        streamResolveTimeout: const Duration(milliseconds: 40),
        resolveFailureTtl: const Duration(milliseconds: 1),
      );
      final server = _server(token: _validToken());

      // Two timeouts, not yet enough to open the breaker.
      for (var i = 0; i < 2; i++) {
        await expectLater(
          service.streamDescriptor(server, 'pre-$i'),
          throwsA(isA<TidalUnavailableException>()),
        );
      }
      expect(calls, 2);

      // A success resets the counter.
      hang = false;
      expect(await service.streamDescriptor(server, 'reset-ok'), isNotNull);
      expect(calls, 3);

      // Two more timeouts must still be tolerated: the breaker is closed.
      hang = true;
      for (var i = 0; i < 2; i++) {
        await expectLater(
          service.streamDescriptor(server, 'post-$i'),
          throwsA(isA<TidalUnavailableException>()),
        );
      }
      expect(
        calls,
        5,
        reason: 'the counter restarted, so these are not yet three consecutive',
      );

      // The third consecutive timeout opens it.
      await expectLater(
        service.streamDescriptor(server, 'post-2'),
        throwsA(isA<TidalUnavailableException>()),
      );
      expect(calls, 6);
      await expectLater(
        service.streamDescriptor(server, 'blocked'),
        throwsA(isA<TidalUnavailableException>()),
      );
      expect(calls, 6, reason: 'three consecutive timeouts open the breaker');
    });

    test('permanent HTTP errors are not negative-cached as hangs', () async {
      var calls = 0;
      final client = MockClient((request) async {
        if (request.url.path.contains('/playbackinfopostpaywall')) {
          calls++;
          return http.Response('forbidden', 404);
        }
        return http.Response('not found', 404);
      });
      final service = TidalService.create(
        client: client,
        networkCache: cache,
        streamResolveTimeout: const Duration(milliseconds: 60),
        resolveFailureTtl: const Duration(seconds: 5),
      );
      final server = _server(token: _validToken());

      await expectLater(
        service.streamDescriptor(server, 'missing-1'),
        throwsA(
          isA<TidalException>().having(
            (e) => e,
            'type',
            isNot(isA<TidalUnavailableException>()),
          ),
        ),
      );
      final firstAttemptCalls = calls;
      expect(firstAttemptCalls, greaterThan(1));

      await expectLater(
        service.streamDescriptor(server, 'missing-1'),
        throwsA(isA<TidalException>()),
      );
      expect(
        calls,
        greaterThan(firstAttemptCalls),
        reason: 'a 404 must not masquerade as a network hang',
      );
      expect(service.resolutionFailureCountForTesting, 0);
    });
  });
}
