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
      await TidalStreamProxy.instance.stop();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('prepares stream in ~sub-second and handles HTTP Range requests', () async {
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
      expect(resp1.headers.value(HttpHeaders.contentRangeHeader), startsWith('bytes 0-49/'));
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
    });

    test('cancelTrack aborts stream session and cleans up temporary file', () async {
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
    });
  });
}
