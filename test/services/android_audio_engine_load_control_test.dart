import 'dart:io';

import 'package:flick/services/android_audio_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('speaker load control (direct CDN)', () {
    test('starts later and rebuffers deeper than the ExoPlayer defaults', () {
      final control = directCdnAudioLoadConfiguration.androidLoadControl;
      expect(control, isNotNull);
      expect(
        control!.bufferForPlaybackDuration,
        const Duration(milliseconds: 7500),
      );
      expect(
        control.bufferForPlaybackAfterRebufferDuration,
        const Duration(seconds: 10),
      );
      // ExoPlayer defaults: 2.5 s before playback, 5 s after a rebuffer. Direct
      // playback starts on a cold CDN read, so both must be larger.
      expect(
        control.bufferForPlaybackDuration,
        greaterThan(const Duration(milliseconds: 2500)),
      );
      expect(
        control.bufferForPlaybackAfterRebufferDuration,
        greaterThan(const Duration(seconds: 5)),
      );
    });

    test('no speaker player is constructed without the load control', () {
      // Guard against the two-construction-site bug: the main player and the
      // crossfade secondary must both come from createSpeakerAudioPlayer().
      // A bare AudioPlayer() anywhere in lib/ would silently run on ExoPlayer
      // defaults and reintroduce the start stutter this migration fixes.
      final offenders = <String>[];
      final playerCtor = RegExp(r'just_audio\.AudioPlayer\(([^;]*?)\)');

      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = entity.readAsStringSync();
        for (final match in playerCtor.allMatches(source)) {
          final args = match.group(1) ?? '';
          if (!args.contains('audioLoadConfiguration')) {
            offenders.add('${entity.path}: ${match.group(0)}');
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'construct speaker players through createSpeakerAudioPlayer() '
            'so the direct-CDN load control always applies',
      );
    });
  });
}
