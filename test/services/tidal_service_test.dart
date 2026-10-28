import 'dart:convert';
import 'dart:io';

import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/models/playback_context.dart';
import 'package:flick/services/network_cache_service.dart';
import 'package:flick/services/sources/dash_direct_delivery.dart';
import 'package:flick/services/sources/tidal_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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

/// A far-future token blob so [TidalService._ensureValidToken] skips refresh
/// (and therefore skips the DB write inside [_persist]).
String _validToken() => jsonEncode({
  'access_token': 'acc-xyz',
  'refresh_token': 'ref-xyz',
  'user_id': 'user-1',
  'country_code': 'NO',
  'expires_at_ms': DateTime.now()
      .add(const Duration(hours: 1))
      .millisecondsSinceEpoch,
});

const String _simpleDashMpdXml = '''<?xml version="1.0" encoding="utf-8"?>
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

String _simpleDashMpd() => _simpleDashMpdXml;

/// A `vnd.tidal.bts` manifest pointing at a direct CDN FLAC URL.
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

/// A TidalService whose playbackinfo always answers with [mpdXml].
Future<({TidalService service, Directory dir})> _dashService({
  required String mpdXml,
  int? apiBitDepth = 16,
  String audioQuality = 'HI_RES_LOSSLESS',
}) async {
  final dir = await Directory.systemTemp.createTemp('tidal_dash_depth');
  final manifest = base64Encode(utf8.encode(mpdXml));
  final client = MockClient((request) async {
    return http.Response(
      jsonEncode({
        'manifest': manifest,
        'manifestMimeType': 'application/dash+xml',
        'audioQuality': audioQuality,
        'bitDepth': ?apiBitDepth,
      }),
      200,
    );
  });
  final service = TidalService.create(
    client: client,
    networkCache: NetworkCacheService(rootDirectory: dir),
  );
  service.useDashManifestStoreForTesting(
    DashManifestStore(rootDirectory: Directory('${dir.path}/mpd')),
  );
  return (service: service, dir: dir);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    FlutterSecureStorage.setMockInitialValues({});
  });
  group('buildSongEntity', () {
    test(
      'maps a Tidal track to a SongEntity with tidal:// path + cover marker',
      () {
        final server = _server();
        final track = {
          'id': 1234567,
          'title': 'Nightcall',
          'duration': 250,
          'trackNumber': 1,
          'volumeNumber': 1,
          'artists': [
            {'name': 'Kavinsky'},
          ],
          'album': {
            'title': 'OutRun',
            'releaseDate': '2013-02-25',
            'cover': '1bce0bf4-a3b9-4c0a-9f2e-1234567890ab',
            'artist': {'name': 'Kavinsky'},
          },
          'audioQuality': 'LOSSLESS',
        };

        final entity = TidalService.buildSongEntity(server, track);

        expect(entity, isNotNull);
        expect(entity!.filePath, 'tidal://9/1234567');
        expect(entity.title, 'Nightcall');
        expect(entity.artist, 'Kavinsky');
        expect(entity.album, 'OutRun');
        expect(entity.albumArtist, 'Kavinsky');
        expect(entity.durationMs, 250000); // seconds -> milliseconds
        expect(entity.trackNumber, 1);
        expect(entity.discNumber, 1);
        expect(entity.year, 2013);
        expect(entity.fileType, 'flac');
        expect(
          entity.albumArtPath,
          'tidal-cover://1bce0bf4-a3b9-4c0a-9f2e-1234567890ab',
        );
        expect(entity.sourceType, 'tidal');
        expect(entity.remoteId, '1234567');
        expect(entity.remoteServerId, 9);
      },
    );

    test('returns null when the track has no id', () {
      expect(TidalService.buildSongEntity(_server(), {'title': 'x'}), isNull);
    });
  });

  group('coverUrl', () {
    test('slashes the uuid into a resources.tidal.com jpg', () {
      final url = TidalService.coverUrl(
        '1bce0bf4-a3b9-4c0a-9f2e-1234567890ab',
        size: 640,
      );
      expect(
        url,
        'https://resources.tidal.com/images/1bce0bf4/a3b9/4c0a/9f2e/1234567890ab/640x640.jpg',
      );
    });

    test('returns empty for a too-short id', () {
      expect(TidalService.coverUrl('ab'), '');
    });

    test('returns empty for nil UUID', () {
      expect(TidalService.coverUrl('00000000-0000-0000-0000-000000000000'), '');
      expect(TidalService.coverUrl('00000000000000000000000000000000'), '');
    });
  });

  group('artistPictureUrl', () {
    test('maps requested size to supported CDN dimensions avoiding 640x640 403', () {
      const uuid = '04d63cd8-a1a5-42e0-b1ec-8e336b7d9200';
      expect(
        TidalService.artistPictureUrl(uuid, size: 160),
        'https://resources.tidal.com/images/04d63cd8/a1a5/42e0/b1ec/8e336b7d9200/160x160.jpg',
      );
      expect(
        TidalService.artistPictureUrl(uuid, size: 320),
        'https://resources.tidal.com/images/04d63cd8/a1a5/42e0/b1ec/8e336b7d9200/320x320.jpg',
      );
      // Sizes above 320 (such as 640) safely map to 750 rather than doomed 640:
      expect(
        TidalService.artistPictureUrl(uuid, size: 640),
        'https://resources.tidal.com/images/04d63cd8/a1a5/42e0/b1ec/8e336b7d9200/750x750.jpg',
      );
      expect(
        TidalService.artistPictureUrl(uuid, size: 750),
        'https://resources.tidal.com/images/04d63cd8/a1a5/42e0/b1ec/8e336b7d9200/750x750.jpg',
      );
    });

    test('returns empty for invalid or empty UUID', () {
      expect(TidalService.artistPictureUrl(''), '');
      expect(TidalService.artistPictureUrl('ab'), '');
    });
  });

  group('extractPlaylistCover', () {
    test('extracts direct cover UUID', () {
      final pl = {'cover': '1bce0bf4-a3b9-4c0a-9f2e-1234567890ab'};
      final url = TidalService.extractPlaylistCover(pl, size: 640);
      expect(
        url,
        'https://resources.tidal.com/images/1bce0bf4/a3b9/4c0a/9f2e/1234567890ab/640x640.jpg',
      );
    });

    test('prioritizes squareImage over wide image when both are present', () {
      final pl = {
        'squareImage': '59a2c0e0-625a-493a-9e7f-0e5f51a16a50',
        'image': '6aedd9bd-d973-4203-a584-71a652d84399',
      };
      final url = TidalService.extractPlaylistCover(pl, size: 320);
      expect(
        url,
        'https://resources.tidal.com/images/59a2c0e0/625a/493a/9e7f/0e5f51a16a50/320x320.jpg',
      );
    });

    test(
      'formats wide image with 3:2 aspect ratio when only image is present',
      () {
        final pl = {'image': '6aedd9bd-d973-4203-a584-71a652d84399'};
        final url = TidalService.extractPlaylistCover(pl, size: 320);
        expect(
          url,
          'https://resources.tidal.com/images/6aedd9bd/d973/4203/a584/71a652d84399/640x428.jpg',
        );
      },
    );

    test('returns direct HTTP url if provided', () {
      final pl = {'cover': 'https://example.com/cover.jpg'};
      expect(
        TidalService.extractPlaylistCover(pl),
        'https://example.com/cover.jpg',
      );
    });

    test('extracts from images map or list', () {
      final plMap = {
        'images': {
          'LARGE': {'url': 'https://cdn.tidal.com/large.jpg'},
        },
      };
      expect(
        TidalService.extractPlaylistCover(plMap),
        'https://cdn.tidal.com/large.jpg',
      );

      final plList = {
        'images': [
          {'url': 'https://cdn.tidal.com/list.jpg'},
        ],
      };
      expect(
        TidalService.extractPlaylistCover(plList),
        'https://cdn.tidal.com/list.jpg',
      );
    });

    test(
      'resizedCoverUrl preserves 3:2 aspect ratio for wide landscape images',
      () {
        const wideUrl =
            'https://resources.tidal.com/images/6aedd9bd/d973/4203/a584/71a652d84399/480x320.jpg';
        final resized = TidalService.resizedCoverUrl(wideUrl, 160);
        expect(
          resized,
          'https://resources.tidal.com/images/6aedd9bd/d973/4203/a584/71a652d84399/320x214.jpg',
        );
      },
    );

    test('returns null when no cover is present', () {
      final pl = {'title': 'My Empty Playlist'};
      expect(TidalService.extractPlaylistCover(pl), isNull);
    });
  });

  group('extFromMime', () {
    test('maps flac / m4a / mp3', () {
      expect(TidalService.extFromMime('audio/flac'), 'flac');
      expect(TidalService.extFromMime('audio/mp4'), 'm4a');
      expect(TidalService.extFromMime('audio/mpeg'), 'mp3');
      expect(TidalService.extFromMime('audio/atmos'), isNull);
    });
  });

  group('resolveToken (device flow)', () {
    test(
      'posts device_authorization, opens browser, polls until access_token',
      () async {
        var tokenCalls = 0;
        Uri? openedUrl;
        final client = MockClient((request) async {
          if (request.url.path.endsWith('/device_authorization')) {
            return http.Response(
              jsonEncode({
                'deviceCode': 'dev-1',
                'userCode': 'AB12CD',
                'verificationUriComplete':
                    'https://tidal.com/activate?code=AB12CD',
                'interval': 0,
                'expiresIn': 60,
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/sessions')) {
            return http.Response(
              jsonEncode({'userId': 'user-1', 'countryCode': 'NO'}),
              200,
            );
          }
          if (request.url.path.endsWith('/token')) {
            tokenCalls++;
            if (tokenCalls == 1) {
              // Still waiting for the user to authorize.
              return http.Response(
                jsonEncode({'error': 'authorization_pending'}),
                400,
              );
            }
            return http.Response(
              jsonEncode({
                'access_token': 'acc-1',
                'refresh_token': 'ref-1',
                'expires_in': 3600,
              }),
              200,
            );
          }
          return http.Response('', 404);
        });

        final service = TidalService.create(
          client: client,
          urlOpener: (url) async {
            openedUrl = url;
            return true;
          },
        );

        final token = await service.resolveToken(_server(), '');

        expect(token, isNotNull);
        final decoded = jsonDecode(token!) as Map<String, dynamic>;
        expect(decoded['access_token'], 'acc-1');
        expect(decoded['refresh_token'], 'ref-1');
        expect(decoded['user_id'], 'user-1');
        expect(openedUrl?.toString(), 'https://tidal.com/activate?code=AB12CD');
        expect(tokenCalls, 2);
      },
    );

    test('throws when the browser cannot open', () async {
      final client = MockClient(
        (request) async => http.Response(
          jsonEncode({
            'deviceCode': 'dev-1',
            'verificationUriComplete': 'https://tidal.com/activate',
            'interval': 0,
            'expiresIn': 60,
          }),
          200,
        ),
      );
      final service = TidalService.create(
        client: client,
        urlOpener: (_) async => false,
      );
      expect(
        () => service.resolveToken(_server(), ''),
        throwsA(isA<TidalException>()),
      );
    });

    test(
      'catches a launcher exception and surfaces the link (not the crash)',
      () async {
        final client = MockClient(
          (request) async => http.Response(
            jsonEncode({
              'deviceCode': 'dev-1',
              'verificationUriComplete': 'https://link.tidal.com/AB12CD',
              'interval': 0,
              'expiresIn': 60,
            }),
            200,
          ),
        );
        // The launcher throws (e.g. Android ACTIVITY_NOT_FOUND PlatformException).
        final service = TidalService.create(
          client: client,
          urlOpener: (_) async => throw Exception('ACTIVITY_NOT_FOUND'),
        );

        String? message;
        try {
          await service.resolveToken(_server(), '');
        } on TidalException catch (e) {
          message = e.message;
        }

        expect(message, isNotNull);
        expect(message, contains('https://link.tidal.com/AB12CD'));
        expect(message!.contains('ACTIVITY_NOT_FOUND'), isFalse);
      },
    );

    test(
      'signIn keeps polling after launch failure and reports the link',
      () async {
        var tokenCalls = 0;
        String? reportedLink;
        final client = MockClient((request) async {
          if (request.url.path.endsWith('/device_authorization')) {
            return http.Response(
              jsonEncode({
                'deviceCode': 'dev-1',
                'verificationUriComplete': 'https://link.tidal.com/ZZ',
                'interval': 0,
                'expiresIn': 60,
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/sessions')) {
            return http.Response(
              jsonEncode({'userId': 'u', 'countryCode': 'US'}),
              200,
            );
          }
          if (request.url.path.endsWith('/token')) {
            tokenCalls++;
            if (tokenCalls == 1) {
              return http.Response(
                jsonEncode({'error': 'authorization_pending'}),
                400,
              );
            }
            return http.Response(
              jsonEncode({
                'access_token': 'a',
                'refresh_token': 'r',
                'expires_in': 3600,
              }),
              200,
            );
          }
          return http.Response('', 404);
        });
        final service = TidalService.create(
          client: client,
          urlOpener: (_) async => throw Exception('ACTIVITY_NOT_FOUND'),
        );

        final token = await service.signIn(
          onVerificationLink: (uri) => reportedLink = uri,
        );

        expect(reportedLink, 'https://link.tidal.com/ZZ');
        expect(tokenCalls, 2); // one pending, then success
        final decoded = jsonDecode(token!) as Map<String, dynamic>;
        expect(decoded['access_token'], 'a');
      },
    );

    test('shows a friendly error (no raw body/URL) on invalid_client', () async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/device_authorization')) {
          return http.Response(
            jsonEncode({
              'error': 'invalid_client',
              'error_description': 'Invalid client id',
            }),
            401,
          );
        }
        return http.Response('', 404);
      });
      final service = TidalService.create(
        client: client,
        urlOpener: (_) async => true,
      );

      String? message;
      try {
        await service.resolveToken(_server(), '');
      } on TidalException catch (e) {
        message = e.message;
      }

      expect(message, isNotNull);
      expect(message, contains('rejected'));
      // The raw OAuth error code + endpoint must NOT leak into the UI message.
      expect(message!.contains('invalid_client'), isFalse);
      expect(message.contains('POST http'), isFalse);
      expect(message.contains('auth.tidal.com'), isFalse);
    });
  });

  group('streamDescriptor', () {
    test(
      'decodes a NONE-encryption BTS manifest to the direct CDN URL',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('tidal_bts_test');
        addTearDown(() => tempDir.delete(recursive: true));
        final manifest = base64Encode(
          utf8.encode(
            jsonEncode({
              'mimeType': 'audio/flac',
              'codecs': 'flac',
              'encryptionType': 'NONE',
              'urls': ['https://cdn.tidal.com/track/flac/abc'],
            }),
          ),
        );
        var playbackInfoRequests = 0;
        final client = MockClient((request) async {
          if (request.url.host == 'cdn.tidal.com') {
            return http.Response.bytes([1, 2, 3], 200);
          }
          playbackInfoRequests++;
          expect(request.url.path, contains('/playbackinfopostpaywall'));
          expect(request.headers['Authorization'], 'Bearer acc-xyz');
          return http.Response(
            jsonEncode({
              'manifest': manifest,
              'manifestMimeType': 'application/vnd.tidal.bts',
              'assetPresentation': 'FULL',
            }),
            200,
          );
        });
        final service = TidalService.create(
          client: client,
          networkCache: NetworkCacheService(rootDirectory: tempDir),
        );

        final desc = await service.streamDescriptor(
          _server(token: _validToken()),
          '1234567',
        );

        expect(desc, isNotNull);
        expect(desc!.url, 'https://cdn.tidal.com/track/flac/abc');
        expect(desc.url, isNot(contains('127.0.0.1')));
        // Sample rate and bit depth omitted from manifest -> headers must be omitted to let probe win
        expect(desc.headers['x-flick-sample-rate'], isNull);
        expect(desc.headers['x-flick-bit-depth'], isNull);
        final secondDescriptor = await service.streamDescriptor(
          _server(token: _validToken()),
          '1234567',
          extension: 'flac',
        );
        expect(playbackInfoRequests, 1);
        expect(
          secondDescriptor == null || secondDescriptor.url == desc.url,
          isTrue,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
      },
    );

    test(
      'includes x-flick-sample-rate and x-flick-bit-depth headers when explicitly provided',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'tidal_bts_explicit_test',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final manifest = base64Encode(
          utf8.encode(
            jsonEncode({
              'mimeType': 'audio/flac',
              'codecs': 'flac',
              'encryptionType': 'NONE',
              'urls': ['https://cdn.tidal.com/track/flac/xyz'],
              'sampleRate': 96000,
              'bitDepth': 24,
            }),
          ),
        );
        final client = MockClient((request) async {
          if (request.url.host == 'cdn.tidal.com') {
            return http.Response.bytes([1, 2, 3], 200);
          }
          return http.Response(
            jsonEncode({
              'manifest': manifest,
              'manifestMimeType': 'application/vnd.tidal.bts',
              'assetPresentation': 'FULL',
            }),
            200,
          );
        });
        final service = TidalService.create(
          client: client,
          networkCache: NetworkCacheService(rootDirectory: tempDir),
        );

        final desc = await service.streamDescriptor(
          _server(token: _validToken()),
          '7654321',
        );

        expect(desc, isNotNull);
        expect(desc!.headers['x-flick-sample-rate'], '96000');
        expect(desc.headers['x-flick-bit-depth'], '24');
        expect(desc.headers['x-flick-extension-hint'], 'flac');
      },
    );

    test('throws a clear error for encrypted (MQA/HiRes) content', () async {
      final manifest = base64Encode(
        utf8.encode(
          jsonEncode({
            'mimeType': 'audio/flac',
            'encryptionType': 'OLD',
            'keyId': 'k1',
            'urls': ['https://cdn.tidal.com/enc'],
          }),
        ),
      );
      final client = MockClient(
        (request) async => http.Response(
          jsonEncode({
            'manifest': manifest,
            'manifestMimeType': 'application/vnd.tidal.bts',
          }),
          200,
        ),
      );
      final service = TidalService.create(client: client);

      expect(
        () => service.streamDescriptor(_server(token: _validToken()), '1'),
        throwsA(isA<TidalException>()),
      );
    });

    test(
      'writes a single-representation .mpd for direct DASH playback',
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
        final manifest = base64Encode(utf8.encode(mpdXml));
        final client = MockClient((request) async {
          return http.Response(
            jsonEncode({
              'manifest': manifest,
              'manifestMimeType': 'application/dash+xml',
              'audioQuality': 'HI_RES_LOSSLESS',
            }),
            200,
          );
        });
        final tempDir = await Directory.systemTemp.createTemp(
          'tidal_dash_test',
        );
        addTearDown(() => tempDir.deleteSync(recursive: true));
        final service = TidalService.create(
          client: client,
          networkCache: NetworkCacheService(rootDirectory: tempDir),
        );
        service.useDashManifestStoreForTesting(
          DashManifestStore(rootDirectory: Directory('${tempDir.path}/mpd')),
        );
        final desc = await service.streamDescriptor(
          _server(token: _validToken()),
          'hires_track_1',
        );
        expect(desc, isNotNull);
        expect(desc!.url, startsWith('file://'));
        expect(desc.url, endsWith('.mpd'));
        expect(desc.headers['x-flick-sample-rate'], '96000');
        expect(
          desc.headers.containsKey('x-flick-bit-depth'),
          isFalse,
          reason: 'the MPD carries no bit depth; nothing may claim one',
        );

        final written = File(
          Uri.parse(desc.url).toFilePath(),
        ).readAsStringSync();
        expect(
          RegExp('<Representation').allMatches(written).length,
          1,
          reason: 'a multi-representation MPD would let ABR downshift silently',
        );
        expect(written, contains('SegmentTimeline'));
        expect(written, contains(r'seg_$Number$.mp4'));
        expect(written, contains('https://cdn.tidal.com/init.mp4'));
      },
    );

    test('BTS descriptor is the raw CDN URL — no loopback proxy hop', () async {
      final tempDir = await Directory.systemTemp.createTemp('tidal_bts_dir');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'manifest': _btsManifest(),
            'manifestMimeType': 'application/vnd.tidal.bts',
            'audioQuality': 'LOSSLESS',
          }),
          200,
        );
      });
      final service = TidalService.create(
        client: client,
        networkCache: NetworkCacheService(rootDirectory: tempDir),
      );
      final desc = await service.streamDescriptor(
        _server(token: _validToken()),
        'bts_track',
      );
      expect(desc, isNotNull);
      expect(desc!.url, 'https://cdn.tidal.com/track/flac/reuse-test');
      expect(desc.url, isNot(contains('127.0.0.1')));
      expect(desc.headers['x-flick-sample-rate'], '44100');
      expect(desc.headers['x-flick-bit-depth'], '16');
      expect(desc.headers['x-flick-extension-hint'], 'flac');
    });

    test('builds a dash:// segment plan for the Rust engine', () async {
      final built = await _dashService(mpdXml: _simpleDashMpd());
      addTearDown(() => built.dir.deleteSync(recursive: true));
      await built.service.streamDescriptor(
        _server(token: _validToken()),
        'plan_track',
      );

      final plan = built.service.directDashPlan('plan_track');
      expect(plan, isNotNull);
      expect(plan!.url, 'dash://plan_track');
      expect(
        plan.headers['x-flick-dash-init'],
        'https://cdn.tidal.com/init.mp4',
      );
      expect(
        plan.headers['x-flick-dash-segments'],
        'https://cdn.tidal.com/seg_1.mp4\nhttps://cdn.tidal.com/seg_2.mp4',
      );
      expect(plan.headers['x-flick-sample-rate'], '96000');
      expect(plan.headers['x-flick-extension-hint'], 'mp4');
    });

    test('has no DASH plan for a BTS resolution', () async {
      final tempDir = await Directory.systemTemp.createTemp('tidal_bts_plan');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'manifest': _btsManifest(),
            'manifestMimeType': 'application/vnd.tidal.bts',
            'audioQuality': 'LOSSLESS',
          }),
          200,
        );
      });
      final service = TidalService.create(
        client: client,
        networkCache: NetworkCacheService(rootDirectory: tempDir),
      );
      await service.streamDescriptor(_server(token: _validToken()), 'bts_plan');
      expect(service.directDashPlan('bts_plan'), isNull);
    });

    test(
      'DASH refuses a manifest whose segments are not absolute https',
      () async {
        const mpdXml = '''<?xml version="1.0" encoding="utf-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011">
  <Period>
    <AdaptationSet mimeType="audio/mp4" codecs="flac">
      <Representation id="rep1" audioSamplingRate="96000">
        <SegmentTemplate initialization="init.mp4" media="seg_\$Number\$.mp4" startNumber="1">
          <SegmentTimeline><S d="1000" r="1" /></SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>''';
        final built = await _dashService(mpdXml: mpdXml);
        addTearDown(() => built.dir.deleteSync(recursive: true));
        await expectLater(
          () => built.service.streamDescriptor(
            _server(token: _validToken()),
            'relative_dash',
          ),
          throwsA(isA<TidalException>()),
        );
      },
    );

    for (final scenario in [
      (
        label: 'API bit depth wins over the tier default',
        api: 16,
        tier: 'HI_RES_LOSSLESS',
        bits: 16,
        explicit: true,
      ),
      (
        label: 'no API bit depth + hi-res tier defaults to 24',
        api: null,
        tier: 'HI_RES_LOSSLESS',
        bits: 24,
        explicit: false,
      ),
      (
        label: 'no API bit depth + lossless tier defaults to 16',
        api: null,
        tier: 'LOSSLESS',
        bits: 16,
        explicit: false,
      ),
    ]) {
      test('DASH bit depth: ${scenario.label}', () async {
        final built = await _dashService(
          mpdXml: _simpleDashMpd(),
          apiBitDepth: scenario.api,
          audioQuality: scenario.tier,
        );
        addTearDown(() => built.dir.deleteSync(recursive: true));
        await built.service.streamDescriptor(
          _server(token: _validToken()),
          'depth_track',
        );
        final res = built.service.getResolvedStream('depth_track');
        expect(res, isNotNull);
        expect(res!.bitDepth, scenario.bits);
        expect(res.isBitDepthExplicit, scenario.explicit);
      });
    }

    test(
      'downloads and stitches DASH initialization and segments into cache',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'tidal_dash_test',
        );
        addTearDown(() => tempDir.deleteSync(recursive: true));
        final cache = NetworkCacheService(rootDirectory: tempDir);

        const mpdXml = '''<?xml version="1.0" encoding="utf-8"?>
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
        final manifest = base64Encode(utf8.encode(mpdXml));

        final client = MockClient((request) async {
          if (request.url.path.contains('/playbackinfopostpaywall')) {
            return http.Response(
              jsonEncode({
                'manifest': manifest,
                'manifestMimeType': 'application/dash+xml',
                'audioQuality': 'HI_RES_LOSSLESS',
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/init.mp4')) {
            return http.Response.bytes([1, 2, 3], 200);
          }
          if (request.url.path.endsWith('/seg_1.mp4')) {
            return http.Response.bytes([4, 5], 200);
          }
          if (request.url.path.endsWith('/seg_2.mp4')) {
            return http.Response.bytes([6, 7], 200);
          }
          return http.Response('not found', 404);
        });

        final service = TidalService.create(
          client: client,
          networkCache: cache,
        );
        final filePath = await service.stream(
          _server(token: _validToken()),
          'hires_track_1',
        );

        expect(filePath, isNotNull);
        final file = File(filePath);
        expect(file.existsSync(), isTrue);
        expect(file.readAsBytesSync(), [1, 2, 3, 4, 5, 6, 7]);
      },
    );

    test(
      'null codec with an audio/mp4 BTS manifest normalizes to AAC and stays lossy',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'tidal_bts_aac_test',
        );
        addTearDown(() => tempDir.deleteSync(recursive: true));
        final manifest = base64Encode(
          utf8.encode(
            jsonEncode({
              'mimeType': 'audio/mp4',
              'encryptionType': 'NONE',
              'urls': ['https://cdn.tidal.com/track/aac/abc'],
            }),
          ),
        );
        final client = MockClient((request) async {
          if (request.url.host == 'cdn.tidal.com') {
            return http.Response.bytes([1, 2, 3], 200);
          }
          return http.Response(
            jsonEncode({
              'manifest': manifest,
              'manifestMimeType': 'application/vnd.tidal.bts',
              'assetPresentation': 'FULL',
            }),
            200,
          );
        });
        final service = TidalService.create(
          client: client,
          networkCache: NetworkCacheService(rootDirectory: tempDir),
        );

        final desc = await service.streamDescriptor(
          _server(token: _validToken()),
          '1234567',
        );
        expect(desc, isNotNull);

        final resolved = service.getResolvedStream('1234567');
        expect(resolved, isNotNull);
        expect(resolved!.codec, 'aac');
        expect(resolved.ext, 'm4a');
        expect(resolved.isLossy, isTrue);
        expect(resolved.effectiveBitrate, 320);
        expect(resolved.resolutionString, '320kbps');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      },
    );
  });

  group('stream (DASH cache extension)', () {
    test('late rearm hits the cached <hash>.mp4 via the resolved ext, '
        'without re-downloading', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'tidal_dash_ext_test',
      );
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final cache = NetworkCacheService(rootDirectory: tempDir);

      const mpdXml = '''<?xml version="1.0" encoding="utf-8"?>
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
      final manifest = base64Encode(utf8.encode(mpdXml));

      // Tracks every HTTP request so the test can prove the second
      // stream() call never touches the network.
      final requests = <String>[];
      final client = MockClient((request) async {
        requests.add('${request.method} ${request.url.path}');
        if (request.url.path.contains('/playbackinfopostpaywall')) {
          return http.Response(
            jsonEncode({
              'manifest': manifest,
              'manifestMimeType': 'application/dash+xml',
              'audioQuality': 'HI_RES_LOSSLESS',
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/init.mp4')) {
          return http.Response.bytes([1, 2, 3], 200);
        }
        if (request.url.path.endsWith('/seg_1.mp4')) {
          return http.Response.bytes([4, 5], 200);
        }
        if (request.url.path.endsWith('/seg_2.mp4')) {
          return http.Response.bytes([6, 7], 200);
        }
        return http.Response('not found', 404);
      });

      final service = TidalService.create(client: client, networkCache: cache);

      // First pass: hi-res song whose fileType is 'flac' (as synced by the
      // catalog). Downloads the DASH track and stashes it as <hash>.mp4.
      final firstPath = await service.stream(
        _server(token: _validToken()),
        'hires_track_ext',
        extension: 'flac',
      );
      expect(firstPath, endsWith('.mp4'));
      expect(File(firstPath).existsSync(), isTrue);
      expect(requests, isNotEmpty);
      requests.clear();

      // Second pass: the late-rearm lookup. It passes extension: 'flac'
      // again (song.fileType), but must resolve against the DASH ext 'mp4'
      // recorded in _resolvedStreams and return the cached file instantly.
      final secondPath = await service.stream(
        _server(token: _validToken()),
        'hires_track_ext',
        extension: 'flac',
      );
      expect(secondPath, firstPath);
      expect(secondPath, endsWith('.mp4'));
      expect(requests, isEmpty);
    });
  });

  group('ping', () {
    test('returns false when no token is stored', () async {
      final service = TidalService.create(
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      expect(await service.ping(_server(token: null)), isFalse);
    });
  });

  group('Catalog & Search APIs', () {
    test('searchCatalog passes query params and countryCode', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/v1/search');
        expect(request.url.queryParameters['query'], 'Daft Punk');
        expect(request.url.queryParameters['limit'], '10');
        expect(request.url.queryParameters['offset'], '5');
        expect(request.url.queryParameters['types'], 'TRACKS,ALBUMS');
        expect(request.url.queryParameters['countryCode'], 'NO');
        expect(request.headers['Authorization'], 'Bearer acc-xyz');
        return http.Response(
          jsonEncode({
            'tracks': {
              'items': [
                {'id': 1, 'title': 'Get Lucky'},
              ],
            },
          }),
          200,
        );
      });
      final service = TidalService.create(client: client);
      final res = await service.searchCatalog(
        _server(token: _validToken()),
        'Daft Punk',
        limit: 10,
        offset: 5,
        types: 'TRACKS,ALBUMS',
      );
      expect(res['tracks']['items'], isNotEmpty);
      expect(res['tracks']['items'][0]['title'], 'Get Lucky');
    });

    test('getAlbum and getAlbumTracks hit correct endpoints', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/v1/albums/alb-1') {
          return http.Response(
            jsonEncode({'id': 'alb-1', 'title': 'Random Access Memories'}),
            200,
          );
        }
        if (request.url.path == '/v1/albums/alb-1/tracks') {
          return http.Response(
            jsonEncode({
              'items': [
                {'id': 1, 'title': 'Give Life Back to Music'},
                {'id': 2, 'title': 'Giorgio by Moroder'},
              ],
            }),
            200,
          );
        }
        return http.Response('', 404);
      });
      final service = TidalService.create(client: client);
      final album = await service.getAlbum(
        _server(token: _validToken()),
        'alb-1',
      );
      expect(album['title'], 'Random Access Memories');

      final tracks = await service.getAlbumTracks(
        _server(token: _validToken()),
        'alb-1',
      );
      expect(tracks.length, 2);
      expect(tracks.first['title'], 'Give Life Back to Music');
    });

    test('getPlaylist and getPlaylistTracks hit correct endpoints', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/v1/playlists/pl-1') {
          return http.Response(
            jsonEncode({'uuid': 'pl-1', 'title': 'Audiophile Favorites'}),
            200,
          );
        }
        if (request.url.path == '/v1/playlists/pl-1/tracks') {
          return http.Response(
            jsonEncode({
              'items': [
                {
                  'item': {'id': 100, 'title': 'Hotel California'},
                },
              ],
            }),
            200,
          );
        }
        return http.Response('', 404);
      });
      final service = TidalService.create(client: client);
      final playlist = await service.getPlaylist(
        _server(token: _validToken()),
        'pl-1',
      );
      expect(playlist['title'], 'Audiophile Favorites');

      final tracks = await service.getPlaylistTracks(
        _server(token: _validToken()),
        'pl-1',
      );
      expect(tracks.length, 1);
      expect(tracks.first['item']['title'], 'Hotel California');
    });

    test('getArtistTopTracks hits /artists/{id}/toptracks', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/v1/artists/art-1/toptracks');
        return http.Response(
          jsonEncode({
            'items': [
              {'id': 10, 'title': 'Starboy'},
            ],
          }),
          200,
        );
      });
      final service = TidalService.create(client: client);
      final tracks = await service.getArtistTopTracks(
        _server(token: _validToken()),
        'art-1',
      );
      expect(tracks.length, 1);
      expect(tracks.first['title'], 'Starboy');
    });

    test('getArtist and getArtistAlbums hit correct endpoints', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/v1/artists/art-1') {
          return http.Response(
            jsonEncode({'id': 1, 'name': 'The Weeknd'}),
            200,
          );
        }
        if (request.url.path == '/v1/artists/art-1/albums') {
          expect(request.url.queryParameters['limit'], '50');
          expect(request.url.queryParameters['offset'], '0');
          return http.Response(
            jsonEncode({
              'items': [
                {'id': 100, 'title': 'After Hours'},
              ],
            }),
            200,
          );
        }
        return http.Response('', 404);
      });
      final service = TidalService.create(client: client);
      final artist = await service.getArtist(
        _server(token: _validToken()),
        'art-1',
      );
      expect(artist['name'], 'The Weeknd');

      final albums = await service.getArtistAlbums(
        _server(token: _validToken()),
        'art-1',
      );
      expect(albums.length, 1);
      expect(albums.first['title'], 'After Hours');
    });

    test('TidalStreamResolution formats resolutionString properly', () {
      const res1 = TidalStreamResolution(
        url: 'http://test',
        isDash: false,
        sampleRate: 96000,
        bitDepth: 24,
        audioQuality: 'HI_RES_LOSSLESS',
        bitrate: 2814,
      );
      expect(res1.resolutionString, '24-bit / 96kHz / 2814kbps');

      const res2 = TidalStreamResolution(
        url: 'http://test',
        isDash: false,
        sampleRate: 44100,
        bitDepth: 16,
        audioQuality: 'LOSSLESS',
        bitrate: 1411,
      );
      expect(res2.resolutionString, '16-bit / 44.1kHz / 1411kbps');

      const res3 = TidalStreamResolution(
        url: 'http://test',
        isDash: false,
        sampleRate: 44100,
        bitDepth: 16,
        audioQuality: 'LOSSLESS',
      );
      expect(res3.effectiveBitrate, 1411);
      expect(res3.resolutionString, '16-bit / 44.1kHz / 1411kbps');

      const resHigh = TidalStreamResolution(
        url: 'http://test',
        isDash: false,
        sampleRate: 44100,
        bitDepth: 16,
        audioQuality: 'HIGH',
        codec: 'aac',
        ext: 'm4a',
      );
      expect(resHigh.isLossy, isTrue);
      expect(resHigh.effectiveBitrate, 320);
      expect(resHigh.resolutionString, '320kbps');

      const resLow = TidalStreamResolution(
        url: 'http://test',
        isDash: false,
        sampleRate: 44100,
        bitDepth: 16,
        audioQuality: 'LOW',
        codec: 'aac',
        ext: 'm4a',
      );
      expect(resLow.isLossy, isTrue);
      expect(resLow.effectiveBitrate, 96);
      expect(resLow.resolutionString, '96kbps');
    });

    test('normalizeCodec maps mp4a, flac, alac, and mimes correctly', () {
      expect(TidalService.normalizeCodec('mp4a.40.2', 'audio/mp4'), 'aac');
      expect(TidalService.normalizeCodec('mp4a.40.5', null), 'aac');
      expect(TidalService.normalizeCodec('flac', 'audio/flac'), 'flac');
      expect(TidalService.normalizeCodec(null, 'audio/mp4'), 'aac');
      expect(TidalService.normalizeCodec(null, 'audio/x-m4a'), 'aac');
      expect(TidalService.normalizeCodec(null, 'audio/flac'), 'flac');
    });

    test(
      'getUserPlaylists returns user playlists and handles missing user_id',
      () async {
        final client = MockClient((request) async {
          if (request.url.path == '/v1/users/user-1/playlists') {
            return http.Response(
              jsonEncode({
                'items': [
                  {'uuid': 'p-user', 'title': 'My Playlist'},
                ],
              }),
              200,
            );
          }
          return http.Response('', 404);
        });
        final service = TidalService.create(client: client);

        final playlists = await service.getUserPlaylists(
          _server(token: _validToken()),
        );
        expect(playlists.length, 1);
        expect(playlists.first['title'], 'My Playlist');

        final empty = await service.getUserPlaylists(_server(token: null));
        expect(empty, isEmpty);
      },
    );
  });

  group('TidalStreamResolution codec-first classification', () {
    test('FLAC in an MP4 container is lossless and keeps its real bitrate', () {
      const res = TidalStreamResolution(
        url: 'http://test',
        isDash: false,
        ext: 'm4a',
        sampleRate: 44100,
        bitDepth: 16,
        audioQuality: 'LOSSLESS',
        codec: 'flac',
        bitrate: 1005,
      );
      expect(res.isLossy, isFalse);
      expect(res.effectiveBitrate, 1005);
      expect(res.resolutionString, '16-bit / 44.1kHz / 1005kbps');
    });

    test(
      'FLAC in an MP4 container without a manifest bitrate does not default to 320',
      () {
        const res = TidalStreamResolution(
          url: 'http://test',
          isDash: false,
          ext: 'm4a',
          sampleRate: 44100,
          bitDepth: 16,
          audioQuality: 'LOSSLESS',
          codec: 'flac',
        );
        expect(res.isLossy, isFalse);
        expect(res.effectiveBitrate, 1411);
        expect(res.resolutionString, '16-bit / 44.1kHz / 1411kbps');
      },
    );

    test('ALAC in an MP4 container is lossless', () {
      const res = TidalStreamResolution(
        url: 'http://test',
        isDash: false,
        ext: 'm4a',
        sampleRate: 44100,
        bitDepth: 16,
        audioQuality: 'LOSSLESS',
        codec: 'alac',
        bitrate: 1000,
      );
      expect(res.isLossy, isFalse);
      expect(res.effectiveBitrate, 1000);
      expect(res.resolutionString, '16-bit / 44.1kHz / 1000kbps');
    });

    test('AAC in an MP4 container stays lossy at 320 kbps', () {
      const res = TidalStreamResolution(
        url: 'http://test',
        isDash: false,
        ext: 'm4a',
        sampleRate: 44100,
        bitDepth: 16,
        audioQuality: 'HIGH',
        codec: 'aac',
      );
      expect(res.isLossy, isTrue);
      expect(res.effectiveBitrate, 320);
      expect(res.resolutionString, '320kbps');
    });

    test('raw mp4a codec string is classified as lossy AAC', () {
      const res = TidalStreamResolution(
        url: 'http://test',
        isDash: false,
        ext: 'm4a',
        sampleRate: 44100,
        bitDepth: 16,
        audioQuality: 'HIGH',
        codec: 'mp4a.40.2',
      );
      expect(res.isLossy, isTrue);
      expect(res.effectiveBitrate, 320);
    });

    test('unknown codec with a HIGH catalog tier is lossy', () {
      const res = TidalStreamResolution(
        url: 'http://test',
        isDash: false,
        sampleRate: 44100,
        bitDepth: 16,
        audioQuality: 'HIGH',
      );
      expect(res.isLossy, isTrue);
      expect(res.effectiveBitrate, 320);
    });

    test('FLAC in a FLAC container is unchanged', () {
      const res = TidalStreamResolution(
        url: 'http://test',
        isDash: false,
        ext: 'flac',
        sampleRate: 44100,
        bitDepth: 16,
        audioQuality: 'LOSSLESS',
        codec: 'flac',
        bitrate: 1411,
      );
      expect(res.isLossy, isFalse);
      expect(res.effectiveBitrate, 1411);
    });

    test('AAC downgrade outranks a lossless catalog tier hint', () {
      // The cascade can request LOSSLESS while TIDAL answers with AAC and
      // omits `audioQuality`, in which case the tier is used as the hint.
      // The codec must still win, otherwise the stream poses as 1411 kbps.
      const res = TidalStreamResolution(
        url: 'http://test',
        isDash: false,
        ext: 'm4a',
        sampleRate: 44100,
        bitDepth: 16,
        audioQuality: 'LOSSLESS',
        codec: 'aac',
      );
      expect(res.isLossy, isTrue);
      expect(res.effectiveBitrate, 320);
      expect(res.resolutionString, '320kbps');
    });

    test(
      'unknown codec with mp3 extension is lossy without inventing a rate',
      () {
        const res = TidalStreamResolution(
          url: 'http://test',
          isDash: false,
          ext: 'mp3',
          sampleRate: 44100,
          bitDepth: 16,
          audioQuality: 'LOSSLESS',
        );
        expect(res.isLossy, isTrue);
        expect(res.effectiveBitrate, isNull);
        expect(res.resolutionString, 'Lossy');
      },
    );
  });

  group('buildEphemeralSong', () {
    test('builds ephemeral Song with LOSSLESS audio metadata', () {
      final server = _server();
      final track = {
        'id': 9999,
        'title': 'Instant Crush',
        'duration': 337,
        'trackNumber': 5,
        'volumeNumber': 1,
        'artists': [
          {'name': 'Daft Punk'},
          {'name': 'Julian Casablancas'},
        ],
        'album': {
          'title': 'Random Access Memories',
          'releaseDate': '2013-05-17',
          'cover': 'abc-123',
        },
        'audioQuality': 'LOSSLESS',
      };

      final song = TidalService.makeEphemeralSong(server, track);

      expect(song.id, 'tidal_9_9999');
      expect(song.title, 'Instant Crush');
      expect(song.artist, 'Daft Punk, Julian Casablancas');
      expect(song.album, 'Random Access Memories');
      expect(song.albumArt, TidalService.coverUrl('abc-123', size: 640));
      expect(song.duration, const Duration(seconds: 337));
      expect(song.fileType, 'flac');
      expect(song.sampleRate, 44100);
      expect(song.bitDepth, 16);
      expect(song.trackNumber, 5);
      expect(song.discNumber, 1);
      expect(song.year, 2013);
      expect(song.filePath, 'tidal://9/9999');
      expect(song.sourceType, 'tidal');
      expect(song.remoteId, '9999');
      expect(song.remoteServerId, 9);
      expect(song.isNetworkSource, isTrue);
    });

    test('builds ephemeral Song with HI_RES_LOSSLESS (24-bit/96kHz)', () {
      final server = _server();
      final track = {
        'id': 8888,
        'title': 'High Res Track',
        'duration': 200,
        'artists': [
          {'name': 'Audiophile Artist'},
        ],
        'audioQuality': 'HI_RES_LOSSLESS',
      };

      final song = TidalService.instance.buildEphemeralSong(server, track);

      expect(song.id, 'tidal_9_8888');
      expect(song.sampleRate, 96000);
      expect(song.bitDepth, 24);
      expect(song.fileType, 'flac');
      expect(song.artist, 'Audiophile Artist');
    });

    test('unwraps playlist item container when building ephemeral song', () {
      final server = _server();
      final wrapped = {
        'type': 'track',
        'item': {
          'id': 7777,
          'title': 'Wrapped Item',
          'duration': 180,
          'artists': [
            {'name': 'Wrapped Artist'},
          ],
          'audioQuality': 'LOSSLESS',
        },
      };

      final song = TidalService.makeEphemeralSong(server, wrapped);

      expect(song.id, 'tidal_9_7777');
      expect(song.title, 'Wrapped Item');
      expect(song.artist, 'Wrapped Artist');
    });

    test('falls back to album artist when track artists are absent', () {
      final server = _server();
      final track = {
        'id': 6666,
        'title': 'No Track Artist',
        'album': {
          'artist': {'name': 'Album Level Artist'},
        },
      };

      final song = TidalService.makeEphemeralSong(server, track);

      expect(song.artist, 'Album Level Artist');
    });
  });

  group('extForQuality', () {
    test('maps audioQuality to file extension', () {
      expect(TidalService.extForQuality('HIGH'), 'm4a');
      expect(TidalService.extForQuality('LOSSLESS'), 'flac');
      expect(TidalService.extForQuality('HI_RES_LOSSLESS'), 'flac');
      expect(TidalService.extForQuality('HI_RES'), 'flac');
      expect(TidalService.extForQuality('UNKNOWN'), isNull);
    });
  });

  group('Playlist Import & ISRC Search', () {
    test('searchTrackByIsrcOrText finds track by ISRC', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/v1/search');
        expect(request.url.queryParameters['query'], 'TCJPE1680100');
        expect(request.url.queryParameters['types'], 'TRACKS');
        return http.Response(
          jsonEncode({
            'tracks': {
              'items': [
                {
                  'id': 998877,
                  'title': 'Glory',
                  'artists': [
                    {'name': 'deneb'},
                  ],
                },
              ],
            },
          }),
          200,
        );
      });
      final service = TidalService.create(client: client);
      final trackId = await service.searchTrackByIsrcOrText(
        _server(token: _validToken()),
        isrc: 'TCJPE1680100',
        title: 'Glory',
        artist: 'deneb',
      );
      expect(trackId, '998877');
    });

    test(
      'searchTrackByIsrcOrText falls back to text search if ISRC returns empty',
      () async {
        int callCount = 0;
        final client = MockClient((request) async {
          callCount++;
          if (callCount == 1) {
            // ISRC returns empty
            return http.Response(
              jsonEncode({
                'tracks': {'items': []},
              }),
              200,
            );
          } else {
            // Title + Artist search
            expect(request.url.queryParameters['query'], 'Glory deneb');
            return http.Response(
              jsonEncode({
                'tracks': {
                  'items': [
                    {
                      'id': 112233,
                      'title': 'Glory',
                      'artists': [
                        {'name': 'deneb'},
                      ],
                    },
                  ],
                },
              }),
              200,
            );
          }
        });
        final service = TidalService.create(client: client);
        final trackId = await service.searchTrackByIsrcOrText(
          _server(token: _validToken()),
          isrc: 'TCJPE1680100',
          title: 'Glory',
          artist: 'deneb',
        );
        expect(trackId, '112233');
        expect(callCount, 2);
      },
    );

    test(
      'searchTrackByIsrcOrText rejects unrelated random candidate from ISRC query and picks matching track from text query',
      () async {
        final client = MockClient((request) async {
          if (request.url.queryParameters['query'] == 'FAKE_ISRC') {
            // TIDAL search returns a random track for the ISRC string
            return http.Response(
              jsonEncode({
                'tracks': {
                  'items': [
                    {
                      'id': 666,
                      'title': 'Totally Random Track',
                      'artists': [
                        {'name': 'Random Artist'},
                      ],
                    },
                  ],
                },
              }),
              200,
            );
          } else {
            // Clean title + artist query returns the genuine track
            final jsonStr = jsonEncode({
              'tracks': {
                'items': [
                  {
                    'id': 777,
                    'title': "Don't say lazy",
                    'artists': [
                      {'name': '桜高軽音部'},
                    ],
                    'duration': 264,
                  },
                ],
              },
            });
            return http.Response.bytes(
              utf8.encode(jsonStr),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
        });
        final service = TidalService.create(client: client);
        final trackId = await service.searchTrackByIsrcOrText(
          _server(token: _validToken()),
          isrc: 'FAKE_ISRC',
          title: 'Don\'t say "lazy"',
          artist: '桜高軽音部 [平沢唯・秋山澪(CV:豊崎愛生)]',
          expectedDurationMs: 263973,
        );
        // It must NOT pick the random track 666; it must pick the authentic track 777!
        expect(trackId, '777');
      },
    );

    test(
      'addTracksToPlaylist batches track IDs and includes ETag header',
      () async {
        int requestIndex = 0;
        final client = MockClient((request) async {
          requestIndex++;
          if (request.url.path == '/v1/playlists/pl-import') {
            return http.Response(
              '{"title": "Import"}',
              200,
              headers: {'etag': '"etag-123"'},
            );
          } else if (request.url.path == '/v1/playlists/pl-import/items') {
            expect(request.headers['If-None-Match'], '"etag-123"');
            expect(request.bodyFields['trackIds'], '101,102,103');
            expect(request.bodyFields['onDupes'], 'SKIP');
            return http.Response('{"status": "ok"}', 200);
          }
          return http.Response('Not Found', 404);
        });
        final service = TidalService.create(client: client);
        await service.addTracksToPlaylist(
          _server(token: _validToken()),
          playlistId: 'pl-import',
          trackIds: ['tidal_9_101', '102', 'tidal_9_103'],
        );
        expect(requestIndex, 2);
      },
    );
  });

  group('Playback Reporting & Home Feed', () {
    test('reportPlayback sends SQS batch event to ec.tidal.com', () async {
      bool sent = false;
      final payloadB64 = base64Url
          .encode(
            utf8.encode(
              jsonEncode({'uid': 12345, 'cid': 9876, 'sid': 'test-session'}),
            ),
          )
          .replaceAll('=', '');
      final jwtToken = 'header.$payloadB64.signature';
      final tokenJson = jsonEncode({
        'access_token': jwtToken,
        'country_code': 'US',
        'expires_at_ms': DateTime.now()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      });

      final client = MockClient((request) async {
        if (request.url.host == 'ec.tidal.com' &&
            request.url.path == '/api/event-batch') {
          sent = true;
          expect(request.headers['Authorization'], 'Bearer $jwtToken');
          expect(
            request
                .bodyFields['SendMessageBatchRequestEntry.1.MessageAttribute.1.Value.StringValue'],
            'playback_session',
          );
          final bodyJson =
              request.bodyFields['SendMessageBatchRequestEntry.1.MessageBody']!;
          expect(bodyJson, contains('"productType":"TRACK"'));
          expect(bodyJson, contains('"requestedProductId":"777888"'));
          expect(bodyJson, contains('"sourceType":"ALBUM"'));
          expect(bodyJson, contains('"sourceId":"alb-123"'));
          return http.Response(
            '<SendMessageBatchResponse></SendMessageBatchResponse>',
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final service = TidalService.create(client: client);
      await service.reportPlayback(
        _server(token: tokenJson),
        trackId: '777888',
        durationSeconds: 45,
        context: const PlaybackContext(
          source: PlaybackSource.album,
          sourceId: 'alb-123',
        ),
      );

      expect(sent, isTrue);
    });

    test(
      'getHomeFeed falls back to SONE-parity V1 multi-endpoints when V2 fails',
      () async {
        final client = MockClient((request) async {
          if (request.url.path == '/v2/home/feed/static') {
            return http.Response('Not Found', 404);
          }
          if (request.url.path == '/v1/pages/my_collection_my_mixes') {
            return http.Response(
              jsonEncode({
                'rows': [
                  {
                    'modules': [
                      {
                        'type': 'MIX_LIST',
                        'title': 'My Mixes',
                        'pagedList': {
                          'items': [
                            {
                              'mixId': 'm-1',
                              'title': 'Mix 1',
                              'mixType': 'MY_MIX',
                            },
                          ],
                        },
                      },
                    ],
                  },
                ],
              }),
              200,
            );
          }
          if (request.url.path == '/v1/pages/for_you') {
            return http.Response(
              jsonEncode({
                'rows': [
                  {
                    'modules': [
                      {
                        'type': 'TRACK_LIST',
                        'title': 'Recommended new tracks',
                        'pagedList': {
                          'items': [
                            {
                              'id': 123,
                              'title': 'Rec Song',
                              'artist': {'name': 'Rec Artist'},
                              'album': {'title': 'Rec Album'},
                              'duration': 180,
                            },
                          ],
                        },
                      },
                    ],
                  },
                ],
              }),
              200,
            );
          }
          if (request.url.path == '/v1/pages/home') {
            return http.Response(
              jsonEncode({
                'rows': [
                  {
                    'modules': [
                      {
                        'type': 'ALBUM_LIST',
                        'title': 'The Hits',
                        'pagedList': {
                          'items': [
                            {'id': 456, 'title': 'Hit Album'},
                          ],
                        },
                      },
                    ],
                  },
                ],
              }),
              200,
            );
          }
          return http.Response('Not Found', 404);
        });

        final service = TidalService.create(client: client);
        final feed = await service.getHomeFeed(_server(token: _validToken()));

        expect(feed.sections.length, 3);
        expect(feed.sections[0].title, 'My Mixes');
        expect(feed.sections[1].title, 'Recommended new tracks');
        expect(feed.sections[2].title, 'The Hits');
      },
    );

    test(
      'getTrackRadioMixId fetches track detail on demand and extracts TRACK_MIX',
      () async {
        final client = MockClient((request) async {
          if (request.url.path == '/v1/tracks/998877') {
            return http.Response(
              jsonEncode({
                'id': 998877,
                'title': 'Midnight City',
                'mixes': {'TRACK_MIX': 'radio-mix-12345'},
              }),
              200,
            );
          }
          return http.Response('Not Found', 404);
        });

        final service = TidalService.create(client: client);
        final radioId = await service.getTrackRadioMixId(
          _server(token: _validToken()),
          '998877',
        );

        expect(radioId, 'radio-mix-12345');
      },
    );
  });

  group('getTrackCredits', () {
    test('parses the top-level array shape returned by the live API', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/v1/tracks/20115564/credits');
        expect(request.url.queryParameters['countryCode'], 'NO');
        expect(request.headers['Authorization'], 'Bearer acc-xyz');
        return http.Response(
          jsonEncode([
            {
              'type': 'Producer',
              'contributors': [
                {'name': 'Thomas Bangalter', 'id': 3538385},
              ],
            },
            {
              'type': 'Composer',
              'contributors': [
                {'name': 'Pharrell Williams', 'id': 4900204},
                {'name': 'Nile Rodgers', 'id': 30528},
                {'name': ''},
              ],
            },
          ]),
          200,
        );
      });
      final service = TidalService.create(client: client);

      final credits = await service.getTrackCredits(
        _server(token: _validToken()),
        '20115564',
      );

      expect(credits, [
        {'type': 'Producer', 'name': 'Thomas Bangalter'},
        {'type': 'Composer', 'name': 'Pharrell Williams'},
        {'type': 'Composer', 'name': 'Nile Rodgers'},
      ]);
    });

    test(
      'returns an empty list when the API succeeds with no credits',
      () async {
        final client = MockClient((request) async => http.Response('[]', 200));
        final service = TidalService.create(client: client);

        final credits = await service.getTrackCredits(
          _server(token: _validToken()),
          '100524902',
        );

        expect(credits, isEmpty);
      },
    );

    test('throws on HTTP failure instead of silently returning empty', () async {
      final client = MockClient(
        (request) async => http.Response(
          '{"status":404,"subStatus":2001,"userMessage":"Resource not found"}',
          404,
        ),
      );
      final service = TidalService.create(client: client);

      await expectLater(
        service.getTrackCredits(_server(token: _validToken()), '999999999999'),
        throwsA(isA<TidalException>()),
      );
    });

    test('throws on unexpected (non-array) response shape', () async {
      final client = MockClient(
        (request) async => http.Response('{"items": []}', 200),
      );
      final service = TidalService.create(client: client);

      await expectLater(
        service.getTrackCredits(_server(token: _validToken()), '20115564'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('getArtistBio', () {
    test('parses biography text from the included resource', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/v2/artists/1234');
        expect(request.url.queryParameters['include'], 'biography');
        expect(request.url.queryParameters['countryCode'], 'NO');
        expect(request.headers['Authorization'], 'Bearer acc-xyz');
        return http.Response(
          jsonEncode({
            'data': {
              'id': '1234',
              'type': 'artists',
              'relationships': {
                'biography': {
                  'data': {'id': 'bio-1', 'type': 'artistBiographies'},
                },
              },
            },
            'included': [
              {
                'id': 'bio-1',
                'type': 'artistBiographies',
                'attributes': {'source': 'TiVo', 'text': '  Born in Oslo.  '},
              },
            ],
          }),
          200,
        );
      });
      final service = TidalService.create(client: client);

      final bio = await service.getArtistBio(
        _server(token: _validToken()),
        '1234',
      );

      expect(bio, 'Born in Oslo.');
    });

    test('accepts a to-many biography relationship (list ref)', () async {
      final client = MockClient(
        (request) async => http.Response(
          jsonEncode({
            'data': {
              'id': '1234',
              'type': 'artists',
              'relationships': {
                'biography': {
                  'data': [
                    {'id': 'bio-1', 'type': 'artistBiographies'},
                  ],
                },
              },
            },
            'included': [
              {
                'id': 'bio-1',
                'type': 'artistBiographies',
                'attributes': {'text': 'List-shaped bio'},
              },
            ],
          }),
          200,
        ),
      );
      final service = TidalService.create(client: client);

      final bio = await service.getArtistBio(
        _server(token: _validToken()),
        '1234',
      );

      expect(bio, 'List-shaped bio');
    });

    test('returns null when the artist has no biography', () async {
      final client = MockClient(
        (request) async => http.Response(
          jsonEncode({
            'data': {'id': '1234', 'type': 'artists', 'relationships': {}},
          }),
          200,
        ),
      );
      final service = TidalService.create(client: client);

      expect(
        await service.getArtistBio(_server(token: _validToken()), '1234'),
        isNull,
      );
    });

    test('returns null instead of throwing on HTTP failure', () async {
      final client = MockClient(
        (request) async => http.Response('{"errors": []}', 404),
      );
      final service = TidalService.create(client: client);

      expect(
        await service.getArtistBio(_server(token: _validToken()), '9999'),
        isNull,
      );
    });
  });

  group('favorite artists', () {
    test('collects ids across paginated favorites', () async {
      final requestedOffsets = <String?>[];
      final client = MockClient((request) async {
        expect(request.url.path, '/v1/users/user-1/favorites/artists');
        final offset = request.url.queryParameters['offset'];
        requestedOffsets.add(offset);
        final items = offset == '0'
            ? List.generate(
                100,
                (i) => {
                  'item': {'id': 'a$i'},
                },
              )
            : [
                {
                  'item': {'id': 'b1'},
                },
              ];
        return http.Response(jsonEncode({'items': items}), 200);
      });
      final service = TidalService.create(client: client);

      final ids = await service.getFavoriteArtistIds(
        _server(token: _validToken()),
      );

      expect(ids.length, 101);
      expect(ids, contains('a0'));
      expect(ids, contains('b1'));
      expect(requestedOffsets, ['0', '100']);
    });

    test('addFavoriteArtist posts the artistId form field', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response('', 201);
      });
      final service = TidalService.create(client: client);

      await service.addFavoriteArtist(_server(token: _validToken()), '42');

      expect(captured.method, 'POST');
      expect(captured.url.path, '/v1/users/user-1/favorites/artists');
      expect(captured.url.queryParameters['countryCode'], 'NO');
      expect(captured.headers['Authorization'], 'Bearer acc-xyz');
      expect(captured.body, 'artistId=42');
    });

    test('removeFavoriteArtist deletes the favorite relationship', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response('', 204);
      });
      final service = TidalService.create(client: client);

      await service.removeFavoriteArtist(_server(token: _validToken()), '42');

      expect(captured.method, 'DELETE');
      expect(captured.url.path, '/v1/users/user-1/favorites/artists/42');
      expect(captured.url.queryParameters['countryCode'], 'NO');
    });

    test('addFavoriteArtist throws TidalException on HTTP failure', () async {
      final client = MockClient(
        (request) async => http.Response('{"status":403}', 403),
      );
      final service = TidalService.create(client: client);

      await expectLater(
        service.addFavoriteArtist(_server(token: _validToken()), '42'),
        throwsA(isA<TidalException>()),
      );
    });

    test(
      'favorite-artist calls are no-ops without a signed-in account',
      () async {
        final client = MockClient(
          (request) async => fail('no HTTP expected for a tokenless server'),
        );
        final service = TidalService.create(client: client);
        final server = _server();

        expect(await service.getFavoriteArtistIds(server), isEmpty);
        await service.addFavoriteArtist(server, '42');
        await service.removeFavoriteArtist(server, '42');
      },
    );
  });

  group('favorite albums', () {
    test('collects album metadata across paginated favorites', () async {
      final requestedOffsets = <String?>[];
      final client = MockClient((request) async {
        expect(request.url.path, '/v1/users/user-1/favorites/albums');
        final offset = request.url.queryParameters['offset'];
        requestedOffsets.add(offset);
        final items = offset == '0'
            ? List.generate(
                100,
                (i) => {
                  'item': {'id': 'album-$i', 'title': 'Album $i'},
                },
              )
            : [
                {
                  'item': {'id': 'album-101', 'title': 'Last Album'},
                },
              ];
        return http.Response(jsonEncode({'items': items}), 200);
      });
      final service = TidalService.create(client: client);

      final albums = await service.getFavoriteAlbums(
        _server(token: _validToken()),
      );

      expect(albums, hasLength(101));
      expect(albums.first['title'], 'Album 0');
      expect(albums.last['id'], 'album-101');
      expect(requestedOffsets, ['0', '100']);
    });

    test('addFavoriteAlbum posts the albumId form field', () async {
      late http.Request captured;
      final service = TidalService.create(
        client: MockClient((request) async {
          captured = request;
          return http.Response('', 201);
        }),
      );

      await service.addFavoriteAlbum(_server(token: _validToken()), '42');

      expect(captured.method, 'POST');
      expect(captured.url.path, '/v1/users/user-1/favorites/albums');
      expect(captured.url.queryParameters['countryCode'], 'NO');
      expect(captured.headers['Authorization'], 'Bearer acc-xyz');
      expect(captured.body, 'albumId=42');
    });

    test('removeFavoriteAlbum deletes the favorite relationship', () async {
      late http.Request captured;
      final service = TidalService.create(
        client: MockClient((request) async {
          captured = request;
          return http.Response('', 204);
        }),
      );

      await service.removeFavoriteAlbum(_server(token: _validToken()), '42');

      expect(captured.method, 'DELETE');
      expect(captured.url.path, '/v1/users/user-1/favorites/albums/42');
      expect(captured.url.queryParameters['countryCode'], 'NO');
    });

    test(
      'favorite-album calls are no-ops without a signed-in account',
      () async {
        final service = TidalService.create(
          client: MockClient((_) async => fail('unexpected request')),
        );
        final server = _server();

        expect(await service.getFavoriteAlbums(server), isEmpty);
        await service.addFavoriteAlbum(server, '42');
        await service.removeFavoriteAlbum(server, '42');
      },
    );
  });

  group('getTrackLyrics', () {
    test('GETs /tracks/{id}/lyrics with auth and countryCode', () async {
      late http.Request seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode({
            'trackId': 123,
            'lyricsProvider': 'MUSIXMATCH',
            'lyrics': 'Doh\nDoh-doh-doh',
            'subtitles': '[00:00.04] Doh',
            'isRightToLeft': false,
          }),
          200,
        );
      });
      final service = TidalService.create(client: client);

      final lyrics = await service.getTrackLyrics(
        _server(token: _validToken()),
        '123',
      );

      expect(seen.url.path, '/v1/tracks/123/lyrics');
      expect(seen.url.queryParameters['countryCode'], isNotEmpty);
      expect(seen.headers['Authorization'], 'Bearer acc-xyz');
      expect(lyrics, isNotNull);
      expect(lyrics!.lyricsProvider, 'MUSIXMATCH');
      expect(lyrics.subtitles, '[00:00.04] Doh');
    });

    test(
      'a 404 means "no lyrics" and returns null instead of throwing',
      () async {
        final client = MockClient(
          (request) async => http.Response('{"error":"notFound"}', 404),
        );
        final service = TidalService.create(client: client);

        expect(
          await service.getTrackLyrics(_server(token: _validToken()), '404403'),
          isNull,
        );
      },
    );

    test('a 403 (lyrics scope refused) also returns null', () async {
      // The lyrics endpoint is known to refuse tokens that lack its scope; that
      // must read as "no lyrics", not as a playback/auth failure.
      final client = MockClient(
        (request) async => http.Response('{"error":"forbidden"}', 403),
      );
      final service = TidalService.create(client: client);

      expect(
        await service.getTrackLyrics(_server(token: _validToken()), '403403'),
        isNull,
      );
    });

    test('an empty payload body returns null', () async {
      final client = MockClient((request) async => http.Response('   ', 200));
      final service = TidalService.create(client: client);

      expect(
        await service.getTrackLyrics(_server(token: _validToken()), 'empty'),
        isNull,
      );
    });

    test('a payload with no lyrics and no subtitles returns null', () async {
      final client = MockClient(
        (request) async => http.Response(
          jsonEncode({'trackId': 5, 'isRightToLeft': false}),
          200,
        ),
      );
      final service = TidalService.create(client: client);

      expect(
        await service.getTrackLyrics(_server(token: _validToken()), '5'),
        isNull,
      );
    });

    test('a server error is rethrown as a typed HTTP failure', () async {
      final client = MockClient(
        (request) async => http.Response('{"error":"boom"}', 503),
      );
      final service = TidalService.create(client: client);

      await expectLater(
        () => service.getTrackLyrics(_server(token: _validToken()), '503503'),
        throwsA(
          isA<TidalHttpException>().having((e) => e.statusCode, 'status', 503),
        ),
      );
    });
  });
}
