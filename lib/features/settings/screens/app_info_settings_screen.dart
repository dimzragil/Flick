import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/features/onboarding/screens/onboarding_screen.dart';
import 'package:flick/features/settings/screens/privacy_policy_screen.dart';
import 'package:flick/features/settings/screens/support_flick_screen.dart';
import 'package:flick/features/settings/widgets/settings_widgets.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/widgets/common/glass_bottom_sheet.dart';

class AppInfoSettingsScreen extends ConsumerStatefulWidget {
  const AppInfoSettingsScreen({super.key});

  @override
  ConsumerState<AppInfoSettingsScreen> createState() =>
      _AppInfoSettingsScreenState();
}

class _AppInfoSettingsScreenState extends ConsumerState<AppInfoSettingsScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _donationPulseController;
  late final Animation<double> _donationPulseAnimation;

  @override
  void initState() {
    super.initState();
    _donationPulseController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    );
    _donationPulseAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _donationPulseController,
        curve: Curves.easeInOut,
      ),
    );
    _donationPulseController.repeat(reverse: true);
  }

  @override
  void dispose() {
    _donationPulseController.dispose();
    super.dispose();
  }

  void _showToast(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  void _showAboutBottomSheet() {
    GlassBottomSheet.show(
      context: context,
      title: 'About Flick Player',
      maxHeightRatio: 0.5,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: AppConstants.spacingMd),
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: AppColors.glassBackgroundStrong,
              borderRadius: BorderRadius.circular(AppConstants.radiusLg),
              border: Border.all(color: AppColors.glassBorder),
            ),
            child: Center(
              child: SvgPicture.asset(
                'assets/icons/flicklogo_svg.svg',
                width: 28,
                height: 28,
                fit: BoxFit.contain,
              ),
            ),
          ),
          const SizedBox(height: AppConstants.spacingMd),
          const Text(
            'Flick Player',
            style: TextStyle(
              fontFamily: 'ProductSans',
              fontSize: 24,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Version $kAppVersion',
            style: TextStyle(
              fontFamily: 'ProductSans',
              fontSize: 14,
              color: AppColors.textTertiary,
            ),
          ),
          const SizedBox(height: AppConstants.spacingLg),
          Container(
            padding: const EdgeInsets.all(AppConstants.spacingMd),
            decoration: BoxDecoration(
              color: AppColors.glassBackground,
              borderRadius: BorderRadius.circular(AppConstants.radiusMd),
              border: Border.all(color: AppColors.glassBorder),
            ),
            child: const Text(
              'A premium music player with custom UAC 2.0 powered by Rust for the best audio experience.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'ProductSans',
                fontSize: 14,
                color: AppColors.textSecondary,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: AppConstants.spacingMd),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton.icon(
                onPressed: () =>
                    _launchUrl('https://github.com/moss-apps/Flick'),
                icon: const Icon(LucideIcons.squareCode, size: 18),
                label: const Text(
                  'GitHub',
                  style: TextStyle(fontFamily: 'ProductSans'),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppConstants.spacingMd),
        ],
      ),
    );
  }

  static const String _flickLicenseText = '''
MIT License

Copyright (c) 2026 Flick Player Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
''';

  static bool _flickLicenseRegistered = false;

  // ponytail: LicensePage covers the list + detail UI; only Flick's own entry is added manually
  void _openLicensesScreen() {
    if (!_flickLicenseRegistered) {
      _flickLicenseRegistered = true;
      LicenseRegistry.addLicense(() async* {
        yield LicenseEntryWithLineBreaks(['Flick'], _flickLicenseText);
      });
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        // ponytail: iOS platform override swaps the app bar back arrow for a chevron-left
        builder: (_) => Theme(
          data: Theme.of(context).copyWith(platform: TargetPlatform.iOS),
          child: LicensePage(
            applicationName: 'Flick',
            applicationVersion: kAppVersion,
            applicationIcon: Padding(
              padding: const EdgeInsets.all(AppConstants.spacingSm),
              child: SvgPicture.asset(
                'assets/icons/flicklogo_svg.svg',
                width: 28,
                height: 28,
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      bool launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        launched = await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
      if (!launched && mounted) {
        _showToast('Could not open the link');
      }
    } catch (e) {
      if (mounted) {
        _showToast('Could not open the link: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: 'App Info',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SettingsSectionHeader('About'),
          SettingsCard(
            children: [
              NavigationSetting(
                icon: LucideIcons.info,
                title: 'About Flick Player',
                subtitle: 'Version $kAppVersion',
                onTap: _showAboutBottomSheet,
              ),
              const SettingsDivider(),
              NavigationSetting(
                icon: LucideIcons.fileText,
                title: 'Licenses',
                subtitle: 'Open source licenses',
                onTap: _openLicensesScreen,
              ),
              const SettingsDivider(),
              NavigationSetting(
                icon: LucideIcons.shieldCheck,
                title: 'Privacy Policy',
                subtitle: 'How we handle your data',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const PrivacyPolicyScreen(),
                    ),
                  );
                },
              ),
              const SettingsDivider(),
              NavigationSetting(
                icon: LucideIcons.sparkles,
                title: 'View Onboarding',
                subtitle: 'Replay the tutorial and feature guide',
                onTap: () {
                  ref.read(onboardingCompletedProvider.notifier).reset();
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const OnboardingScreen(),
                    ),
                  );
                },
              ),
              const SettingsDivider(),
              NavigationSetting(
                icon: LucideIcons.graduationCap,
                title: 'Interactive Tutorial',
                subtitle: 'Step-by-step walkthrough of the app',
                onTap: () {
                  ref.read(tutorialProvider.notifier).start();
                  Navigator.of(context).popUntil((route) => route.isFirst);
                },
              ),
            ],
          ),
          const SizedBox(height: AppConstants.spacingLg),
          const SettingsSectionHeader('Support'),
          AnimatedBuilder(
            animation: _donationPulseAnimation,
            builder: (context, child) {
              return SettingsCard(
                border: Border.all(
                  color: AppColors.textPrimary.withValues(
                    alpha: 0.25 + _donationPulseAnimation.value * 0.55,
                  ),
                  width: 1.0 + _donationPulseAnimation.value * 1.2,
                ),
                children: [
                  NavigationSetting(
                    icon: LucideIcons.heart,
                    title: 'Support Flick',
                    subtitle: 'Donate, fund features, and keep the app alive',
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SupportFlickScreen(),
                        ),
                      );
                    },
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: AppConstants.spacingLg),
          const SizedBox(height: AppConstants.navBarHeight + 40),
        ],
      ),
    );
  }
}
