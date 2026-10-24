import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/features/player/widgets/ambient_background.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flick/widgets/common/display_mode_wrapper.dart';

/// Gradient base + blurred current-song album art behind pushed routes.
/// Matches the MainShell / SettingsScaffold background so screens pushed
/// onto the navigator don't fall through to black.
///
/// Also re-asserts the user's refresh-rate preference when the screen mounts:
/// this shell wraps every TIDAL route (hub, album, artist, playlist, mix,
/// search), and none of them used to carry a [DisplayModeWrapper], so Android's
/// dynamic-refresh-rate daemon could leave the panel at 60 Hz until the app was
/// backgrounded and resumed.
class BlurredSongBackground extends ConsumerWidget {
  final Widget child;

  const BlurredSongBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (AmbientBackgroundScope.isPresent(context)) {
      return DisplayModeWrapper(child: child);
    }
    final currentSong = ref.watch(currentSongProvider);
    return DisplayModeWrapper(
      child: Stack(
        children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: AppColors.backgroundGradient),
            ),
          ),
          Positioned.fill(child: AmbientBackground(song: currentSong)),
          Positioned.fill(child: child),
        ],
      ),
    );
  }
}
