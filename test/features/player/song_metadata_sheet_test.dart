import 'dart:convert';

import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/features/player/widgets/song_metadata_sheet.dart';
import 'package:flick/features/tidal/providers/tidal_providers.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/sources/network_source_service.dart';
import 'package:flick/services/sources/tidal_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

NetworkServerEntity _server() {
  return NetworkServerEntity()
    ..id = 9
    ..label = 'Tidal'
    ..protocol = 'tidal'
    ..baseUrl = TidalService.tidalBaseUrl
    ..username = null
    ..token = _validToken();
}

/// A far-future token blob so [TidalService._ensureValidToken] skips refresh.
String _validToken() => jsonEncode({
  'access_token': 'acc-xyz',
  'refresh_token': 'ref-xyz',
  'user_id': 'user-1',
  'country_code': 'NO',
  'expires_at_ms': DateTime.now()
      .add(const Duration(hours: 1))
      .millisecondsSinceEpoch,
});

const Song _tidalSong = Song(
  id: 'tidal-1',
  title: 'Get Lucky',
  artist: 'Daft Punk',
  duration: Duration(minutes: 6),
  fileType: 'FLAC',
  sourceType: NetworkProtocol.tidal,
  remoteId: '20115564',
);

/// Pumps the sheet with a mock TIDAL HTTP client and server provider.
Future<void> _pumpSheet(
  WidgetTester tester, {
  required http.Client client,
}) async {
  final previous = TidalService.instance;
  TidalService.instance = TidalService.create(client: client);
  addTearDown(() => TidalService.instance = previous);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tidalServerProvider.overrideWith(
          () => _MockTidalServerNotifier(_server()),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: SongMetadataSheet(song: _tidalSong)),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('renders credits grouped by role from the live array shape', (
    tester,
  ) async {
    final client = MockClient((request) async {
      if (request.url.path == '/v1/tracks/20115564/credits') {
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
              ],
            },
          ]),
          200,
        );
      }
      return http.Response('Not Found', 404);
    });

    await _pumpSheet(tester, client: client);
    await tester.pumpAndSettle();

    expect(find.text('Credits'), findsOneWidget);
    expect(find.text('Producer'), findsOneWidget);
    expect(find.text('Thomas Bangalter'), findsOneWidget);
    expect(find.text('Composer'), findsOneWidget);
    expect(find.text('Pharrell Williams, Nile Rodgers'), findsOneWidget);
    expect(find.text('Failed to load credits'), findsNothing);
  });

  testWidgets('shows the genuine empty state for a creditless track', (
    tester,
  ) async {
    final client = MockClient((request) async => http.Response('[]', 200));

    await _pumpSheet(tester, client: client);
    await tester.pumpAndSettle();

    expect(find.text('No credits available for this track'), findsOneWidget);
    expect(find.text('Failed to load credits'), findsNothing);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('shows a failure state on API error and retry reloads credits', (
    tester,
  ) async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (calls == 1) {
        return http.Response('server broke', 500);
      }
      return http.Response(
        jsonEncode([
          {
            'type': 'Composer',
            'contributors': [
              {'name': 'Nile Rodgers', 'id': 30528},
            ],
          },
        ]),
        200,
      );
    });

    await _pumpSheet(tester, client: client);
    await tester.pumpAndSettle();

    expect(find.text('Failed to load credits'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('No credits available for this track'), findsNothing);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('Composer'), findsOneWidget);
    expect(find.text('Nile Rodgers'), findsOneWidget);
    expect(find.text('Failed to load credits'), findsNothing);
  });
}

class _MockTidalServerNotifier extends TidalServerNotifier {
  final NetworkServerEntity? _server;
  _MockTidalServerNotifier(this._server);

  @override
  Future<NetworkServerEntity?> build() async {
    return _server;
  }
}
