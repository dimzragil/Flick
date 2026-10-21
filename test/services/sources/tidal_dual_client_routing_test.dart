import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/models/song.dart';
import 'package:flick/features/player/widgets/bit_perfect_indicator.dart';
import 'package:flick/services/network_cache_service.dart';
import 'package:flick/services/sources/tidal_service.dart';

NetworkServerEntity _server({
  int id = 1,
  String token = '',
}) {
  return NetworkServerEntity()
    ..id = id
    ..label = 'Tidal Dual Client Test'
    ..protocol = 'tidal'
    ..baseUrl = TidalService.tidalBaseUrl
    ..token = token;
}

String _tokenWithJwtCid(int cid) {
  final header = base64Url
      .encode(utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'})))
      .replaceAll('=', '');
  final payload = base64Url
      .encode(
        utf8.encode(
          jsonEncode({
            'uid': 123456,
            'cid': cid,
            'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
          }),
        ),
      )
      .replaceAll('=', '');
  final jwt = '$header.$payload.signature';

  return jsonEncode({
    'access_token': jwt,
    'refresh_token': 'refresh_token_xyz',
    'user_id': '123456',
    'country_code': 'US',
    'expires_at_ms': DateTime.now().millisecondsSinceEpoch + 3600000,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TidalService Dual-Client Routing', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('tidal_dual_client_test');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'probes HI_RES via hiRes profile and falls back to LOSSLESS via lossless profile',
      () async {
        final probedProfiles = <String>[];
        final probedTiers = <String>[];

        final client = MockClient((request) async {
          if (request.url.path.contains('/oauth2/token')) {
            final body = request.body;
            if (body.contains('client_id=${TidalService.losslessClientId}')) {
              return http.Response(
                jsonEncode({
                  'access_token': _tokenWithJwtCid(6432),
                  'refresh_token': 'new_refresh_lossless',
                  'expires_in': 3600,
                }),
                200,
              );
            }
            if (body.contains('client_id=${TidalService.hiResClientId}')) {
              return http.Response(
                jsonEncode({
                  'access_token': _tokenWithJwtCid(13319),
                  'refresh_token': 'new_refresh_hires',
                  'expires_in': 3600,
                }),
                200,
              );
            }
          }

          if (request.url.path.contains('test_cd.flac')) {
            return http.Response('dummy_flac_audio_bytes', 200, headers: {
              'content-length': '22',
              'accept-ranges': 'bytes',
            });
          }

          if (request.url.path.contains('/playbackinfopostpaywall')) {
            final quality = request.url.queryParameters['audioquality'];
            final authHeader = request.headers['Authorization'] ?? '';
            probedTiers.add(quality ?? '');

            if (authHeader.isNotEmpty) {
              probedProfiles.add(quality ?? '');
            }

            // Simulate track having NO Hi-Res Master (returns 404 on HI_RES_LOSSLESS and HI_RES)
            if (quality == 'HI_RES_LOSSLESS' || quality == 'HI_RES') {
              return http.Response(
                jsonEncode({
                  'status': 404,
                  'userMessage': 'Not available in Hi-Res',
                }),
                404,
              );
            }

            // On LOSSLESS tier, return genuine unencrypted BTS FLAC (from 4N3n client)
            if (quality == 'LOSSLESS') {
              final btsManifest = jsonEncode({
                'mimeType': 'audio/flac',
                'codecs': 'flac',
                'encryptionType': 'NONE',
                'urls': ['https://audio.tidal.com/test_cd.flac'],
                'sampleRate': 44100,
                'bitDepth': 16,
                'bitRate': 1061000,
              });
              return http.Response(
                jsonEncode({
                  'manifest': base64Encode(utf8.encode(btsManifest)),
                  'manifestMimeType': 'application/vnd.tidal.bts',
                  'audioQuality': 'LOSSLESS',
                  'sampleRate': 44100,
                  'bitDepth': 16,
                }),
                200,
              );
            }
          }

          return http.Response('Not Found', 404);
        });

        final service = TidalService.create(
          client: client,
          networkCache: NetworkCacheService(rootDirectory: tempDir),
        );

        // Start with server having an existing token from fX2J (cid: 13319)
        final server = _server(token: _tokenWithJwtCid(13319));

        final desc = await service.streamDescriptor(server, '246452124');
        expect(desc, isNotNull);

        // Probes should have cascaded through HI_RES_LOSSLESS -> HI_RES -> LOSSLESS
        expect(probedTiers, contains('HI_RES_LOSSLESS'));
        expect(probedTiers, contains('LOSSLESS'));

        // The resolved stream must be 16-bit FLAC CD Quality
        final resolved = service.getResolvedStream('246452124');
        expect(resolved, isNotNull);
        expect(resolved!.codec, 'flac');
        expect(resolved.ext, 'flac');
        expect(resolved.bitDepth, 16);
        expect(resolved.sampleRate, 44100);
        expect(resolved.isLossy, isFalse);

        // Badge in Flick player indicator must resolve to 'CD'
        final song = Song(
          id: 'tidal_1_246452124',
          title: 'Heavenward',
          artist: 'Asunojokei',
          album: 'Island',
          duration: const Duration(minutes: 4),
          filePath: 'tidal://1/246452124',
          sourceType: 'tidal',
          fileType: 'flac',
          bitDepth: 16,
          sampleRate: 44100,
        );

        final qualityBadge = BitPerfectIndicator.getSongQuality(song, resolved);
        expect(qualityBadge, 'CD');
      },
    );

    test(
      'probes HI_RES via hiRes profile and yields HR 24-bit DASH FLAC when available',
      () async {
        const mpdXml = '''<?xml version="1.0" encoding="utf-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011">
  <Period>
    <AdaptationSet mimeType="audio/mp4" codecs="flac">
      <Representation id="rep1" audioSamplingRate="96000" bandwidth="2000000">
        <SegmentTemplate initialization="https://cdn.tidal.com/init.mp4" media="https://cdn.tidal.com/seg_\$Number\$.mp4" startNumber="1">
          <SegmentTimeline><S d="1000" r="1" /></SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>''';

        final client = MockClient((request) async {
          if (request.url.path.contains('/oauth2/token')) {
            return http.Response(
              jsonEncode({
                'access_token': _tokenWithJwtCid(13319),
                'refresh_token': 'new_refresh_hires',
                'expires_in': 3600,
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/init.mp4')) {
            return http.Response.bytes([1, 2, 3, 4], 200);
          }
          if (request.url.path.contains('/seg_')) {
            return http.Response.bytes([5, 6, 7, 8], 200);
          }
          if (request.url.path.contains('/playbackinfopostpaywall')) {
            final quality = request.url.queryParameters['audioquality'];
            if (quality == 'HI_RES_LOSSLESS') {
              return http.Response(
                jsonEncode({
                  'manifest': base64Encode(utf8.encode(mpdXml)),
                  'manifestMimeType': 'application/dash+xml',
                  'audioQuality': 'HI_RES_LOSSLESS',
                  'sampleRate': 96000,
                  'bitDepth': 24,
                }),
                200,
              );
            }
          }
          return http.Response('Not Found', 404);
        });

        final service = TidalService.create(
          client: client,
          networkCache: NetworkCacheService(rootDirectory: tempDir),
        );

        final server = _server(token: _tokenWithJwtCid(13319));
        final desc = await service.streamDescriptor(server, '19823990');
        expect(desc, isNotNull);

        final resolved = service.getResolvedStream('19823990');
        expect(resolved, isNotNull);
        expect(resolved!.isDash, isTrue);
        expect(resolved.bitDepth, 24);
        expect(resolved.sampleRate, 96000);
        expect(resolved.codec, 'flac');
        expect(resolved.isLossy, isFalse);

        final song = Song(
          id: 'tidal_1_19823990',
          title: 'Get Lucky',
          artist: 'Daft Punk',
          album: 'Random Access Memories',
          duration: const Duration(minutes: 4),
          filePath: 'tidal://1/19823990',
          sourceType: 'tidal',
          fileType: 'flac',
          bitDepth: 24,
          sampleRate: 96000,
        );

        final qualityBadge = BitPerfectIndicator.getSongQuality(song, resolved);
        expect(qualityBadge, 'HR');
      },
    );
  });
}
