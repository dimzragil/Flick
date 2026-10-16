import 'package:flutter/material.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/services/sources/tidal_service.dart';

/// Returns true if [error] is (or looks like) a TIDAL rate-limit error.
bool isTidalRateLimitError(Object error) {
  if (error is TidalRateLimitedException) return true;
  // Fallback: Riverpod/async gaps sometimes stringify; match the message.
  final s = error.toString();
  return s.contains('Too many TIDAL requests') || s.contains('429');
}

/// Friendly error widget for TIDAL API failures.
///
/// Shows a specific, actionable message when rate-limited (with a retry
/// button), and falls back to a generic message otherwise. Previously the
/// Hub would spin forever during 429 backoff and then show a raw
/// exception string — leaving users staring at spinners with no idea
/// what was wrong or when to retry.
class TidalErrorWidget extends StatelessWidget {
  final Object error;
  final String contextLabel;
  final VoidCallback? onRetry;

  const TidalErrorWidget({
    super.key,
    required this.error,
    required this.contextLabel,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final rateLimited = isTidalRateLimitError(error);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              rateLimited ? Icons.hourglass_empty : Icons.cloud_off_outlined,
              color: AppColors.textSecondary,
              size: 40,
            ),
            const SizedBox(height: 12),
            Text(
              rateLimited ? 'TIDAL is rate-limiting requests' : contextLabel,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              rateLimited
                  ? 'Too many requests to TIDAL right now. '
                      'Wait a minute or two, then try again.'
                  : error.toString().replaceFirst('TidalException: ', ''),
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Try again'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Color(0x4DFFFFFF)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
