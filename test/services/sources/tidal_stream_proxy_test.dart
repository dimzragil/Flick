import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flick/services/sources/dash_manifest_parser.dart';
import 'package:flick/services/sources/tidal_stream_proxy.dart';

void main() {
  group('TidalStreamProxy', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('tidal_proxy_test');
    });

    tearDown(() async {
      TidalStreamProxy.instance.cancelAllSessions();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'prepares stream in ~sub-second and handles HTTP Range requests',
      () async {
        final targetPath = '${tempDir.path}/track1.mp4';
        final initBytes = List<int>.generate(100, (i) => i);
        final seg0Bytes = List<int>.generate(200, (i) => 100 + i);
        final seg1Bytes = List<int>.generate(200, (i) => 200 + i);

        final client = MockClient((request) async {
          if (request.url.path.contains('init')) {
            return http.Response.bytes(initBytes, 200);
          }
          if (request.url.path.contains('seg0')) {
            return http.Response.bytes(seg0Bytes, 200);
          }
          if (request.url.path.contains('seg1')) {
            return http.Response.bytes(seg1Bytes, 200);
          }
          return http.Response('Not Found', 404);
        });

        const dashInfo = DashTrackInfo(
          codec: 'flac',
          sampleRate: 96000,
          bitDepth: 24,
          initializationUrl: 'https://cdn.tidal.com/init.mp4',
          segmentUrls: [
            'https://cdn.tidal.com/seg0.mp4',
            'https://cdn.tidal.com/seg1.mp4',
          ],
          bandwidth: 2000000,
          durationSeconds: 10.0,
        );

        final streamUrl = await TidalStreamProxy.instance.prepareStream(
          trackId: 'track1',
          dashInfo: dashInfo,
          targetPath: targetPath,
          client: client,
        );

        expect(streamUrl, contains('http://127.0.0.1:'));
        expect(streamUrl, endsWith('.mp4'));

        // Test Range request for init bytes (first 50 bytes)
        final httpClient = HttpClient();
        final req1 = await httpClient.getUrl(Uri.parse(streamUrl));
        req1.headers.set(HttpHeaders.rangeHeader, 'bytes=0-49');
        final resp1 = await req1.close();

        expect(resp1.statusCode, HttpStatus.partialContent);
        expect(
          resp1.headers.value(HttpHeaders.contentRangeHeader),
          startsWith('bytes 0-49/'),
        );
        final body1 = await resp1.expand((b) => b).toList();
        expect(body1, initBytes.sublist(0, 50));

        // Test Range request spanning into segment 0
        final req2 = await httpClient.getUrl(Uri.parse(streamUrl));
        req2.headers.set(HttpHeaders.rangeHeader, 'bytes=100-149');
        final resp2 = await req2.close();

        expect(resp2.statusCode, HttpStatus.partialContent);
        final body2 = await resp2.expand((b) => b).toList();
        expect(body2, seg0Bytes.sublist(0, 50));

        // Wait a moment for background worker to finalize download
        await Future<void>.delayed(const Duration(milliseconds: 200));
        httpClient.close();
      },
    );

    test(
      'cancelTrack aborts stream session and cleans up temporary file',
      () async {
        final targetPath = '${tempDir.path}/track_cancel.mp4';
        final client = MockClient((request) async {
          return http.Response.bytes([1, 2, 3, 4], 200);
        });

        const dashInfo = DashTrackInfo(
          codec: 'flac',
          sampleRate: 96000,
          bitDepth: 24,
          initializationUrl: 'https://cdn.tidal.com/init.mp4',
          segmentUrls: ['https://cdn.tidal.com/seg0.mp4'],
        );

        final streamUrl = await TidalStreamProxy.instance.prepareStream(
          trackId: 'track_cancel',
          dashInfo: dashInfo,
          targetPath: targetPath,
          client: client,
        );

        expect(streamUrl, isNotEmpty);
        TidalStreamProxy.instance.cancelTrack('track_cancel');

        // Request to cancelled session should return 404
        final httpClient = HttpClient();
        final req = await httpClient.getUrl(Uri.parse(streamUrl));
        final resp = await req.close();
        expect(resp.statusCode, HttpStatus.notFound);
        httpClient.close();
      },
    );

    test('prebuffers BTS locally and serves byte ranges', () async {
      final targetPath = '${tempDir.path}/track.flac';
      final sourceBytes = List<int>.generate(1024 * 1024 + 17, (i) => i % 251);
      final client = MockClient((request) async {
        expect(request.url.host, 'cdn.tidal.com');
        return http.Response.bytes(sourceBytes, 200);
      });

      final streamUrl = await TidalStreamProxy.instance.prepareBtsStream(
        trackId: 'bts_track',
        sourceUrl: 'https://cdn.tidal.com/track.flac',
        targetPath: targetPath,
        contentType: 'audio/flac',
        client: client,
      );
      expect(streamUrl, startsWith('http://127.0.0.1:'));
      expect(streamUrl, endsWith('.flac'));

      final httpClient = HttpClient();
      final initialRequest = await httpClient.getUrl(Uri.parse(streamUrl));
      initialRequest.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=0-${1024 * 1024 - 1}',
      );
      final initialResponse = await initialRequest.close();
      expect(initialResponse.statusCode, HttpStatus.partialContent);
      expect(
        initialResponse.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 0-${256 * 1024 - 1}/1048593',
      );
      expect(
        (await initialResponse.expand((bytes) => bytes).toList()).length,
        256 * 1024,
      );

      final request = await httpClient.getUrl(Uri.parse(streamUrl));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=100-199');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.partialContent);
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 100-199/1048593',
      );
      expect(
        await response.expand((bytes) => bytes).toList(),
        sourceBytes.sublist(100, 200),
      );
      httpClient.close();
    });

    test(
      'cancel during prebuffer fails start() fast with StateError instead of '
      'hanging on the 20s timeout',
      () async {
        final targetPath = '${tempDir.path}/cancel_prebuffer.flac';
        // The main download stream never emits: the prebuffer can only
        // complete via cancel (or the 20s timeout).
        final downloadController = StreamController<List<int>>();
        final client = MockClient.streaming((request, bodyStream) async {
          final range = request.headers.entries
              .where((e) => e.key.toLowerCase() == 'range')
              .map((e) => e.value)
              .firstOrNull;
          if (range != null && range.startsWith('bytes=-')) {
            // Tail prefetch: pretend the CDN ignores the suffix range.
            return http.StreamedResponse(
              const Stream<List<int>>.empty(),
              200,
              contentLength: 0,
            );
          }
          return http.StreamedResponse(
            downloadController.stream,
            200,
            contentLength: 8 * 1024 * 1024,
          );
        });

        final session = TidalBtsStreamSession(
          streamToken: 'tok-cancel',
          trackId: 'cancel_prebuffer',
          sourceUrl: 'https://cdn.tidal.com/track.flac',
          targetPath: targetPath,
          client: client,
          contentType: 'audio/flac',
        );

        final stopwatch = Stopwatch()..start();
        final startFuture = session.start();
        // Let start() open the part file and enter the download loop.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        session.cancel();
        // End the download stream so the consume loop observes the cancel.
        await downloadController.close();

        await expectLater(
          startFuture,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'BTS session cancelled',
            ),
          ),
        );
        stopwatch.stop();
        // Without the cancel fix, start() would hang until the 20s _ready
        // timeout fired.
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
      },
    );

    test(
      'finalized session is evicted from active map, closes client, and serves ranges',
      () async {
        final targetPath = '${tempDir.path}/finalize_eviction.mp4';
        final initBytes = List<int>.generate(100, (i) => i);
        final seg0Bytes = List<int>.generate(200, (i) => 100 + i);

        final innerClient = MockClient((request) async {
          if (request.url.path.contains('init')) {
            return http.Response.bytes(initBytes, 200);
          }
          if (request.url.path.contains('seg0')) {
            return http.Response.bytes(seg0Bytes, 200);
          }
          return http.Response('Not Found', 404);
        });
        final trackingClient = _ClosingMockClient(innerClient);

        const dashInfo = DashTrackInfo(
          codec: 'flac',
          sampleRate: 96000,
          bitDepth: 24,
          initializationUrl: 'https://cdn.tidal.com/init.mp4',
          segmentUrls: ['https://cdn.tidal.com/seg0.mp4'],
        );

        final finalizedCompleter = Completer<void>();
        final streamUrl = await TidalStreamProxy.instance.prepareStream(
          trackId: 'track_finalize',
          dashInfo: dashInfo,
          targetPath: targetPath,
          client: trackingClient,
          onFinalized: (_) async {
            if (!finalizedCompleter.isCompleted) finalizedCompleter.complete();
          },
        );

        await finalizedCompleter.future.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // 1. Heavy session must be evicted from active map
        expect(TidalStreamProxy.instance.activeSessionCount, 0);

        // 2. Client must be closed on finalize
        expect(trackingClient.closeCallCount, greaterThanOrEqualTo(1));

        // 3. Completed stream must still serve HTTP range requests without 404
        final httpClient = HttpClient();
        final req = await httpClient.getUrl(Uri.parse(streamUrl));
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=50-99');
        final resp = await req.close();

        expect(resp.statusCode, HttpStatus.partialContent);
        final body = await resp.expand((b) => b).toList();
        expect(body, initBytes.sublist(50, 100));
        httpClient.close();
      },
    );

    test('client is closed when session is cancelled', () async {
      final targetPath = '${tempDir.path}/cancel_client.mp4';
      final innerClient = MockClient((request) async {
        return http.Response.bytes([1, 2, 3], 200);
      });
      final trackingClient = _ClosingMockClient(innerClient);

      final dashInfo = DashTrackInfo(
        codec: 'flac',
        sampleRate: 96000,
        bitDepth: 24,
        initializationUrl: 'https://cdn.tidal.com/init.mp4',
        segmentUrls: List.generate(
          10,
          (i) => 'https://cdn.tidal.com/seg$i.mp4',
        ),
      );

      await TidalStreamProxy.instance.prepareStream(
        trackId: 'track_to_cancel',
        dashInfo: dashInfo,
        targetPath: targetPath,
        client: trackingClient,
      );

      // Pump paused at buffer limit (seg 3 > seg 0 + 2), download not finished
      expect(trackingClient.closeCallCount, 0);
      expect(TidalStreamProxy.instance.activeSessionCount, 1);

      TidalStreamProxy.instance.cancelTrack('track_to_cancel');
      expect(trackingClient.closeCallCount, greaterThanOrEqualTo(1));
      expect(TidalStreamProxy.instance.activeSessionCount, 0);
    });

    test(
      'completed streams retain metadata without eviction so previous tracks do not 404',
      () async {
        // Baseline: completed metadata now survives cancelAllSessions/stop
        // by design, so assert relative growth, not an absolute count.
        final before = TidalStreamProxy.instance.completedStreamCount;
        String? firstTrackUrl;
        for (var i = 0; i < 6; i++) {
          final targetPath = '${tempDir.path}/lru_track_$i.mp4';
          final initBytes = List<int>.generate(20, (x) => x);
          final innerClient = MockClient((request) async {
            return http.Response.bytes(initBytes, 200);
          });

          const dashInfo = DashTrackInfo(
            codec: 'flac',
            sampleRate: 96000,
            bitDepth: 24,
            initializationUrl: 'https://cdn.tidal.com/init.mp4',
            segmentUrls: [],
          );

          final finalizedCompleter = Completer<void>();
          final url = await TidalStreamProxy.instance.prepareStream(
            trackId: 'lru_track_$i',
            dashInfo: dashInfo,
            targetPath: targetPath,
            client: innerClient,
            onFinalized: (_) async {
              if (!finalizedCompleter.isCompleted)
                finalizedCompleter.complete();
            },
          );
          if (i == 0) firstTrackUrl = url;

          await finalizedCompleter.future.timeout(const Duration(seconds: 5));
        }

        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(TidalStreamProxy.instance.completedStreamCount, before + 6);

        // Verify that track 0 is still servable and does not return 404
        final httpClient = HttpClient();
        final req = await httpClient.getUrl(Uri.parse(firstTrackUrl!));
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-9');
        final resp = await req.close();
        expect(resp.statusCode, HttpStatus.partialContent);
        httpClient.close();
      },
    );

    test(
      'init failure does not cause unhandled async error from seg0Future',
      () async {
        final targetPath = '${tempDir.path}/seg0_error.mp4';
        final client = MockClient((request) async {
          if (request.url.path.contains('init')) {
            throw http.ClientException('Init failed');
          }
          if (request.url.path.contains('seg0')) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            throw http.ClientException('Seg0 failed');
          }
          return http.Response('Not Found', 404);
        });

        const dashInfo = DashTrackInfo(
          codec: 'flac',
          sampleRate: 44100,
          bitDepth: 16,
          initializationUrl: 'https://cdn.tidal.com/init.mp4',
          segmentUrls: ['https://cdn.tidal.com/seg0.mp4'],
        );

        await expectLater(
          TidalStreamProxy.instance.prepareStream(
            trackId: 'seg0_err_track',
            dashInfo: dashInfo,
            targetPath: targetPath,
            client: client,
          ),
          throwsA(isA<http.ClientException>()),
        );

        // Wait long enough for seg0's delayed future to complete with error
        await Future<void>.delayed(const Duration(milliseconds: 100));
      },
    );

    test(
      'open-ended range request (bytes=0-) streams entire multi-segment DASH track continuously without early EOF',
      () async {
        final targetPath = '${tempDir.path}/open_ended_dash.mp4';
        final initBytes = List<int>.generate(100, (i) => i);
        final seg0Bytes = List<int>.generate(200, (i) => (100 + i) % 256);
        final seg1Bytes = List<int>.generate(200, (i) => (200 + i) % 256);
        final seg2Bytes = List<int>.generate(200, (i) => (300 + i) % 256);

        final client = MockClient((request) async {
          if (request.url.path.contains('init')) {
            return http.Response.bytes(initBytes, 200);
          }
          if (request.url.path.contains('seg0')) {
            return http.Response.bytes(seg0Bytes, 200);
          }
          if (request.url.path.contains('seg1')) {
            return http.Response.bytes(seg1Bytes, 200);
          }
          if (request.url.path.contains('seg2')) {
            return http.Response.bytes(seg2Bytes, 200);
          }
          return http.Response('Not Found', 404);
        });

        const dashInfo = DashTrackInfo(
          codec: 'flac',
          sampleRate: 96000,
          bitDepth: 24,
          initializationUrl: 'https://cdn.tidal.com/init.mp4',
          segmentUrls: [
            'https://cdn.tidal.com/seg0.mp4',
            'https://cdn.tidal.com/seg1.mp4',
            'https://cdn.tidal.com/seg2.mp4',
          ],
          bandwidth: 2000000,
          durationSeconds: 15.0,
        );

        final streamUrl = await TidalStreamProxy.instance.prepareStream(
          trackId: 'open_ended_track',
          dashInfo: dashInfo,
          targetPath: targetPath,
          client: client,
        );

        final httpClient = HttpClient();
        final req = await httpClient.getUrl(Uri.parse(streamUrl));
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
        final resp = await req.close();

        expect(resp.statusCode, HttpStatus.partialContent);
        // While streaming dynamic segments, Content-Length must not be set to truncate at seg0
        expect(resp.headers.value(HttpHeaders.contentLengthHeader), isNull);

        final receivedBytes = await resp.expand((b) => b).toList();
        final expectedBytes = [
          ...initBytes,
          ...seg0Bytes,
          ...seg1Bytes,
          ...seg2Bytes,
        ];
        expect(receivedBytes.length, expectedBytes.length);
        expect(receivedBytes, expectedBytes);
        httpClient.close();
      },
    );

    test(
      'bare GET (no Range header) streams entire multi-segment DASH track with 200 OK',
      () async {
        final targetPath = '${tempDir.path}/bare_get_dash.mp4';
        final initBytes = List<int>.generate(100, (i) => i);
        final seg0Bytes = List<int>.generate(200, (i) => (100 + i) % 256);
        final seg1Bytes = List<int>.generate(200, (i) => (200 + i) % 256);

        final client = MockClient((request) async {
          if (request.url.path.contains('init')) {
            return http.Response.bytes(initBytes, 200);
          }
          if (request.url.path.contains('seg0')) {
            return http.Response.bytes(seg0Bytes, 200);
          }
          if (request.url.path.contains('seg1')) {
            return http.Response.bytes(seg1Bytes, 200);
          }
          return http.Response('Not Found', 404);
        });

        const dashInfo = DashTrackInfo(
          codec: 'flac',
          sampleRate: 96000,
          bitDepth: 24,
          initializationUrl: 'https://cdn.tidal.com/init.mp4',
          segmentUrls: [
            'https://cdn.tidal.com/seg0.mp4',
            'https://cdn.tidal.com/seg1.mp4',
          ],
        );

        final streamUrl = await TidalStreamProxy.instance.prepareStream(
          trackId: 'bare_get_track',
          dashInfo: dashInfo,
          targetPath: targetPath,
          client: client,
        );

        final httpClient = HttpClient();
        final req = await httpClient.getUrl(Uri.parse(streamUrl));
        final resp = await req.close();

        expect(resp.statusCode, HttpStatus.ok);
        expect(resp.headers.value(HttpHeaders.contentLengthHeader), isNull);

        final receivedBytes = await resp.expand((b) => b).toList();
        final expectedBytes = [...initBytes, ...seg0Bytes, ...seg1Bytes];
        expect(receivedBytes.length, expectedBytes.length);
        expect(receivedBytes, expectedBytes);
        httpClient.close();
      },
    );

    test(
      'open-ended seek request (bytes=100-) streams from offset to EOF',
      () async {
        final targetPath = '${tempDir.path}/seek_dash.mp4';
        final initBytes = List<int>.generate(100, (i) => i);
        final seg0Bytes = List<int>.generate(200, (i) => (100 + i) % 256);
        final seg1Bytes = List<int>.generate(200, (i) => (200 + i) % 256);

        final client = MockClient((request) async {
          if (request.url.path.contains('init')) {
            return http.Response.bytes(initBytes, 200);
          }
          if (request.url.path.contains('seg0')) {
            return http.Response.bytes(seg0Bytes, 200);
          }
          if (request.url.path.contains('seg1')) {
            return http.Response.bytes(seg1Bytes, 200);
          }
          return http.Response('Not Found', 404);
        });

        const dashInfo = DashTrackInfo(
          codec: 'flac',
          sampleRate: 96000,
          bitDepth: 24,
          initializationUrl: 'https://cdn.tidal.com/init.mp4',
          segmentUrls: [
            'https://cdn.tidal.com/seg0.mp4',
            'https://cdn.tidal.com/seg1.mp4',
          ],
        );

        final streamUrl = await TidalStreamProxy.instance.prepareStream(
          trackId: 'seek_track',
          dashInfo: dashInfo,
          targetPath: targetPath,
          client: client,
        );

        final httpClient = HttpClient();
        final req = await httpClient.getUrl(Uri.parse(streamUrl));
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=100-');
        final resp = await req.close();

        expect(resp.statusCode, HttpStatus.partialContent);
        final receivedBytes = await resp.expand((b) => b).toList();
        final expectedBytes = [...seg0Bytes, ...seg1Bytes];
        expect(receivedBytes.length, expectedBytes.length);
        expect(receivedBytes, expectedBytes);
        httpClient.close();
      },
    );

    test(
      'explicit-end request (Rust contract) returns single closed block with Content-Length and closes',
      () async {
        final targetPath = '${tempDir.path}/rust_block.mp4';
        final initBytes = List<int>.generate(100, (i) => i);
        final seg0Bytes = List<int>.generate(200, (i) => 100 + i);

        final client = MockClient((request) async {
          if (request.url.path.contains('init')) {
            return http.Response.bytes(initBytes, 200);
          }
          if (request.url.path.contains('seg0')) {
            return http.Response.bytes(seg0Bytes, 200);
          }
          return http.Response('Not Found', 404);
        });

        const dashInfo = DashTrackInfo(
          codec: 'flac',
          sampleRate: 96000,
          bitDepth: 24,
          initializationUrl: 'https://cdn.tidal.com/init.mp4',
          segmentUrls: ['https://cdn.tidal.com/seg0.mp4'],
        );

        final streamUrl = await TidalStreamProxy.instance.prepareStream(
          trackId: 'rust_track',
          dashInfo: dashInfo,
          targetPath: targetPath,
          client: client,
        );

        final httpClient = HttpClient();
        final req = await httpClient.getUrl(Uri.parse(streamUrl));
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-99');
        final resp = await req.close();

        expect(resp.statusCode, HttpStatus.partialContent);
        expect(resp.headers.value(HttpHeaders.contentLengthHeader), '100');
        expect(
          resp.headers.value(HttpHeaders.contentRangeHeader),
          startsWith('bytes 0-99/'),
        );

        final body = await resp.expand((b) => b).toList();
        expect(body, initBytes);
        httpClient.close();
      },
    );

    test(
      'BTS open-ended range request (bytes=0-) streams entire file without early socket close',
      () async {
        final targetPath = '${tempDir.path}/open_ended_bts.flac';
        final btsBytes = List<int>.generate(400 * 1024, (i) => i % 256);

        final client = MockClient((request) async {
          return http.Response.bytes(
            btsBytes,
            200,
            headers: {'content-length': '${btsBytes.length}'},
          );
        });

        final streamUrl = await TidalStreamProxy.instance.prepareBtsStream(
          trackId: 'open_ended_bts_track',
          sourceUrl: 'https://cdn.tidal.com/audio.flac',
          targetPath: targetPath,
          contentType: 'audio/flac',
          client: client,
        );

        final httpClient = HttpClient();
        final req = await httpClient.getUrl(Uri.parse(streamUrl));
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
        final resp = await req.close();

        expect(resp.statusCode, HttpStatus.partialContent);
        final received = await resp.expand((b) => b).toList();
        expect(received.length, btsBytes.length);
        expect(received, btsBytes);
        httpClient.close();
      },
    );

    test(
      'background session stays window-limited until actively streamed',
      () async {
        final targetPath = '${tempDir.path}/window_test.mp4';
        final initBytes = List<int>.generate(100, (i) => i);
        final requestedSegments = <String>[];

        final client = MockClient((request) async {
          final path = request.url.path;
          if (path.contains('init')) {
            return http.Response.bytes(initBytes, 200);
          }
          requestedSegments.add(path);
          return http.Response.bytes(List<int>.generate(200, (i) => i), 200);
        });

        const dashInfo = DashTrackInfo(
          codec: 'flac',
          sampleRate: 44100,
          bitDepth: 16,
          initializationUrl: 'https://cdn.tidal.com/init.mp4',
          segmentUrls: [
            'https://cdn.tidal.com/seg0.mp4',
            'https://cdn.tidal.com/seg1.mp4',
            'https://cdn.tidal.com/seg2.mp4',
            'https://cdn.tidal.com/seg3.mp4',
            'https://cdn.tidal.com/seg4.mp4',
            'https://cdn.tidal.com/seg5.mp4',
            'https://cdn.tidal.com/seg6.mp4',
            'https://cdn.tidal.com/seg7.mp4',
          ],
        );

        final streamUrl = await TidalStreamProxy.instance.prepareStream(
          trackId: 'track_window',
          dashInfo: dashInfo,
          targetPath: targetPath,
          client: client,
        );

        // Give the background pump time to run ahead.
        await Future<void>.delayed(const Duration(milliseconds: 500));

        // Background session: seg0 downloaded upfront, then the pump fetches
        // at most _bufferAheadLimit (3) more segments and sleeps.
        expect(requestedSegments.length, lessThanOrEqualTo(4));

        // Simulate ExoPlayer starting progressive playback (open-ended range):
        // the session must flip to aggressive prefetch.
        final httpClient = HttpClient();
        final req = await httpClient.getUrl(Uri.parse(streamUrl));
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
        final respFuture = req.close();

        await Future<void>.delayed(const Duration(seconds: 2));

        // All 8 segments must have been fetched now.
        expect(requestedSegments.length, 8);

        // Drain the progressive response (server closes after finalize).
        final resp = await respFuture;
        await resp.drain<void>();
        httpClient.close();
      },
    );

    test(
      'deferPump creates a lazy session with zero network until needed',
      () async {
        final targetPath = '${tempDir.path}/track_deferred.mp4';
        final requestedSegments = <String>[];
        final client = MockClient((request) async {
          final path = request.url.path;
          requestedSegments.add(path);
          return http.Response.bytes(List<int>.generate(200, (i) => i), 200);
        });

        const dashInfo = DashTrackInfo(
          codec: 'flac',
          sampleRate: 96000,
          bitDepth: 24,
          initializationUrl: 'https://cdn.tidal.com/init.mp4',
          segmentUrls: [
            'https://cdn.tidal.com/seg0.mp4',
            'https://cdn.tidal.com/seg1.mp4',
            'https://cdn.tidal.com/seg2.mp4',
            'https://cdn.tidal.com/seg3.mp4',
          ],
        );

        final streamUrl = await TidalStreamProxy.instance.prepareStream(
          trackId: 'track_deferred',
          dashInfo: dashInfo,
          targetPath: targetPath,
          client: client,
          deferPump: true,
        );

        // URL is valid immediately...
        expect(streamUrl, contains('127.0.0.1'));

        // ...but nothing is downloaded while deferred.
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(requestedSegments, isEmpty);

        // kickPrefetch starts the pump on demand (init + seg0 + window).
        TidalStreamProxy.instance.kickPrefetch('track_deferred');
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(requestedSegments, isNotEmpty);
        expect(requestedSegments.any((p) => p.contains('init')), isTrue);
        expect(requestedSegments.any((p) => p.contains('seg0')), isTrue);
      },
    );

    test('first handleRequest starts a deferred session on demand', () async {
      final targetPath = '${tempDir.path}/track_deferred2.mp4';
      final requestedSegments = <String>[];
      final client = MockClient((request) async {
        final path = request.url.path;
        requestedSegments.add(path);
        return http.Response.bytes(List<int>.generate(200, (i) => i), 200);
      });

      const dashInfo = DashTrackInfo(
        codec: 'flac',
        sampleRate: 44100,
        bitDepth: 16,
        initializationUrl: 'https://cdn.tidal.com/init.mp4',
        segmentUrls: [
          'https://cdn.tidal.com/seg0.mp4',
          'https://cdn.tidal.com/seg1.mp4',
        ],
      );

      final streamUrl = await TidalStreamProxy.instance.prepareStream(
        trackId: 'track_deferred2',
        dashInfo: dashInfo,
        targetPath: targetPath,
        client: client,
        deferPump: true,
      );

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(requestedSegments, isEmpty);

      // Simulate a player connecting: the first request must trigger the
      // initial download, then serve bytes.
      final httpClient = HttpClient();
      final req = await httpClient.getUrl(Uri.parse(streamUrl));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-100');
      final resp = await req.close();
      expect(resp.statusCode, 206);
      await resp.drain<void>();
      httpClient.close();

      expect(requestedSegments.any((p) => p.contains('init')), isTrue);
      expect(requestedSegments.any((p) => p.contains('seg0')), isTrue);
    });

    test(
      'prepareBtsStream with deferPump: true creates valid session with zero initial download',
      () async {
        final targetPath = '${tempDir.path}/defer_bts.flac';
        final btsBytes = List<int>.generate(400 * 1024, (i) => i % 256);
        var networkCalls = 0;

        final client = MockClient((request) async {
          networkCalls++;
          return http.Response.bytes(
            btsBytes,
            200,
            headers: {'content-length': '${btsBytes.length}'},
          );
        });

        final streamUrl = await TidalStreamProxy.instance.prepareBtsStream(
          trackId: 'defer_bts_track',
          sourceUrl: 'https://cdn.tidal.com/audio.flac',
          targetPath: targetPath,
          contentType: 'audio/flac',
          client: client,
          deferPump: true,
        );

        expect(streamUrl, contains('/tidal-bts/'));
        // Verify zero network calls were made during preparation
        expect(networkCalls, 0);

        // First request to proxy must trigger download on-demand and include Content-Range & Content-Length
        final httpClient = HttpClient();
        final req = await httpClient.getUrl(Uri.parse(streamUrl));
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
        final resp = await req.close();

        expect(resp.statusCode, HttpStatus.partialContent);
        expect(
          resp.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 0-${btsBytes.length - 1}/${btsBytes.length}',
        );
        expect(
          resp.headers.value(HttpHeaders.contentLengthHeader),
          '${btsBytes.length}',
        );

        final received = await resp.expand((b) => b).toList();
        expect(received.length, btsBytes.length);
        expect(received, btsBytes);
        expect(networkCalls, greaterThanOrEqualTo(1));
        httpClient.close();
      },
    );

    test('kickPrefetch triggers download for deferred BTS session', () async {
      final targetPath = '${tempDir.path}/kick_bts.flac';
      final btsBytes = List<int>.generate(100 * 1024, (i) => i % 256);
      var downloadStarted = false;

      final client = MockClient((request) async {
        downloadStarted = true;
        return http.Response.bytes(
          btsBytes,
          200,
          headers: {'content-length': '${btsBytes.length}'},
        );
      });

      await TidalStreamProxy.instance.prepareBtsStream(
        trackId: 'kick_bts_track',
        sourceUrl: 'https://cdn.tidal.com/audio.flac',
        targetPath: targetPath,
        contentType: 'audio/flac',
        client: client,
        deferPump: true,
      );

      expect(downloadStarted, isFalse);

      // Kick prefetch for this BTS track
      TidalStreamProxy.instance.kickPrefetch('kick_bts_track');

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(downloadStarted, isTrue);
    });
  });
}

class _ClosingMockClient extends http.BaseClient {
  _ClosingMockClient(this._inner);
  final http.Client _inner;
  int closeCallCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _inner.send(request);
  }

  @override
  void close() {
    closeCallCount++;
    _inner.close();
  }
}
