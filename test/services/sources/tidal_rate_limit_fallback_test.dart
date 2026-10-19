import 'dart:convert';

import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/services/sources/tidal_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

NetworkServerEntity _server() {
  return NetworkServerEntity()
    ..id = 0
    ..label = 'Tidal'
    ..protocol = 'tidal'
    ..baseUrl = TidalService.tidalBaseUrl
    ..token = jsonEncode({
      'access_token': 'test-access-token',
      'user_id': '12345678',
      'country_code': 'US',
      'expires_at_ms': DateTime.now()
          .add(const Duration(hours: 2))
          .millisecondsSinceEpoch,
    });
}

String _v1PageBody(String title) {
  return jsonEncode({
    'rows': [
      {
        'modules': [
          {
            'type': 'TRACK_LIST',
            'title': title,
            'pagedList': {
              'items': [
                {
                  'id': 1001,
                  'title': 'Track from $title',
                  'duration': 200,
                  'artists': [
                    {'name': 'Artist'},
                  ],
                  'album': {'title': 'Album', 'cover': 'cover-uuid'},
                },
              ],
            },
          },
        ],
      },
    ],
  });
}

const _v1Paths = [
  '/v1/pages/my_collection_my_mixes',
  '/v1/pages/for_you',
  '/v1/pages/home',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TidalService home feed fallback', () {
    test(
      'V2 429 does not fall back to V1 and propagates the rate-limit error',
      () async {
        var v2Requests = 0;
        var v1Requests = 0;

        final client = MockClient((request) async {
          if (request.url.path == '/v2/home/feed/static') {
            v2Requests++;
            return http.Response('', 429, headers: {'retry-after': '0'});
          }
          v1Requests++;
          return http.Response(
            _v1PageBody('Unexpected V1 page'),
            200,
            headers: {'content-type': 'application/json'},
          );
        });

        final service = TidalService.create(client: client);

        await expectLater(
          service.getHomeFeed(_server()),
          throwsA(isA<TidalRateLimitedException>()),
        );

        // The four V2 attempts come from _with429Retry (1 initial + 3
        // retries). What matters is that the rate-limit never fans out into
        // the three V1 endpoints.
        expect(v2Requests, 4);
        expect(v1Requests, 0);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('V2 non-429 failure still uses the V1 fallback', () async {
      final v1Paths = <String>[];

      final client = MockClient((request) async {
        if (request.url.path == '/v2/home/feed/static') {
          return http.Response('upstream error', 500);
        }
        v1Paths.add(request.url.path);
        return http.Response(
          _v1PageBody('Fallback ${request.url.path}'),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final service = TidalService.create(client: client);
      final feed = await service.getHomeFeed(_server());

      expect(feed.sections, isNotEmpty);
      expect(v1Paths, hasLength(_v1Paths.length));
      expect(v1Paths, containsAll(_v1Paths));
    });

    test(
      'V1 fallback propagates a 429 instead of returning an empty feed',
      () async {
        var v1Requests = 0;

        final client = MockClient((request) async {
          if (request.url.path == '/v2/home/feed/static') {
            return http.Response('upstream error', 500);
          }
          v1Requests++;
          return http.Response('', 429, headers: {'retry-after': '0'});
        });

        final service = TidalService.create(client: client);

        await expectLater(
          service.getHomeFeed(_server()),
          throwsA(isA<TidalRateLimitedException>()),
        );
        // All three pages were attempted (they run in parallel), each with its
        // own retry chain; none was folded into a silent empty feed.
        expect(v1Requests, 3 * 4);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
