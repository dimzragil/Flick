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
    ..id = 42
    ..label = 'Tidal'
    ..protocol = 'tidal'
    ..baseUrl = TidalService.tidalBaseUrl
    ..username = null
    ..token = token;
}

String _validToken() => jsonEncode({
  'access_token': 'acc-atmos-test',
  'refresh_token': 'ref-atmos-test',
  'user_id': 'user-atmos',
  'country_code': 'US',
  'expires_at_ms': DateTime.now()
      .add(const Duration(hours: 1))
      .millisecondsSinceEpoch,
});

String _atmosBtsManifest() => base64Encode(
  utf8.encode(
    jsonEncode({
      'mimeType': 'audio/mp4',
      'codecs': 'ec-3',
      'encryptionType': 'NONE',
      'urls': ['https://cdn.tidal.com/track/atmos/sample.mp4'],
      'sampleRate': 48000,
      'bitDepth': 16,
      'bitRate': 448000,
    }),
  ),
);

String _stereoLosslessBtsManifest() => base64Encode(
  utf8.encode(
    jsonEncode({
      'mimeType': 'audio/flac',
      'codecs': 'flac',
      'encryptionType': 'NONE',
      'urls': ['https://cdn.tidal.com/track/flac/stereo.flac'],
      'sampleRate': 44100,
      'bitDepth': 16,
    }),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Dolby Atmos codec normalization & model properties', () {
    test('TidalStreamResolution.isDolbyAtmos returns true for atmos codecs', () {
      const res1 = TidalStreamResolution(
        url: 'https://test',
        isDash: false,
        sampleRate: 48000,
        bitDepth: 16,
        audioQuality: 'DOLBY_ATMOS',
        codec: 'eac3_joc',
      );
      expect(res1.isDolbyAtmos, isTrue);

      const res2 = TidalStreamResolution(
        url: 'https://test',
        isDash: false,
        sampleRate: 48000,
        bitDepth: 16,
        audioQuality: 'HIGH',
        codec: 'ec-3',
      );
      expect(res2.isDolbyAtmos, isTrue);

      const resStereo = TidalStreamResolution(
        url: 'https://test',
        isDash: false,
        sampleRate: 44100,
        bitDepth: 16,
        audioQuality: 'LOSSLESS',
        codec: 'flac',
      );
      expect(resStereo.isDolbyAtmos, isFalse);
    });

    test('normalizeCodec detects Atmos EAC-3 variants', () {
      expect(TidalService.normalizeCodec('eac3_joc', null), 'eac3_joc');
      expect(TidalService.normalizeCodec('ec-3', null), 'eac3_joc');
      expect(TidalService.normalizeCodec('eac3', null), 'eac3_joc');
      expect(TidalService.normalizeCodec(null, 'audio/eac3-joc'), 'eac3_joc');
      expect(TidalService.normalizeCodec(null, 'audio/ec-3'), 'eac3_joc');
      expect(TidalService.normalizeCodec('flac', null), 'flac');
    });
  });

  group('Dolby Atmos Cascade & Bit-Perfect USB DAC Mode', () {
    late Directory tempDir;
    late NetworkCacheService cache;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('tidal_atmos_test');
      cache = NetworkCacheService(rootDirectory: tempDir);
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('when allowDolbyAtmos is true, requests DOLBY_ATMOS first and resolves Atmos stream', () async {
      final requestedTiers = <String>[];
      final client = MockClient((request) async {
        if (request.url.path.contains('/playbackinfopostpaywall')) {
          final tier = request.url.queryParameters['audioquality'] ?? '';
          requestedTiers.add(tier);
          if (tier == 'DOLBY_ATMOS') {
            return http.Response(
              jsonEncode({
                'manifest': _atmosBtsManifest(),
                'manifestMimeType': 'application/vnd.tidal.bts',
                'audioQuality': 'DOLBY_ATMOS',
                'codec': 'ec-3',
              }),
              200,
            );
          }
        }
        return http.Response('{"error": "Not found"}', 404);
      });

      final service = TidalService.create(client: client, networkCache: cache);
      final server = _server(token: _validToken());

      final res = await service.streamDescriptor(
        server,
        'track-atmos-101',
        allowDolbyAtmos: true,
      );

      expect(res, isNotNull);
      expect(requestedTiers.first, 'DOLBY_ATMOS');
      final resolved = service.getResolvedStream('track-atmos-101');
      expect(resolved, isNotNull);
      expect(resolved!.isDolbyAtmos, isTrue);
      expect(resolved.codec, 'eac3_joc');
      expect(resolved.audioQuality, 'DOLBY_ATMOS');
    });

    test('when Atmos returns 404, cascade seamlessly falls back to Lossless Stereo', () async {
      final requestedTiers = <String>[];
      final client = MockClient((request) async {
        if (request.url.path.contains('/playbackinfopostpaywall')) {
          final tier = request.url.queryParameters['audioquality'] ?? '';
          requestedTiers.add(tier);
          if (tier == 'DOLBY_ATMOS') {
            return http.Response('{"error": "Atmos not available"}', 404);
          }
          if (tier == 'LOSSLESS') {
            return http.Response(
              jsonEncode({
                'manifest': _stereoLosslessBtsManifest(),
                'manifestMimeType': 'application/vnd.tidal.bts',
                'audioQuality': 'LOSSLESS',
                'codec': 'flac',
              }),
              200,
            );
          }
        }
        return http.Response('{"error": "Not found"}', 404);
      });

      final service = TidalService.create(client: client, networkCache: cache);
      final server = _server(token: _validToken());

      final res = await service.streamDescriptor(
        server,
        'track-fallback-102',
        allowDolbyAtmos: true,
      );

      expect(res, isNotNull);
      // Verify cascade order started with DOLBY_ATMOS and fell through to LOSSLESS
      expect(requestedTiers.contains('DOLBY_ATMOS'), isTrue);
      expect(requestedTiers.contains('LOSSLESS'), isTrue);

      final resolved = service.getResolvedStream('track-fallback-102');
      expect(resolved, isNotNull);
      expect(resolved!.isDolbyAtmos, isFalse);
      expect(resolved.audioQuality, 'LOSSLESS');
      expect(resolved.codec, 'flac');
    });

    test('when allowDolbyAtmos is false (Bit-Perfect USB DAC Mode), Atmos is completely bypassed', () async {
      final requestedTiers = <String>[];
      final client = MockClient((request) async {
        if (request.url.path.contains('/playbackinfopostpaywall')) {
          final tier = request.url.queryParameters['audioquality'] ?? '';
          requestedTiers.add(tier);
          if (tier == 'HI_RES_LOSSLESS') {
            return http.Response(
              jsonEncode({
                'manifest': _stereoLosslessBtsManifest(),
                'manifestMimeType': 'application/vnd.tidal.bts',
                'audioQuality': 'HI_RES_LOSSLESS',
                'codec': 'flac',
                'bitDepth': 24,
                'sampleRate': 96000,
              }),
              200,
            );
          }
        }
        return http.Response('{"error": "Not found"}', 404);
      });

      final service = TidalService.create(client: client, networkCache: cache);
      final server = _server(token: _validToken());

      final res = await service.streamDescriptor(
        server,
        'track-bitperfect-103',
        allowDolbyAtmos: false,
      );

      expect(res, isNotNull);
      // DOLBY_ATMOS must NOT have been requested at all
      expect(requestedTiers.contains('DOLBY_ATMOS'), isFalse);
      expect(requestedTiers.first, 'HI_RES_LOSSLESS');

      final resolved = service.getResolvedStream('track-bitperfect-103');
      expect(resolved, isNotNull);
      expect(resolved!.isDolbyAtmos, isFalse);
      expect(resolved.codec, 'flac');
    });

    test('cached Atmos stream is rejected and evicted when re-requested with allowDolbyAtmos: false', () async {
      var callCount = 0;
      final requestedTiers = <String>[];
      final client = MockClient((request) async {
        if (request.url.path.contains('/playbackinfopostpaywall')) {
          callCount++;
          final tier = request.url.queryParameters['audioquality'] ?? '';
          requestedTiers.add(tier);
          if (tier == 'DOLBY_ATMOS') {
            return http.Response(
              jsonEncode({
                'manifest': _atmosBtsManifest(),
                'manifestMimeType': 'application/vnd.tidal.bts',
                'audioQuality': 'DOLBY_ATMOS',
                'codec': 'ec-3',
              }),
              200,
            );
          }
          if (tier == 'HI_RES_LOSSLESS') {
            return http.Response(
              jsonEncode({
                'manifest': _stereoLosslessBtsManifest(),
                'manifestMimeType': 'application/vnd.tidal.bts',
                'audioQuality': 'HI_RES_LOSSLESS',
                'codec': 'flac',
              }),
              200,
            );
          }
        }
        return http.Response('{"error": "Not found"}', 404);
      });

      final service = TidalService.create(client: client, networkCache: cache);
      final server = _server(token: _validToken());

      // 1. First play on phone speaker (allowDolbyAtmos: true)
      await service.streamDescriptor(
        server,
        'track-switch-104',
        allowDolbyAtmos: true,
      );
      expect(service.getResolvedStream('track-switch-104')?.isDolbyAtmos, isTrue);

      // 2. User plugs in USB DAC -> Bit-Perfect mode activates (allowDolbyAtmos: false)
      await service.streamDescriptor(
        server,
        'track-switch-104',
        allowDolbyAtmos: false,
      );

      // Verify that the cached Atmos resolution was NOT reused, and a new request was made
      expect(callCount, 2);
      expect(requestedTiers[1], 'HI_RES_LOSSLESS');
      expect(service.getResolvedStream('track-switch-104')?.isDolbyAtmos, isFalse);
      expect(service.getResolvedStream('track-switch-104')?.codec, 'flac');
    });
  });
}
