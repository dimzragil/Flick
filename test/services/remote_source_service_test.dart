import 'package:flick/models/song.dart';
import 'package:flick/services/remote_source_service.dart';
import 'package:flick/services/sources/network_source_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('resolvedStreamLog returns null for local songs', () {
    const song = Song(
      id: '1',
      title: 'Local',
      artist: 'Nobody',
      duration: Duration.zero,
      fileType: 'flac',
    );
    expect(RemoteSourceService.instance.resolvedStreamLog(song), isNull);
  });

  test(
    'resolvedStreamLog returns null for TIDAL songs with no cached resolution',
    () {
      const song = Song(
        id: '2',
        title: 'Uncached',
        artist: 'Nobody',
        duration: Duration.zero,
        fileType: 'flac',
        sourceType: NetworkProtocol.tidal,
        remoteId: '999999999',
      );
      expect(RemoteSourceService.instance.resolvedStreamLog(song), isNull);
    },
  );
}
