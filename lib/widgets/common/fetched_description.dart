import 'package:flutter/material.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/widgets/common/glass_bottom_sheet.dart';

/// Read-only collapsible text fetched from an online source, such as an
/// artist biography or album notes. Coexists with the user-authored
/// [DetailDescription] without touching its storage.
class FetchedDescription extends StatelessWidget {
  final String text;
  final String sourceLabel;
  final int collapsedLines;
  final String? sheetTitle;

  const FetchedDescription({
    super.key,
    required this.text,
    this.sourceLabel = 'Apple Music',
    this.collapsedLines = 3,
    this.sheetTitle,
  });

  void _showFullText(BuildContext context) {
    GlassBottomSheet.show(
      context: context,
      title: sheetTitle,
      maxHeightRatio: 0.75,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text.trim(),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: context.adaptiveTextSecondary,
              height: 1.45,
            ),
          ),
          const SizedBox(height: AppConstants.spacingMd),
          Text(
            'From $sourceLabel',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.adaptiveTextTertiary,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppConstants.spacingLg,
        AppConstants.spacingXs,
        AppConstants.spacingLg,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            trimmed,
            maxLines: collapsedLines,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: context.adaptiveTextSecondary,
              height: 1.45,
            ),
          ),
          const SizedBox(height: AppConstants.spacingXs),
          Row(
            children: [
              TextButton(
                onPressed: () => _showFullText(context),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.accent,
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Show more'),
              ),
              const Spacer(),
              Text(
                'From $sourceLabel',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.adaptiveTextTertiary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
