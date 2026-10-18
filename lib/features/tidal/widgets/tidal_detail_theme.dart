import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../services/color_extraction_service.dart';

/// Dominant-color state shared by the TIDAL detail screens.
///
/// Wraps [ColorExtractionService] (remote cover URLs are resolved through the
/// shared image cache, so this never re-downloads artwork already on screen)
/// and exposes the extracted color for theming the action capsule, artwork
/// glows and [TidalColorWash]. The color complements the shared
/// `BlurredSongBackground`; it never replaces it.
mixin TidalDominantColor<T extends StatefulWidget> on State<T> {
  final ColorExtractionService _colorService = ColorExtractionService();

  Color? _dominantColor;
  String? _colorSourceUrl;

  /// The artwork's dominant color, or null until extraction completes (or
  /// when the artwork exposes no extractable color).
  Color? get dominantColor => _dominantColor;

  /// Base background tint handed to [AdaptiveColorProvider], blended the same
  /// way as the local album screen's themed background.
  Color get themedBackground => _dominantColor == null
      ? AppColors.background
      : Color.lerp(AppColors.background, _dominantColor!, _backgroundBlend)!;

  /// Schedules a dominant-color extraction for [imageUrl] once per URL.
  ///
  /// Safe to call from `build`: the extraction itself runs in a post-frame
  /// callback and [setState] only fires when the color resolves for the URL
  /// that is still current.
  void maybeExtractDominantColor(String? imageUrl) {
    if (imageUrl == null || imageUrl.isEmpty || imageUrl == _colorSourceUrl) {
      return;
    }
    _colorSourceUrl = imageUrl;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final color = await _colorService.extractDominantColor(imageUrl);
      if (!mounted || _colorSourceUrl != imageUrl || color == null) return;
      setState(() => _dominantColor = color);
    });
  }
}

const double _backgroundBlend = 0.22;

/// Translucent dominant-color wash layered over the shared
/// `BlurredSongBackground`.
///
/// The wash fades in when the page's artwork resolves and animates between
/// colors when the artwork changes — mirroring the local album screen's
/// background tween. Keep it translucent: the blurred current-song backdrop
/// must stay visible underneath. Motion respects reduced-motion and the
/// app-wide animations setting through [AppConstants.animationSlow].
class TidalColorWash extends StatelessWidget {
  const TidalColorWash({super.key, required this.color});

  /// Dominant color to wash with; null leaves the backdrop untouched.
  final Color? color;

  static const double _washAlpha = 0.22;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: TweenAnimationBuilder<Color?>(
        // TweenAnimationBuilder requires a non-null end; null simply means
        // "no wash yet" and settles on fully transparent.
        tween: ColorTween(
          begin: Colors.transparent,
          end: color?.withValues(alpha: _washAlpha) ?? Colors.transparent,
        ),
        duration: AppConstants.animationSlow,
        curve: Curves.easeOut,
        builder: (context, animatedColor, _) => ColoredBox(
          color: animatedColor ?? Colors.transparent,
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}
