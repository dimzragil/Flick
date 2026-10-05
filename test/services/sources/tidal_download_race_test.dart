import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/services/network_cache_service.dart';
import 'package:flick/services/sources/tidal_service.dart';

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
  'expires_at_ms': DateTime.now().add(const Duration(hours: 2)).millisecondsSinceEpoch,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('TidalService download single-flight and cancel handles', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('tidal_download_test');
    });

    tearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    test('single-flights concurrent stream() calls for the same remoteId', () async {
      var cdnRequests = 0;
      final manifest = base64Encode(
        utf8.encode(
          jsonEncode({
            'mimeType': 'audio/flac',
            'codecs': 'flac',
            'encryptionType': 'NONE',
            'urls': ['https://cdn.tidal.com/track/flac/concurrent1'],
          }),
        ),
      );

      final client = MockClient((request) async {
        if (request.url.host == 'cdn.tidal.com') {
          cdnRequests++;
          // Artificial delay to simulate download latency
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return http.Response.bytes([1, 2, 3, 4], 200);
        }
        if (request.url.path.contains('/playbackinfopostpaywall')) {
          return http.Response(
            jsonEncode({
              'manifest': manifest,
              'manifestMimeType': 'application/vnd.tidal.bts',
              'assetPresentation': 'FULL',
            }),
            200,
          );
        }
        return http.Response('', 404);
      });

      final service = TidalService.create(
        client: client,
        networkCache: NetworkCacheService(rootDirectory: tempDir),
      );

      final server = _server(token: _validToken());

      // Trigger two concurrent stream() calls for the same track
      final future1 = service.stream(server, 'track_concurrent_1', extension: 'flac');
      final future2 = service.stream(server, 'track_concurrent_1', extension: 'flac');

      final results = await Future.wait([future1, future2]);

      expect(results[0], results[1]);
      expect(File(results[0]).existsSync(), isTrue);
      // CDN must only have been requested once due to single-flighting
      expect(cdnRequests, 1);
      expect(service.downloadInFlightForTesting, isEmpty);
      expect(service.activeDownloadsForTesting['track_concurrent_1'], isNull);
    });

    test('cancelActiveDownload cancels in-flight download without stranding handles', () async {
      final manifest = base64Encode(
        utf8.encode(
          jsonEncode({
            'mimeType': 'audio/flac',
            'codecs': 'flac',
            'encryptionType': 'NONE',
            'urls': ['https://cdn.tidal.com/track/flac/cancel_test'],
          }),
        ),
      );

      final client = MockClient.streaming((request, bodyStream) async {
        if (request.url.host == 'cdn.tidal.com') {
          // Delayed stream to allow cancellation mid-flight
          final stream = () async* {
            yield [1, 2, 3];
            await Future<void>.delayed(const Duration(milliseconds: 200));
            yield [4, 5, 6];
          }();
          return http.StreamedResponse(stream, 200, contentLength: 6);
        }
        if (request.url.path.contains('/playbackinfopostpaywall')) {
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                jsonEncode({
                  'manifest': manifest,
                  'manifestMimeType': 'application/vnd.tidal.bts',
                  'assetPresentation': 'FULL',
                }),
              ),
            ),
            200,
          );
        }
        return http.StreamedResponse(const Stream.empty(), 404);
      });

      final service = TidalService.create(
        client: client,
        networkCache: NetworkCacheService(rootDirectory: tempDir),
      );

      final server = _server(token: _validToken());

      final downloadFuture = service.stream(server, 'track_to_cancel', extension: 'flac');

      // Wait briefly for download to enter network stream
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(service.activeDownloadsForTesting['track_to_cancel'], isNotNull);
      expect(service.activeDownloadsForTesting['track_to_cancel']!.isNotEmpty, isTrue);

      service.cancelActiveDownload('track_to_cancel');

      expect(service.activeDownloadsForTesting['track_to_cancel'], isNull);
      await expectLater(downloadFuture, throwsA(isA<TidalException>()));
    });
  });
}
