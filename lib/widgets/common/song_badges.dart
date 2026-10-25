import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

/// Renders a song's title with optional Dolby Atmos, Hi-Res, and Explicit badges.
///
/// Badges appear immediately to the right of the title in the order:
/// [Flexible Text(title)] [Atmos icon?] [HI-RES badge?] [E badge?]
class SongTitleRow extends StatelessWidget {
  final String title;
  final TextStyle? style;
  final bool? isExplicit;
  final bool? isAtmos;
  final bool? isHiRes;
  final TextAlign? textAlign;
  final Color? badgeColor;
  final Color? badgeBackgroundColor;

  const SongTitleRow({
    super.key,
    required this.title,
    this.style,
    this.isExplicit,
    this.isAtmos,
    this.isHiRes,
    this.textAlign,
    this.badgeColor,
    this.badgeBackgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
            textAlign: textAlign,
          ),
        ),
        if (isAtmos == true) ...[
          const SizedBox(width: 4),
          DolbyAtmosIcon(
            color: badgeColor,
            backgroundColor: badgeBackgroundColor,
          ),
        ],
        if (isHiRes == true) ...[
          const SizedBox(width: 4),
          const HiResBadge(margin: EdgeInsets.zero),
        ],
        if (isExplicit == true) ...[
          const SizedBox(width: 4),
          ExplicitBadge(
            color: badgeColor,
            backgroundColor: badgeBackgroundColor,
          ),
        ],
      ],
    );
  }
}

/// Shared badge widget displaying the 'E' (Explicit) indicator on song rows and album cards.
class ExplicitBadge extends StatelessWidget {
  final Color? color;
  final Color? backgroundColor;

  const ExplicitBadge({super.key, this.color, this.backgroundColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
      decoration: BoxDecoration(
        color: backgroundColor ?? AppColors.glassBackgroundStrong,
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(
        'E',
        style: TextStyle(
          color: color ?? AppColors.textSecondary,
          fontSize: 8,
          fontWeight: FontWeight.bold,
          height: 1.0,
        ),
      ),
    );
  }
}

/// Shared badge widget displaying the 'HI-RES' indicator on song rows.
class HiResBadge extends StatelessWidget {
  final EdgeInsetsGeometry margin;

  const HiResBadge({super.key, this.margin = const EdgeInsets.only(left: 6)});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: const Color(0xFFE5A93C), width: 0.75),
      ),
      child: const Text(
        'HI-RES',
        style: TextStyle(
          color: Color(0xFFE5A93C),
          fontSize: 9,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// Shared icon widget displaying the Dolby Atmos emblem on song rows.
class DolbyAtmosIcon extends StatelessWidget {
  final Color? color;
  final Color? backgroundColor;

  const DolbyAtmosIcon({super.key, this.color, this.backgroundColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1.5),
      decoration: BoxDecoration(
        color: backgroundColor ?? AppColors.glassBackgroundStrong,
        borderRadius: BorderRadius.circular(2),
      ),
      child: SizedBox(
        width: 11,
        height: 7,
        child: CustomPaint(
          painter: _DolbyDoubleDPainter(
            color: color ?? AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _DolbyDoubleDPainter extends CustomPainter {
  final Color color;

  const _DolbyDoubleDPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final h = size.height;
    final w = size.width;
    const gap = 1.0;
    final dWidth = (w - gap) / 2;
    const stroke = 1.0;

    // Left D (vertical bar on left, curve extending right to center)
    final leftOuter = Path()
      ..moveTo(0, 0)
      ..lineTo(0, h)
      ..lineTo(dWidth * 0.45, h)
      ..arcToPoint(
        Offset(dWidth * 0.45, 0),
        radius: Radius.elliptical(dWidth * 0.55, h / 2),
        clockwise: false,
      )
      ..close();

    final leftInner = Path()
      ..moveTo(stroke, stroke)
      ..lineTo(stroke, h - stroke)
      ..lineTo(dWidth * 0.45, h - stroke)
      ..arcToPoint(
        Offset(dWidth * 0.45, stroke),
        radius: Radius.elliptical(
          (dWidth * 0.55 - stroke).clamp(0.1, double.infinity),
          ((h - 2 * stroke) / 2).clamp(0.1, double.infinity),
        ),
        clockwise: false,
      )
      ..close();

    final leftD = Path.combine(PathOperation.difference, leftOuter, leftInner);
    canvas.drawPath(leftD, paint);

    // Right D (vertical bar on right, curve extending left to center)
    final rightOuter = Path()
      ..moveTo(w, 0)
      ..lineTo(w, h)
      ..lineTo(w - dWidth * 0.45, h)
      ..arcToPoint(
        Offset(w - dWidth * 0.45, 0),
        radius: Radius.elliptical(dWidth * 0.55, h / 2),
        clockwise: true,
      )
      ..close();

    final rightInner = Path()
      ..moveTo(w - stroke, stroke)
      ..lineTo(w - stroke, h - stroke)
      ..lineTo(w - dWidth * 0.45, h - stroke)
      ..arcToPoint(
        Offset(w - dWidth * 0.45, stroke),
        radius: Radius.elliptical(
          (dWidth * 0.55 - stroke).clamp(0.1, double.infinity),
          ((h - 2 * stroke) / 2).clamp(0.1, double.infinity),
        ),
        clockwise: true,
      )
      ..close();

    final rightD = Path.combine(
      PathOperation.difference,
      rightOuter,
      rightInner,
    );
    canvas.drawPath(rightD, paint);
  }

  @override
  bool shouldRepaint(covariant _DolbyDoubleDPainter oldDelegate) =>
      oldDelegate.color != color;
}
