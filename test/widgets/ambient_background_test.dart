import 'package:flick/features/player/widgets/ambient_background.dart';
import 'package:flick/models/song.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('AmbientBackground renders SizedBox.shrink when song is null', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AmbientBackground(song: null),
        ),
      ),
    );

    expect(find.byType(AmbientBackground), findsOneWidget);
    expect(find.byType(RawImage), findsNothing);
  });

  testWidgets('AmbientBackground renders SizedBox.shrink when inside AmbientBackgroundScope', (tester) async {
    const song = Song(
      id: '1',
      title: 'Test',
      artist: 'Artist',
      album: 'Album',
      duration: Duration(minutes: 2),
      fileType: 'mp3',
      albumArt: '/dummy/art.jpg',
      filePath: '/dummy/audio.mp3',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AmbientBackgroundScope(
            child: AmbientBackground(song: song),
          ),
        ),
      ),
    );

    expect(find.byType(AmbientBackground), findsOneWidget);
    expect(find.byType(RawImage), findsNothing);
  });
}
