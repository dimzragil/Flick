import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/services/network_cache_service.dart';
import 'package:flick/services/sources/tidal_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

NetworkServerEntity _server({String? token}) {
  return NetworkServerEntity()
    ..id = 9
    ..label = 'Tidal Test'
    ..protocol = 'tidal'
    ..baseUrl = TidalService.tidalBaseUrl
    ..token = token;
}

String _validToken() => jsonEncode({
  'access_token': 'acc-xyz',
  'refresh_token': 'ref-abc',
  'user_id': 'user-1',
  'country_code': 'NO',
  'expires_at_ms': DateTime.now()
      .add(const Duration(hours: 2))
      .millisecondsSinceEpoch,
});

/// A two-segment DASH manifest: init + seg_1 + seg_2.
const _mpdXml = '''<?xml version="1.0" encoding="utf-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011">
  <Period>
    <AdaptationSet mimeType="audio/mp4" codecs="flac">
      <Representation id="rep1" audioSamplingRate="96000">
        <SegmentTemplate initialization="https://cdn.tidal.com/init.mp4" media="https://cdn.tidal.com/seg_\$Number\$.mp4" startNumber="1">
          <SegmentTimeline><S d="1000" r="1" /></SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>''';

http.StreamedResponse _bytes(List<int> body, int status) =>
    http.StreamedResponse(Stream.value(body), status);

/// Serves the playback-info manifest plus the static init/segment bytes that
/// every test in this file assembles into `[1,2,3,4,5,6,7]`.
http.StreamedResponse _serveStatic(http.BaseRequest request) {
  final path = request.url.path;
  if (path.contains('/playbackinfopostpaywall')) {
    return _bytes(
      utf8.encode(
        jsonEncode({
          'manifest': base64Encode(utf8.encode(_mpdXml)),
          'manifestMimeType': 'application/dash+xml',
          'audioQuality': 'HI_RES_LOSSLESS',
        }),
      ),
      200,
    );
  }
  if (path.endsWith('/init.mp4')) return _bytes([1, 2, 3], 200);
  if (path.endsWith('/seg_1.mp4')) return _bytes([4, 5], 200);
  if (path.endsWith('/seg_2.mp4')) return _bytes([6, 7], 200);
  return _bytes(utf8.encode('not found'), 404);
}

Stream<List<int>> _dribble(List<List<int>> chunks, Duration gap) async* {
  for (final chunk in chunks) {
    await Future<void>.delayed(gap);
    yield chunk;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('DASH segment download resilience', () {
    late Directory tempDir;
    late NetworkCacheService cache;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('tidal_dash_resilient');
      cache = NetworkCacheService(rootDirectory: tempDir);
    });

    tearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    test(
      'retries a transient segment failure instead of aborting the track',
      () async {
        var seg2Requests = 0;
        final progress = <double>[];
        final client = MockClient.streaming((request, _) async {
          if (request.url.path.endsWith('/seg_2.mp4')) {
            seg2Requests++;
            return seg2Requests == 1
                ? _bytes(utf8.encode('boom'), 503)
                : _bytes([6, 7], 200);
          }
          return _serveStatic(request);
        });
        final service = TidalService.create(
          client: client,
          networkCache: cache,
        );

        final filePath = await service.stream(
          _server(token: _validToken()),
          'retry_segment_track',
          onProgress: progress.add,
        );

        expect(File(filePath).readAsBytesSync(), [1, 2, 3, 4, 5, 6, 7]);
        expect(seg2Requests, 2, reason: 'the failed segment must be retried');
        // Progress still reports in-order contiguous writes only.
        expect(progress, [1 / 3, 2 / 3]);
      },
    );

    test('retries a transient init segment failure', () async {
      var initRequests = 0;
      final client = MockClient.streaming((request, _) async {
        if (request.url.path.endsWith('/init.mp4')) {
          initRequests++;
          return initRequests == 1
              ? _bytes(utf8.encode('boom'), 500)
              : _bytes([1, 2, 3], 200);
        }
        return _serveStatic(request);
      });
      final service = TidalService.create(client: client, networkCache: cache);

      final filePath = await service.stream(
        _server(token: _validToken()),
        'retry_init_track',
      );

      expect(File(filePath).readAsBytesSync(), [1, 2, 3, 4, 5, 6, 7]);
      expect(initRequests, 2);
    });

    test('aborts after bounded retries and cleans up partial files', () async {
      var seg2Requests = 0;
      final client = MockClient.streaming((request, _) async {
        if (request.url.path.endsWith('/seg_2.mp4')) {
          seg2Requests++;
          return _bytes(utf8.encode('down'), 500);
        }
        return _serveStatic(request);
      });
      final service = TidalService.create(
        client: client,
        networkCache: cache,
        dashSegmentAttempts: 2,
      );

      await expectLater(
        service.stream(_server(token: _validToken()), 'permanent_fail_track'),
        throwsA(isA<TidalException>()),
      );
      expect(seg2Requests, 2, reason: 'attempts must be bounded, not hammered');

      final leftovers = Directory(
        '${tempDir.path}/9',
      ).listSync().whereType<File>().map((file) => file.path).toList();
      expect(
        leftovers,
        isEmpty,
        reason: 'partial downloads must be deleted after a failure',
      );
    });

    test(
      'slow-but-progressing segment survives (idle timeout, not total)',
      () async {
        final client = MockClient.streaming((request, _) async {
          if (request.url.path.endsWith('/seg_2.mp4')) {
            // ~300ms total transfer, far beyond the 100ms header bound, but
            // every inter-chunk gap (150ms) is below the 250ms stall timeout.
            return http.StreamedResponse(
              _dribble([
                [6],
                [7],
              ], const Duration(milliseconds: 150)),
              200,
            );
          }
          return _serveStatic(request);
        });
        final service = TidalService.create(
          client: client,
          networkCache: cache,
          dashSegmentHeaderTimeout: const Duration(milliseconds: 100),
          dashSegmentIdleTimeout: const Duration(milliseconds: 250),
        );

        final filePath = await service.stream(
          _server(token: _validToken()),
          'slow_progress_track',
        );

        expect(File(filePath).readAsBytesSync(), [1, 2, 3, 4, 5, 6, 7]);
      },
    );

    test(
      'a stalled segment download is retried and the track completes',
      () async {
        var seg2Requests = 0;
        final stalled = StreamController<List<int>>();
        addTearDown(stalled.close);
        final client = MockClient.streaming((request, _) async {
          if (request.url.path.endsWith('/seg_2.mp4')) {
            seg2Requests++;
            if (seg2Requests == 1) {
              // Emit nothing: the idle timeout must fail this attempt and let
              // the retry loop fetch the segment again.
              return http.StreamedResponse(stalled.stream, 200);
            }
            return _bytes([6, 7], 200);
          }
          return _serveStatic(request);
        });
        final service = TidalService.create(
          client: client,
          networkCache: cache,
          dashSegmentIdleTimeout: const Duration(milliseconds: 80),
        );

        final filePath = await service.stream(
          _server(token: _validToken()),
          'stalled_track',
        );

        expect(File(filePath).readAsBytesSync(), [1, 2, 3, 4, 5, 6, 7]);
        expect(seg2Requests, 2);
      },
    );

    test('never truncates the streaming session <target>.part file', () async {
      // Simulate a live TidalStreamSession writing/serving the track: its
      // temp file is `<targetPath>.part`. The complete-file downloader must
      // use its own temp file so this one survives untouched.
      final targetPath = await cache.pathFor(
        9,
        'collision_track',
        extension: 'mp4',
      );
      final streamPart = File('$targetPath.part');
      const sentinel = [9, 9, 9, 9];
      await streamPart.writeAsBytes(sentinel);

      final seg2Gate = Completer<void>();
      final seg2Started = Completer<void>();
      final client = MockClient.streaming((request, _) async {
        if (request.url.path.endsWith('/seg_2.mp4')) {
          if (!seg2Started.isCompleted) seg2Started.complete();
          await seg2Gate.future;
          return _bytes([6, 7], 200);
        }
        return _serveStatic(request);
      });
      final service = TidalService.create(client: client, networkCache: cache);

      final download = service.stream(
        _server(token: _validToken()),
        'collision_track',
        // ensureLocal() passes song.fileType, so the cache lookup is an exact
        // <hash>.flac miss; the in-progress <hash>.mp4.part must not be
        // mistaken for a completed file.
        extension: 'flac',
      );
      await seg2Started.future;
      expect(
        await streamPart.readAsBytes(),
        sentinel,
        reason: 'the full downloader must not truncate the live stream file',
      );

      seg2Gate.complete();
      final filePath = await download;

      expect(File(filePath).readAsBytesSync(), [1, 2, 3, 4, 5, 6, 7]);
      expect(
        await streamPart.readAsBytes(),
        sentinel,
        reason: 'the streaming session file must survive the download',
      );
    });
  });
}
