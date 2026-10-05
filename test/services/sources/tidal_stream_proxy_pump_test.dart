import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flick/services/sources/dash_manifest_parser.dart';
import 'package:flick/services/sources/tidal_stream_proxy.dart';

void main() {
  group('TidalStreamProxy pump retry and EOF contract', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('tidal_pump_test');
    });

    tearDown(() async {
      await TidalStreamProxy.instance.stop();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('pump retries transient segment errors and completes stream', () async {
      final targetPath = '${tempDir.path}/retry_test.mp4';
      final initBytes = List<int>.generate(100, (i) => i);
      final seg0Bytes = List<int>.generate(200, (i) => 100 + i);
      final seg1Bytes = List<int>.generate(200, (i) => 200 + i);

      var seg1Attempts = 0;
      final client = MockClient((request) async {
        if (request.url.path.contains('init')) {
          return http.Response.bytes(initBytes, 200);
        }
        if (request.url.path.contains('seg0')) {
          return http.Response.bytes(seg0Bytes, 200);
        }
        if (request.url.path.contains('seg1')) {
          seg1Attempts++;
          if (seg1Attempts == 1) {
            return http.Response('Internal Server Error', 500);
          }
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
        trackId: 'retry_track',
        dashInfo: dashInfo,
        targetPath: targetPath,
        client: client,
        initialRetryDelay: Duration.zero,
      );

      // Trigger pump by requesting seg1 offset
      final httpClient = HttpClient();
      final req = await httpClient.getUrl(Uri.parse(streamUrl));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=300-349');
      final resp = await req.close();

      expect(resp.statusCode, HttpStatus.partialContent);
      final body = await resp.expand((b) => b).toList();
      expect(body, seg1Bytes.sublist(0, 50));
      expect(seg1Attempts, greaterThanOrEqualTo(2));
      httpClient.close();
    });

    test('dead session after permanent pump failure is replaced by prepareStream', () async {
      final targetPath1 = '${tempDir.path}/fail_track1.mp4';
      final targetPath2 = '${tempDir.path}/fail_track2.mp4';
      final initBytes = List<int>.generate(100, (i) => i);
      final seg0Bytes = List<int>.generate(200, (i) => 100 + i);

      var failPermanently = true;
      final client = MockClient((request) async {
        if (request.url.path.contains('init')) {
          return http.Response.bytes(initBytes, 200);
        }
        if (request.url.path.contains('seg0')) {
          return http.Response.bytes(seg0Bytes, 200);
        }
        if (request.url.path.contains('seg1')) {
          if (failPermanently) {
            return http.Response('Service Unavailable', 503);
          }
          return http.Response.bytes(List<int>.filled(200, 1), 200);
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

      final streamUrl1 = await TidalStreamProxy.instance.prepareStream(
        trackId: 'fail_track',
        dashInfo: dashInfo,
        targetPath: targetPath1,
        client: client,
        initialRetryDelay: Duration.zero,
      );

      // Request beyond buffered range, pump fails all retries
      final httpClient = HttpClient();
      final req1 = await httpClient.getUrl(Uri.parse(streamUrl1));
      req1.headers.set(HttpHeaders.rangeHeader, 'bytes=300-349');
      final resp1 = await req1.close();
      expect(resp1.statusCode, HttpStatus.serviceUnavailable);

      // Now recovery: prepareStream for same trackId should not reuse dead session
      failPermanently = false;
      final streamUrl2 = await TidalStreamProxy.instance.prepareStream(
        trackId: 'fail_track',
        dashInfo: dashInfo,
        targetPath: targetPath2,
        client: client,
        initialRetryDelay: Duration.zero,
      );

      expect(streamUrl2, isNot(equals(streamUrl1)));

      final req2 = await httpClient.getUrl(Uri.parse(streamUrl2));
      req2.headers.set(HttpHeaders.rangeHeader, 'bytes=300-349');
      final resp2 = await req2.close();
      expect(resp2.statusCode, HttpStatus.partialContent);

      httpClient.close();
    });

    test('range request beyond current bytes returns 503 instead of 416 while downloading', () async {
      final targetPath = '${tempDir.path}/503_test.mp4';
      final initBytes = List<int>.generate(100, (i) => i);
      final seg0Bytes = List<int>.generate(200, (i) => 100 + i);

      // Make seg1 permanently fail so pump halts without finishing the track
      final client = MockClient((request) async {
        if (request.url.path.contains('init')) {
          return http.Response.bytes(initBytes, 200);
        }
        if (request.url.path.contains('seg0')) {
          return http.Response.bytes(seg0Bytes, 200);
        }
        return http.Response('Error', 500);
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
        trackId: 'contract_track',
        dashInfo: dashInfo,
        targetPath: targetPath,
        client: client,
        initialRetryDelay: Duration.zero,
      );

      final httpClient = HttpClient();
      final req = await httpClient.getUrl(Uri.parse(streamUrl));
      // Request bytes far beyond what's written (init + seg0 = 300 bytes)
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=5000-6000');
      final resp = await req.close();

      // Must be 503, NEVER 416 (416 cuts off playback in Rust/Symphonia)
      expect(resp.statusCode, HttpStatus.serviceUnavailable);
      httpClient.close();
    });
  });
}
