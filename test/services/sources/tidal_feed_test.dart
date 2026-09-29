import 'dart:convert';

import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/models/sources/tidal_models.dart';
import 'package:flick/services/sources/tidal_service.dart';
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
      'access_token': 'test-access-token',
      'refresh_token': 'test-refresh-token',
      'user_id': '12345678',
      'country_code': 'US',
      'expires_at_ms':
          DateTime.now().add(const Duration(hours: 2)).millisecondsSinceEpoch,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TidalService Home Feed & Mixes', () {
    test('getHomeFeed parses V2 vibes, shortcuts, and horizontal lists', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path.contains('/v2/home/feed/static')) {
          expect(request.url.queryParameters['countryCode'], 'US');
          expect(request.url.queryParameters['deviceType'], 'BROWSER');
          return http.Response(
            jsonEncode({
              'header': {
                'vibes': {
                  'items': [
                    {'name': 'Suggested', 'type': 'STATIC'},
                    {'name': 'Relax', 'type': 'RELAX'},
                    {'name': 'Workout', 'type': 'WORKOUT'},
                  ]
                }
              },
              'items': [
                {
                  'type': 'SHORTCUT_LIST',
                  'title': 'Shortcuts',
                  'items': [
                    {
                      'type': 'MIX',
                      'data': {
                        'id': 'mix-01',
                        'title': 'My Daily Mix 1',
                        'images': {
                          'LARGE': {'url': 'https://resources.tidal.com/images/mix1.jpg'}
                        }
                      }
                    },
                    {
                      'type': 'PLAYLIST',
                      'data': {
                        'uuid': 'pl-uuid-02',
                        'title': 'Chill Hits',
                        'cover': 'cover-uuid-02',
                        'numberOfTracks': 42,
                      }
                    }
                  ]
                },
                {
                  'type': 'HORIZONTAL_LIST',
                  'title': 'Custom Mixes',
                  'items': [
                    {
                      'type': 'MIX',
                      'data': {
                        'id': 'mix-02',
                        'title': 'Artist Radio',
                        'mixImages': [
                          {'url': 'https://resources.tidal.com/images/mix2.jpg'}
                        ]
                      }
                    }
                  ]
                }
              ]
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('Not Found', 404);
      });

      final service = TidalService.create(client: mockClient);
      final server = _server(token: _validToken());

      final feed = await service.getHomeFeed(server);

      expect(feed.tabs.length, 3);
      expect(feed.tabs[0].name, 'Suggested');
      expect(feed.tabs[0].slug, 'static');
      expect(feed.tabs[1].name, 'Relax');
      expect(feed.tabs[1].slug, 'relax');

      expect(feed.sections.length, 2);

      // SHORTCUT_LIST
      final shortcutSec = feed.sections.firstWhere((s) => s.isShortcutList);
      expect(shortcutSec.items.length, 2);
      expect(shortcutSec.items[0].id, 'mix-01');
      expect(shortcutSec.items[0].title, 'My Daily Mix 1');
      expect(shortcutSec.items[0].isMix, isTrue);
      expect(shortcutSec.items[0].imageUrl, 'https://resources.tidal.com/images/mix1.jpg');

      expect(shortcutSec.items[1].id, 'pl-uuid-02');
      expect(shortcutSec.items[1].title, 'Chill Hits');
      expect(shortcutSec.items[1].isPlaylist, isTrue);
      expect(shortcutSec.items[1].subtitle, contains('42 tracks'));

      // HORIZONTAL_LIST
      final hSec = feed.sections.firstWhere((s) => s.isHorizontalList);
      expect(hSec.title, 'Custom Mixes');
      expect(hSec.items.length, 1);
      expect(hSec.items[0].id, 'mix-02');
      expect(hSec.items[0].imageUrl, 'https://resources.tidal.com/images/mix2.jpg');
    });

    test('getMix parses MIX_HEADER and TRACK_LIST into TidalMix', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path.contains('/v1/pages/mix')) {
          expect(request.url.queryParameters['mixId'], 'daily-mix-1');
          return http.Response(
            jsonEncode({
              'rows': [
                {
                  'modules': [
                    {
                      'type': 'MIX_HEADER',
                      'mix': {
                        'title': 'Daily Mix 1',
                        'subTitle': 'Daft Punk, Justice, and more',
                        'mixType': 'DAILY_MIX',
                        'images': {
                          'LARGE': {'url': 'https://resources.tidal.com/mix-banner.jpg'}
                        }
                      }
                    }
                  ]
                },
                {
                  'modules': [
                    {
                      'type': 'TRACK_LIST',
                      'pagedList': {
                        'items': [
                          {
                            'id': 1001,
                            'title': 'Get Lucky',
                            'duration': 248,
                            'artists': [
                              {'name': 'Daft Punk'}
                            ],
                            'album': {
                              'title': 'Random Access Memories',
                              'cover': 'ram-cover-uuid',
                            },
                            'audioQuality': 'HI_RES_LOSSLESS',
                            'mediaMetadata': {
                              'tags': ['HIRES_LOSSLESS']
                            }
                          }
                        ]
                      }
                    }
                  ]
                }
              ]
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('Not Found', 404);
      });

      final service = TidalService.create(client: mockClient);
      final server = _server(token: _validToken());

      final mix = await service.getMix(server, 'daily-mix-1');

      expect(mix.mixId, 'daily-mix-1');
      expect(mix.title, 'Daily Mix 1');
      expect(mix.subTitle, 'Daft Punk, Justice, and more');
      expect(mix.mixType, 'DAILY_MIX');
      expect(mix.imageUrl, 'https://resources.tidal.com/mix-banner.jpg');
      expect(mix.tracks.length, 1);

      final track = mix.tracks.first;
      expect(track.title, 'Get Lucky');
      expect(track.artist, 'Daft Punk');
      expect(track.remoteId, '1001');
      expect(track.bitDepth, 24);
      expect(track.sampleRate, 96000);
    });

    test('addFavoriteTrack and removeFavoriteTrack send expected HTTP requests', () async {
      String? lastPostPath;
      String? lastDeletePath;
      Map<String, String>? lastFields;

      final mockClient = MockClient((request) async {
        if (request.method == 'POST' && request.url.path.contains('/favorites/tracks')) {
          lastPostPath = request.url.path;
          lastFields = request.bodyFields;
          return http.Response('{}', 200);
        }
        if (request.method == 'DELETE' && request.url.path.contains('/favorites/tracks/')) {
          lastDeletePath = request.url.path;
          return http.Response('{}', 200);
        }
        return http.Response('Not Found', 404);
      });

      final service = TidalService.create(client: mockClient);
      final server = _server(token: _validToken());

      await service.addFavoriteTrack(server, '9999');
      expect(lastPostPath, '/v1/users/12345678/favorites/tracks');
      expect(lastFields?['trackId'], '9999');

      await service.removeFavoriteTrack(server, '9999');
      expect(lastDeletePath, '/v1/users/12345678/favorites/tracks/9999');
    });

    test('addTrackToPlaylist fetches ETag and sets If-None-Match header', () async {
      String? receivedEtagHeader;
      Map<String, String>? receivedFields;

      final mockClient = MockClient((request) async {
        // Step 1: GET /playlists/{id}
        if (request.method == 'GET' && request.url.path == '/v1/playlists/pl-123') {
          return http.Response('{"title": "My Playlist"}', 200, headers: {
            'etag': '"etag-abc-123"',
          });
        }
        // Step 2: POST /playlists/{id}/items
        if (request.method == 'POST' && request.url.path == '/v1/playlists/pl-123/items') {
          receivedEtagHeader = request.headers['If-None-Match'];
          receivedFields = request.bodyFields;
          return http.Response('{"added": 1}', 200);
        }
        return http.Response('Not Found', 404);
      });

      final service = TidalService.create(client: mockClient);
      final server = _server(token: _validToken());

      await service.addTrackToPlaylist(server, playlistId: 'pl-123', trackId: 'trk-555');

      expect(receivedEtagHeader, '"etag-abc-123"');
      expect(receivedFields?['trackIds'], 'trk-555');
      expect(receivedFields?['onDupes'], 'SKIP');
    });

    test('addTrackToPlaylist sanitizes prefixed trackId (tidal_x_12345)', () async {
      String? cleanId;
      final mockClient = MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response('{"title": "My Playlist"}', 200, headers: {'etag': '"etag-1"'});
        }
        if (request.method == 'POST') {
          cleanId = request.bodyFields['trackIds'];
          return http.Response('{}', 200);
        }
        return http.Response('Not Found', 404);
      });

      final service = TidalService.create(client: mockClient);
      final server = _server(token: _validToken());

      await service.addTrackToPlaylist(server, playlistId: 'pl-1', trackId: 'tidal_9_98765');
      expect(cleanId, '98765');
    });

    test('createPlaylist sends OpenAPI format payload', () async {
      Map<String, dynamic>? receivedJson;

      final mockClient = MockClient((request) async {
        if (request.method == 'POST' && request.url.path == '/v2/playlists') {
          receivedJson = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'data': {
                'id': 'new-pl-777',
                'type': 'playlists',
                'attributes': {'name': 'New Mix'}
              }
            }),
            201,
          );
        }
        return http.Response('Not Found', 404);
      });

      final service = TidalService.create(client: mockClient);
      final server = _server(token: _validToken());

      final res = await service.createPlaylist(server, title: 'New Mix', description: 'Great tracks');

      expect(receivedJson?['data']?['attributes']?['name'], 'New Mix');
      expect(receivedJson?['data']?['attributes']?['description'], 'Great tracks');
      expect(res['id'], 'new-pl-777');
    });

    test('TidalHomeItem accurately classifies mixes, playlists, albums, artists, tracks, and my tracks', () {
      // 1. Playlist with UUID even when type is missing / HORIZONTAL_LIST
      final plItem = TidalHomeItem.fromJson({
        'uuid': 'c8273bd7-0000-1111-2222-333344445555',
        'title': 'Chill Hits',
        'numberOfTracks': 30,
        'creator': {'name': 'TIDAL', 'id': 0},
      }, typeHint: 'HORIZONTAL_LIST');
      expect(plItem.isPlaylist, isTrue);
      expect(plItem.isAlbum, isFalse);

      // 2. Mix with mixType
      final mixItem = TidalHomeItem.fromJson({
        'id': 'mix-001',
        'title': 'Daily Discovery',
        'mixType': 'DAILY_MIX',
      }, typeHint: 'SHORTCUT_LIST');
      expect(mixItem.isMix, isTrue);
      expect(mixItem.isPlaylist, isFalse);

      // 3. Album with numeric ID and cover
      final albumItem = TidalHomeItem.fromJson({
        'id': 1234567,
        'title': 'A Beautiful Album',
        'cover': 'cover-uuid',
        'artist': {'name': 'Great Artist'},
      }, typeHint: 'HORIZONTAL_LIST');
      expect(albumItem.isAlbum, isTrue);
      expect(albumItem.isPlaylist, isFalse);
      expect(albumItem.isMix, isFalse);

      // 4. Artist with picture
      final artistItem = TidalHomeItem.fromJson({
        'id': 99999,
        'name': 'Famous Singer',
        'picture': 'pic-uuid',
      }, typeHint: 'HORIZONTAL_LIST');
      expect(artistItem.isArtist, isTrue);
      expect(artistItem.isAlbum, isFalse);

      // 5. My Tracks shortcut
      final myTracksItem = TidalHomeItem.fromJson({
        'id': 'tidal://my-collection/tracks',
        'title': 'My Tracks',
      }, typeHint: 'SHORTCUT_LIST');
      expect(myTracksItem.isMyTracks, isTrue);
    });
  });
}
