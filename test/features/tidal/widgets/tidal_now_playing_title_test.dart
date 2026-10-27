import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/features/tidal/widgets/tidal_now_playing_title.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flick/services/sources/network_source_service.dart';
import 'package:flick/services/sources/tidal_service.dart';
import 'package:flick/widgets/common/song_badges.dart';

class _CurrentSongController extends Notifier<Song?> {
  @override
  Song? build() => null;

  void set(Song? song) => state = song;
}

final _currentSongControllerProvider =
    NotifierProvider<_CurrentSongController, Song?>(_CurrentSongController.new);

Song _song({
  required String id,
  String? remoteId,
  String? sourceType = NetworkProtocol.tidal,
  int? bitDepth,
}) {
  return Song(
    id: id,
    title: 'Song $id',
    artist: 'Test Artist',
    duration: const Duration(seconds: 180),
    fileType: 'flac',
    sourceType: sourceType,
    remoteId: remoteId ?? id,
    bitDepth: bitDepth,
  );
}

TidalStreamResolution _resolution(
  String tier, {
  int bitDepth = 24,
  bool explicitBitDepth = true,
}) {
  return TidalStreamResolution(
    url: '',
    isDash: false,
    sampleRate: 44100,
    bitDepth: bitDepth,
    isBitDepthExplicit: explicitBitDepth,
    audioQuality: tier,
  );
}

Widget _app(List<Widget> children, {bool isPlaying = true}) {
  return ProviderScope(
    overrides: [
      isPlayingProvider.overrideWithValue(isPlaying),
      currentSongProvider.overrideWith(
        (ref) => ref.watch(_currentSongControllerProvider),
      ),
    ],
    child: MaterialApp(
      home: Scaffold(body: Column(children: children)),
    ),
  );
}

void _setCurrent(WidgetTester tester, Song? song) {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(TidalNowPlayingTitle).first),
  );
  container.read(_currentSongControllerProvider.notifier).set(song);
}

Color? _titleColor(WidgetTester tester, String title) {
  final text = tester.widget<Text>(find.text(title));
  return text.style?.color;
}

const _baseStyle = TextStyle(color: AppColors.textPrimary, fontSize: 14);

TidalNowPlayingTitle _title(
  String title,
  String songId, {
  ValueNotifier<int>? version,
  TidalStreamResolution? Function(String)? lookup,
  bool isHiRes = false,
}) {
  return TidalNowPlayingTitle(
    title: title,
    songId: songId,
    isHiRes: isHiRes ? true : null,
    style: _baseStyle,
    resolutionVersionListenable: version ?? ValueNotifier<int>(0),
    resolutionLookup: lookup ?? (_) => null,
  );
}

void main() {
  group('tidalNowPlayingTitleColor', () {
    test('HI_RES and HI_RES_LOSSLESS are gold', () {
      expect(
        tidalNowPlayingTitleColor(_resolution('HI_RES_LOSSLESS')),
        AppColors.nowPlayingHiRes,
      );
      expect(
        tidalNowPlayingTitleColor(_resolution('HI_RES')),
        AppColors.nowPlayingHiRes,
      );
    });

    test('LOSSLESS and HIGH are cyan', () {
      expect(
        tidalNowPlayingTitleColor(_resolution('LOSSLESS', bitDepth: 16)),
        AppColors.nowPlayingCdAndBelow,
      );
      expect(
        tidalNowPlayingTitleColor(_resolution('HIGH', bitDepth: 16)),
        AppColors.nowPlayingCdAndBelow,
      );
    });

    test('tier wins when a Hi-Res tier delivers 16-bit audio', () {
      expect(
        tidalNowPlayingTitleColor(_resolution('HI_RES', bitDepth: 16)),
        AppColors.nowPlayingHiRes,
      );
      expect(
        tidalNowPlayingTitleColor(_resolution('HI_RES_LOSSLESS', bitDepth: 16)),
        AppColors.nowPlayingHiRes,
      );
    });

    test('unknown tier falls back to delivered bit depth', () {
      expect(
        tidalNowPlayingTitleColor(_resolution('DOLBY_ATMOS', bitDepth: 24)),
        AppColors.nowPlayingHiRes,
      );
      expect(
        tidalNowPlayingTitleColor(_resolution('DOLBY_ATMOS', bitDepth: 16)),
        AppColors.nowPlayingCdAndBelow,
      );
    });

    test('unknown tier and unknown bit depth stays default', () {
      expect(
        tidalNowPlayingTitleColor(
          _resolution('UNKNOWN', explicitBitDepth: false),
        ),
        isNull,
      );
    });

    test('null resolution stays default', () {
      expect(tidalNowPlayingTitleColor(null), isNull);
    });
  });

  group('TidalNowPlayingTitle widget', () {
    testWidgets('Hi-Res current track title is gold', (tester) async {
      final version = ValueNotifier<int>(0);
      final song = _song(id: 'tidal_1_101', remoteId: '101');
      final resolutions = {'101': _resolution('HI_RES_LOSSLESS')};

      await tester.pumpWidget(
        _app([
          _title(
            'Hi-Res Track',
            song.id,
            version: version,
            lookup: (trackId) => resolutions[trackId],
          ),
        ]),
      );
      _setCurrent(tester, song);
      await tester.pump();

      expect(_titleColor(tester, 'Hi-Res Track'), AppColors.nowPlayingHiRes);
    });

    testWidgets('LOSSLESS current track title is cyan', (tester) async {
      final song = _song(id: 'tidal_1_102', remoteId: '102');
      final resolutions = {'102': _resolution('LOSSLESS', bitDepth: 16)};

      await tester.pumpWidget(
        _app([
          _title(
            'CD Track',
            song.id,
            lookup: (trackId) => resolutions[trackId],
          ),
        ]),
      );
      _setCurrent(tester, song);
      await tester.pump();

      expect(_titleColor(tester, 'CD Track'), AppColors.nowPlayingCdAndBelow);
    });

    testWidgets('AAC fallback (HIGH) is cyan even when catalog says 24-bit', (
      tester,
    ) async {
      final song = _song(id: 'tidal_1_103', remoteId: '103', bitDepth: 24);
      final resolutions = {'103': _resolution('HIGH', bitDepth: 16)};

      await tester.pumpWidget(
        _app([
          _title(
            'Fell Back Track',
            song.id,
            lookup: (trackId) => resolutions[trackId],
            isHiRes: true,
          ),
        ]),
      );
      _setCurrent(tester, song);
      await tester.pump();

      expect(
        _titleColor(tester, 'Fell Back Track'),
        AppColors.nowPlayingCdAndBelow,
      );
    });

    testWidgets('non-current rows keep their default title color', (
      tester,
    ) async {
      final current = _song(id: 'tidal_1_104', remoteId: '104');
      final other = _song(id: 'tidal_1_105', remoteId: '105');
      final resolutions = {
        '104': _resolution('HI_RES_LOSSLESS'),
        '105': _resolution('HI_RES_LOSSLESS'),
      };

      await tester.pumpWidget(
        _app([
          _title(
            'Current Track',
            current.id,
            lookup: (trackId) => resolutions[trackId],
          ),
          _title(
            'Other Track',
            other.id,
            lookup: (trackId) => resolutions[trackId],
          ),
        ]),
      );
      _setCurrent(tester, current);
      await tester.pump();

      expect(_titleColor(tester, 'Current Track'), AppColors.nowPlayingHiRes);
      expect(_titleColor(tester, 'Other Track'), AppColors.textPrimary);
    });

    testWidgets('paused current track is still colored', (tester) async {
      final song = _song(id: 'tidal_1_106', remoteId: '106');
      final resolutions = {'106': _resolution('LOSSLESS', bitDepth: 16)};

      await tester.pumpWidget(
        _app([
          _title(
            'Paused Track',
            song.id,
            lookup: (trackId) => resolutions[trackId],
          ),
        ], isPlaying: false),
      );
      _setCurrent(tester, song);
      await tester.pump();

      expect(
        _titleColor(tester, 'Paused Track'),
        AppColors.nowPlayingCdAndBelow,
      );
    });

    testWidgets('changing the current track reverts the old row and colors '
        'the new row', (tester) async {
      final first = _song(id: 'tidal_1_107', remoteId: '107');
      final second = _song(id: 'tidal_1_108', remoteId: '108');
      final resolutions = {
        '107': _resolution('HI_RES_LOSSLESS'),
        '108': _resolution('LOSSLESS', bitDepth: 16),
      };

      await tester.pumpWidget(
        _app([
          _title(
            'First Track',
            first.id,
            lookup: (trackId) => resolutions[trackId],
          ),
          _title(
            'Second Track',
            second.id,
            lookup: (trackId) => resolutions[trackId],
          ),
        ]),
      );
      _setCurrent(tester, first);
      await tester.pump();
      expect(_titleColor(tester, 'First Track'), AppColors.nowPlayingHiRes);
      expect(_titleColor(tester, 'Second Track'), AppColors.textPrimary);

      _setCurrent(tester, second);
      await tester.pump();
      expect(_titleColor(tester, 'First Track'), AppColors.textPrimary);
      expect(
        _titleColor(tester, 'Second Track'),
        AppColors.nowPlayingCdAndBelow,
      );
    });

    testWidgets('null current track leaves every row at default', (
      tester,
    ) async {
      final song = _song(id: 'tidal_1_109', remoteId: '109');
      final resolutions = {'109': _resolution('HI_RES_LOSSLESS')};

      await tester.pumpWidget(
        _app([
          _title(
            'No Current Track',
            song.id,
            lookup: (trackId) => resolutions[trackId],
          ),
        ]),
      );
      _setCurrent(tester, null);
      await tester.pump();

      expect(_titleColor(tester, 'No Current Track'), AppColors.textPrimary);
    });

    testWidgets('row stays default while resolving, then colors on resolve', (
      tester,
    ) async {
      final version = ValueNotifier<int>(0);
      final song = _song(id: 'tidal_1_110', remoteId: '110');
      final resolutions = <String, TidalStreamResolution>{};

      await tester.pumpWidget(
        _app([
          _title(
            'Resolving Track',
            song.id,
            version: version,
            lookup: (trackId) => resolutions[trackId],
          ),
        ]),
      );
      _setCurrent(tester, song);
      await tester.pump();
      expect(_titleColor(tester, 'Resolving Track'), AppColors.textPrimary);

      resolutions['110'] = _resolution('HI_RES_LOSSLESS');
      version.value++;
      await tester.pump();

      expect(_titleColor(tester, 'Resolving Track'), AppColors.nowPlayingHiRes);
    });

    testWidgets('Hub rows match the current track by TIDAL track id', (
      tester,
    ) async {
      final song = _song(id: 'tidal_1_hub-1', remoteId: 'hub-1');
      final resolutions = {'hub-1': _resolution('HI_RES_LOSSLESS')};

      await tester.pumpWidget(
        _app([
          TidalNowPlayingTitle(
            title: 'Hub Track',
            tidalTrackId: 'hub-1',
            style: _baseStyle,
            resolutionVersionListenable: ValueNotifier<int>(0),
            resolutionLookup: (trackId) => resolutions[trackId],
          ),
        ]),
      );
      _setCurrent(tester, song);
      await tester.pump();

      expect(_titleColor(tester, 'Hub Track'), AppColors.nowPlayingHiRes);
    });

    testWidgets('local current tracks are never colored', (tester) async {
      final song = _song(id: 'local-1', remoteId: 'local-1', sourceType: null);
      final resolutions = {'local-1': _resolution('HI_RES_LOSSLESS')};

      await tester.pumpWidget(
        _app([
          _title(
            'Local Track',
            song.id,
            lookup: (trackId) => resolutions[trackId],
          ),
        ]),
      );
      _setCurrent(tester, song);
      await tester.pump();

      expect(_titleColor(tester, 'Local Track'), AppColors.textPrimary);
    });

    testWidgets('only the title color changes; badges are preserved', (
      tester,
    ) async {
      final song = _song(id: 'tidal_1_111', remoteId: '111');
      final resolutions = {'111': _resolution('HI_RES_LOSSLESS')};

      await tester.pumpWidget(
        _app([
          _title(
            'Badged Track',
            song.id,
            lookup: (trackId) => resolutions[trackId],
            isHiRes: true,
          ),
        ]),
      );
      _setCurrent(tester, song);
      await tester.pump();

      expect(_titleColor(tester, 'Badged Track'), AppColors.nowPlayingHiRes);
      expect(find.byType(HiResBadge), findsOneWidget);
    });
  });
}
