import 'package:flick/features/player/widgets/bit_perfect_indicator.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/sources/tidal_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mixerOutputRateLabel', () {
    test('shows the real device native rate when available', () {
      expect(BitPerfectIndicator.mixerOutputRateLabel(44100), '44.1 kHz');
      expect(BitPerfectIndicator.mixerOutputRateLabel(48000), '48.0 kHz');
      expect(BitPerfectIndicator.mixerOutputRateLabel(192000), '192.0 kHz');
    });

    test('labels the 48 kHz fallback as assumed when unavailable', () {
      expect(
        BitPerfectIndicator.mixerOutputRateLabel(null),
        '48.0 kHz (assumed)',
      );
      expect(BitPerfectIndicator.mixerOutputRateLabel(0), '48.0 kHz (assumed)');
    });
  });

  group('mixerBitDepthLabel', () {
    test('24-bit is inferred preserved when hiResInternal is advertised', () {
      expect(
        BitPerfectIndicator.mixerBitDepthLabel(24, preservesHiRes: true),
        '24-bit → 24-bit',
      );
    });

    test('24-bit is inferred truncated without hiResInternal', () {
      expect(
        BitPerfectIndicator.mixerBitDepthLabel(24, preservesHiRes: false),
        '24-bit → 16-bit',
      );
    });

    test('non-24-bit depths pass through unchanged', () {
      expect(
        BitPerfectIndicator.mixerBitDepthLabel(16, preservesHiRes: false),
        '16-bit',
      );
      expect(
        BitPerfectIndicator.mixerBitDepthLabel(32, preservesHiRes: true),
        '32-bit',
      );
    });
  });

  group('getSongQuality', () {
    const baseSong = Song(
      id: 'song-1',
      title: 'Track',
      artist: 'Artist',
      duration: Duration(minutes: 3),
      fileType: 'flac',
      bitDepth: 16,
      sampleRate: 44100,
    );

    test('evaluates 16-bit FLAC as CD', () {
      expect(BitPerfectIndicator.getSongQuality(baseSong), 'CD');
    });

    test('evaluates 24-bit FLAC as HR', () {
      final hrSong = baseSong.copyWith(bitDepth: 24, sampleRate: 96000);
      expect(BitPerfectIndicator.getSongQuality(hrSong), 'HR');
    });

    test('evaluates lossy MP3/AAC fileType as HQ', () {
      final mp3Song = baseSong.copyWith(fileType: 'mp3');
      expect(BitPerfectIndicator.getSongQuality(mp3Song), 'HQ');
      final aacSong = baseSong.copyWith(fileType: 'aac');
      expect(BitPerfectIndicator.getSongQuality(aacSong), 'HQ');
    });

    test('evaluates song with lossy TidalStreamResolution as HQ even if song was tagged flac', () {
      const lossyResolution = TidalStreamResolution(
        url: 'http://test',
        isDash: false,
        sampleRate: 44100,
        bitDepth: 16,
        audioQuality: 'HIGH',
        codec: 'aac',
        ext: 'm4a',
      );
      expect(
        BitPerfectIndicator.getSongQuality(baseSong, lossyResolution),
        'HQ',
      );
    });

    test('evaluates song with Hi-Res TidalStreamResolution as HR', () {
      const hrResolution = TidalStreamResolution(
        url: 'http://test',
        isDash: false,
        sampleRate: 96000,
        bitDepth: 24,
        audioQuality: 'HI_RES_LOSSLESS',
        codec: 'flac',
      );
      expect(
        BitPerfectIndicator.getSongQuality(baseSong, hrResolution),
        'HR',
      );
    });
  });
}
