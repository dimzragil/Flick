import 'dart:convert';
import 'dart:io';

import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/services/network_cache_service.dart';
import 'package:flick/services/sources/tidal_service.dart';
import 'package:flick/services/sources/tidal_stream_proxy.dart';
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
      'urls': ['https://cdn.tidal.com/track/flac/reuse-test'],
      'sampleRate': 44100,
      'bitDepth': 16,
    }),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resolved stream reuse', () {
    test(
      'two descriptor passes for one track issue one playbackinfo call',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'tidal_stream_reuse',
        );
        addTearDown(() {
          TidalStreamProxy.instance.cancelAllSessions();
          return tempDir.delete(recursive: true);
        });

        var playbackInfoRequests = 0;
        final client = MockClient((request) async {
          if (request.url.path.contains('/playbackinfopostpaywall')) {
            playbackInfoRequests++;
            return http.Response(
              jsonEncode({
                'manifest': _btsManifest(),
                'manifestMimeType': 'application/vnd.tidal.bts',
                'audioQuality': 'LOSSLESS',
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        });

        final service = TidalService.create(
          client: client,
          networkCache: NetworkCacheService(rootDirectory: tempDir),
        );
        final server = _server(token: _validToken());

        // Catalog hint: start the cascade at LOSSLESS.
        TidalService.makeEphemeralSong(server, {
          'id': 'reuse_track',
          'audioQuality': 'LOSSLESS',
          'duration': 200,
        });

        final first = await service.streamDescriptor(
          server,
          'reuse_track',
          extension: 'flac',
          deferPump: true,
        );
        expect(first, isNotNull);
        expect(playbackInfoRequests, 1);

        // Drop the active local proxy session so the second pass must rely on
        // the resolved-stream cache rather than the activeBtsStreamUrl
        // shortcut.
        TidalStreamProxy.instance.cancelAllSessions();

        final second = await service.streamDescriptor(
          server,
          'reuse_track',
          extension: 'flac',
          deferPump: true,
        );
        expect(second, isNotNull);
        expect(
          playbackInfoRequests,
          1,
          reason:
              'the playback-start pass must reuse the cached resolution '
              'instead of calling playbackinfopostpaywall again',
        );
      },
    );

    test('a changed catalog quality hint invalidates the cache', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'tidal_stream_reuse_tier',
      );
      addTearDown(() {
        TidalStreamProxy.instance.cancelAllSessions();
        return tempDir.delete(recursive: true);
      });

      final requestedTiers = <String>[];
      final client = MockClient((request) async {
        if (request.url.path.contains('/playbackinfopostpaywall')) {
          requestedTiers.add(request.url.queryParameters['audioquality'] ?? '');
          return http.Response(
            jsonEncode({
              'manifest': _btsManifest(),
              'manifestMimeType': 'application/vnd.tidal.bts',
              'audioQuality': request.url.queryParameters['audioquality'],
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });

      final service = TidalService.create(
        client: client,
        networkCache: NetworkCacheService(rootDirectory: tempDir),
      );
      final server = _server(token: _validToken());

      TidalService.makeEphemeralSong(server, {
        'id': 'tier_track',
        'audioQuality': 'LOSSLESS',
        'duration': 200,
      });
      final first = await service.streamDescriptor(
        server,
        'tier_track',
        extension: 'flac',
        deferPump: true,
      );
      expect(first, isNotNull);
      expect(requestedTiers, ['LOSSLESS']);

      TidalStreamProxy.instance.cancelAllSessions();

      TidalService.makeEphemeralSong(server, {
        'id': 'tier_track',
        'audioQuality': 'HI_RES',
        'duration': 200,
      });
      final second = await service.streamDescriptor(
        server,
        'tier_track',
        extension: 'flac',
        deferPump: true,
      );
      expect(second, isNotNull);
      expect(requestedTiers, [
        'LOSSLESS',
        'HI_RES',
      ], reason: 'the cached LOSSLESS stream must not be served for HI_RES');
    });

    test('an expired resolution is fetched again', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'tidal_stream_reuse_ttl',
      );
      addTearDown(() {
        TidalStreamProxy.instance.cancelAllSessions();
        return tempDir.delete(recursive: true);
      });

      var playbackInfoRequests = 0;
      final client = MockClient((request) async {
        if (request.url.path.contains('/playbackinfopostpaywall')) {
          playbackInfoRequests++;
          return http.Response(
            jsonEncode({
              'manifest': _btsManifest(),
              'manifestMimeType': 'application/vnd.tidal.bts',
              'audioQuality': 'LOSSLESS',
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });

      final service = TidalService.create(
        client: client,
        networkCache: NetworkCacheService(rootDirectory: tempDir),
        resolvedStreamTtl: Duration.zero,
      );
      final server = _server(token: _validToken());

      await service.streamDescriptor(
        server,
        'expiring_track',
        extension: 'flac',
        deferPump: true,
      );
      expect(playbackInfoRequests, 1);

      TidalStreamProxy.instance.cancelAllSessions();

      await service.streamDescriptor(
        server,
        'expiring_track',
        extension: 'flac',
        deferPump: true,
      );
      expect(
        playbackInfoRequests,
        2,
        reason: 'a resolution older than the TTL must not be reused',
      );
    });
  });
}
