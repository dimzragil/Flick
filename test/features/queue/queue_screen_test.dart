import 'package:flick/features/queue/screens/queue_screen.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flick/services/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _suggested = Song(
  id: 'suggested-1',
  title: 'Suggested song',
  artist: 'Suggested artist',
  duration: Duration(minutes: 3),
  fileType: 'FLAC',
  remoteId: 'suggested-1',
);

void main() {
  testWidgets('queue tabs render suggestions and an empty state', (
    tester,
  ) async {
    await tester.pumpWidget(_queueApp(suggestions: const []));
    expect(find.text('Play queue'), findsOneWidget);
    expect(find.text('Suggested tracks'), findsOneWidget);

    await tester.tap(find.text('Suggested tracks'));
    await tester.pumpAndSettle();
    expect(
      find.text('No suggested tracks available for this track'),
      findsOneWidget,
    );

    await tester.pumpWidget(_queueApp(suggestions: [_suggested]));
    await tester.tap(find.text('Suggested tracks'));
    await tester.pumpAndSettle();
    expect(find.text('Suggested song'), findsOneWidget);
    expect(find.text('Suggested artist'), findsOneWidget);
  });

  testWidgets(
    'tapping a suggestion plays it and keeps the suggested tab open',
    (tester) async {
      final fakePlayer = _FakePlayerNotifier(
        const PlayerState(
          currentSong: Song(
            id: 'current',
            title: 'Current song',
            artist: 'Current artist',
            duration: Duration(minutes: 3),
            fileType: 'FLAC',
          ),
          queue: [
            Song(
              id: 'manual',
              title: 'Manual song',
              artist: 'Manual artist',
              duration: Duration(minutes: 3),
              fileType: 'FLAC',
            ),
          ],
          upNext: [
            Song(
              id: 'up-next',
              title: 'Up next song',
              artist: 'Queue artist',
              duration: Duration(minutes: 3),
              fileType: 'FLAC',
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        _queueApp(suggestions: [_suggested], fakePlayer: fakePlayer),
      );
      await tester.tap(find.text('Suggested tracks'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Suggested song'));
      await tester.pumpAndSettle();

      expect(fakePlayer.playedSong, _suggested);
      expect(fakePlayer.state.currentSong, _suggested);
      expect(fakePlayer.state.upNext.single.id, 'up-next');
      expect(fakePlayer.state.queue.single.id, 'manual');
      expect(find.text('Suggested song'), findsOneWidget);
    },
  );
}

Widget _queueApp({
  required List<Song> suggestions,
  _FakePlayerNotifier? fakePlayer,
}) => ProviderScope(
  key: UniqueKey(),
  overrides: [
    playerProvider.overrideWith(
      () => fakePlayer ?? _FakePlayerNotifier(const PlayerState()),
    ),
    suggestedTracksProvider.overrideWith((ref) async => suggestions),
    playerServiceProvider.overrideWithValue(_PlayerServiceStub()),
  ],
  child: const MaterialApp(home: QueueScreen()),
);

class _FakePlayerNotifier extends PlayerNotifier {
  final PlayerState initialState;
  Song? playedSong;

  _FakePlayerNotifier(this.initialState);

  @override
  PlayerState build() => initialState;

  @override
  Future<void> playSuggestedTrack(Song song) async {
    playedSong = song;
    state = state.copyWith(currentSong: song);
  }
}

class _PlayerServiceStub implements PlayerService {
  @override
  bool isRadioTrack(String songId) => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
