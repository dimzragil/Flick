import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/responsive.dart';

/// Wraps TIDAL loading skeletons in the dark-glass shimmer sweep.
///
/// The sweep is disabled when app-wide animations are off
/// ([AppConstants.setAnimationsEnabled]), leaving a static placeholder.
class TidalShimmer extends StatelessWidget {
  const TidalShimmer({super.key, required this.child});

  final Widget child;

  /// Skeleton fill + sweep highlight tuned for the dark glass theme.
  static const Color baseColor = AppColors.surface;
  static const Color highlightColor = AppColors.surfaceLight;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Shimmer.fromColors(
        baseColor: baseColor,
        highlightColor: highlightColor,
        period: const Duration(milliseconds: 1500),
        enabled: AppConstants.animationNormal != Duration.zero,
        child: child,
      ),
    );
  }
}

/// Solid rounded block used to compose skeletons (artwork, pills, banners).
class TidalSkeletonBox extends StatelessWidget {
  const TidalSkeletonBox({
    super.key,
    this.width,
    this.height,
    this.radius = AppConstants.radiusSm,
    this.shape = BoxShape.rectangle,
  });

  final double? width;
  final double? height;
  final double radius;
  final BoxShape shape;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: TidalShimmer.baseColor,
        shape: shape,
        borderRadius: shape == BoxShape.rectangle
            ? BorderRadius.circular(radius)
            : null,
      ),
    );
  }
}

/// Thin bar used to stand in for text lines.
class TidalSkeletonLine extends StatelessWidget {
  const TidalSkeletonLine({
    super.key,
    this.width,
    this.height = 10,
    this.radius = AppConstants.radiusXs,
  });

  final double? width;
  final double? height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return TidalSkeletonBox(width: width, height: height, radius: radius);
  }
}

/// One track/list row: artwork thumb + two text bars + trailing bar.
class _SkeletonTrackRow extends StatelessWidget {
  const _SkeletonTrackRow({
    required this.thumbSize,
    this.thumbRadius = AppConstants.radiusSm,
    this.trailingWidth = 32,
  });

  final double thumbSize;
  final double thumbRadius;
  final double? trailingWidth;

  @override
  Widget build(BuildContext context) {
    final thumb = context.scaleSize(thumbSize);
    final gap = context.scaleSize(AppConstants.spacingSm);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.scaleSize(5)),
      child: Row(
        children: [
          TidalSkeletonBox(width: thumb, height: thumb, radius: thumbRadius),
          SizedBox(width: gap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const TidalSkeletonLine(width: double.infinity, height: 12),
                SizedBox(height: context.scaleSize(6)),
                TidalSkeletonLine(width: context.scaleSize(120)),
              ],
            ),
          ),
          if (trailingWidth != null) ...[
            SizedBox(width: gap),
            TidalSkeletonLine(width: context.scaleSize(trailingWidth!)),
          ],
        ],
      ),
    );
  }
}

/// Section placeholder: optional title bar + horizontal card carousel.
class _SkeletonCarousel extends StatelessWidget {
  const _SkeletonCarousel();

  @override
  Widget build(BuildContext context) {
    final card = context.scaleSize(136);
    final gap = context.scaleSize(AppConstants.spacingSm);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TidalSkeletonLine(width: context.scaleSize(140), height: 16),
        SizedBox(height: gap),
        SizedBox(
          height: context.scaleSize(205),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: 3,
            separatorBuilder: (_, __) => SizedBox(width: gap),
            itemBuilder: (context, index) => SizedBox(
              width: card,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TidalSkeletonBox(
                    width: card,
                    height: card,
                    radius: AppConstants.radiusMd,
                  ),
                  SizedBox(height: gap),
                  TidalSkeletonLine(width: card * 0.85, height: 12),
                  SizedBox(height: context.scaleSize(6)),
                  TidalSkeletonLine(width: card * 0.55),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Hub feed placeholder: tab pills + two section carousels.
class TidalHubFeedSkeleton extends StatelessWidget {
  const TidalHubFeedSkeleton({super.key, this.sections = 2});

  final int sections;

  @override
  Widget build(BuildContext context) {
    return TidalShimmer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (var i = 0; i < 4; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                TidalSkeletonBox(
                  width: context.scaleSize(64),
                  height: context.scaleSize(32),
                  radius: AppConstants.radiusXl,
                ),
              ],
            ],
          ),
          SizedBox(height: context.scaleSize(AppConstants.spacingLg)),
          for (var s = 0; s < sections; s++) ...[
            const _SkeletonCarousel(),
            SizedBox(height: context.scaleSize(AppConstants.spacingLg)),
          ],
        ],
      ),
    );
  }
}

/// Track-list placeholder (hub playlists, search results, detail tracks).
class TidalListSkeleton extends StatelessWidget {
  const TidalListSkeleton({
    super.key,
    this.rows = 6,
    this.thumbSize = 48,
    this.thumbRadius = AppConstants.radiusSm,
    this.trailingWidth = 32,
  });

  final int rows;
  final double thumbSize;
  final double thumbRadius;
  final double? trailingWidth;

  @override
  Widget build(BuildContext context) {
    return TidalShimmer(
      child: Column(
        children: [
          for (var i = 0; i < rows; i++)
            _SkeletonTrackRow(
              thumbSize: thumbSize,
              thumbRadius: thumbRadius,
              trailingWidth: trailingWidth,
            ),
        ],
      ),
    );
  }
}

/// Album/artist loading placeholder: centered art + title lines + track rows.
class TidalDetailBodySkeleton extends StatelessWidget {
  const TidalDetailBodySkeleton({
    super.key,
    this.artSize = 180,
    this.circle = false,
    this.rows = 6,
  });

  final double artSize;
  final bool circle;
  final int rows;

  @override
  Widget build(BuildContext context) {
    final art = context.scaleSize(artSize);
    final pad = context.scaleSize(AppConstants.spacingMd);
    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(horizontal: pad),
      child: TidalShimmer(
        child: Column(
          children: [
            SizedBox(height: pad),
            TidalSkeletonBox(
              width: art,
              height: art,
              radius: AppConstants.radiusMd,
              shape: circle ? BoxShape.circle : BoxShape.rectangle,
            ),
            SizedBox(height: pad),
            TidalSkeletonLine(width: art * 0.9, height: 16),
            SizedBox(height: context.scaleSize(8)),
            TidalSkeletonLine(width: art * 0.6),
            SizedBox(height: context.scaleSize(AppConstants.spacingLg)),
            for (var i = 0; i < rows; i++)
              const _SkeletonTrackRow(thumbSize: 48),
          ],
        ),
      ),
    );
  }
}

/// Mix/playlist loading placeholder: full-bleed banner art + track rows.
class TidalBannerBodySkeleton extends StatelessWidget {
  const TidalBannerBodySkeleton({
    super.key,
    this.bannerHeight = 280,
    this.rows = 7,
  });

  final double bannerHeight;
  final int rows;

  @override
  Widget build(BuildContext context) {
    final pad = context.scaleSize(AppConstants.spacingMd);
    return SingleChildScrollView(
      child: TidalShimmer(
        child: Column(
          children: [
            TidalSkeletonBox(
              width: double.infinity,
              height: context.scaleSize(bannerHeight),
              radius: 0,
            ),
            SizedBox(height: pad),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: pad),
              child: Column(
                children: [
                  for (var i = 0; i < rows; i++)
                    const _SkeletonTrackRow(thumbSize: 48),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Search loading placeholder: top-result card + result rows.
class TidalSearchSkeleton extends StatelessWidget {
  const TidalSearchSkeleton({super.key, this.rows = 6});

  final int rows;

  @override
  Widget build(BuildContext context) {
    final pad = context.scaleSize(AppConstants.spacingMd);
    final art = context.scaleSize(96);
    return SingleChildScrollView(
      child: TidalShimmer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.all(pad),
              child: Row(
                children: [
                  TidalSkeletonBox(
                    width: art,
                    height: art,
                    radius: AppConstants.radiusMd,
                  ),
                  SizedBox(width: pad),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const TidalSkeletonLine(
                          width: double.infinity,
                          height: 14,
                        ),
                        SizedBox(height: context.scaleSize(8)),
                        TidalSkeletonLine(
                          width: context.scaleSize(140),
                          height: 11,
                        ),
                        SizedBox(height: context.scaleSize(10)),
                        TidalSkeletonLine(width: context.scaleSize(90)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: pad),
              child: Column(
                children: [
                  for (var i = 0; i < rows; i++)
                    const _SkeletonTrackRow(thumbSize: 48),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
