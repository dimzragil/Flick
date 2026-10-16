import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';

/// Glass tab pill used by the TIDAL tab/category selectors with an animated
/// active indicator.
///
/// Replaces the previous ChoiceChip/FilterChip look: the fill, border, and
/// label ease into the selected state over 200ms with [Curves.easeInOut]
/// instead of snapping. Mirrors the AnimatedContainer chip style used on the
/// full player screen for visual consistency. The tap ripple is preserved by
/// hosting the [InkWell] on a transparent [Material] above the animated fill.
class TidalTabPill extends StatelessWidget {
  const TidalTabPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.fontSize = 13,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    this.borderRadius = 19,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final double fontSize;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  /// Indicator animation timing (200ms, easeInOut).
  static const Duration _duration = Duration(milliseconds: 200);
  static const Curve _curve = Curves.easeInOut;

  /// Selected/unselected colors preserved from the previous chip styling.
  static const Color _selectedFill = Color(0x66FFFFFF);
  static const Color _selectedBorder = Color(0xD9FFFFFF);
  static const Color _selectedLabel = Color(0xD9FFFFFF);

  @override
  Widget build(BuildContext context) {
    // Honor the app-wide kill switch: no animation when disabled.
    final duration = AppConstants.animationNormal == Duration.zero
        ? Duration.zero
        : _duration;
    final radius = BorderRadius.circular(borderRadius);

    return RepaintBoundary(
      child: AnimatedContainer(
        duration: duration,
        curve: _curve,
        decoration: BoxDecoration(
          color: selected ? _selectedFill : AppColors.glassBackgroundStrong,
          borderRadius: radius,
          border: Border.all(
            color: selected ? _selectedBorder : AppColors.glassBorder,
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: Padding(
              padding: padding,
              child: AnimatedDefaultTextStyle(
                duration: duration,
                curve: _curve,
                style: TextStyle(
                  color: selected ? _selectedLabel : AppColors.textPrimary,
                  fontSize: fontSize,
                  fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                ),
                child: Text(label),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
