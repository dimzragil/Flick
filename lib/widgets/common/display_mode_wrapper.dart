import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/utils/dev_log.dart';
import 'package:flick/providers/app_preferences_provider.dart';
import 'package:flick/services/display_mode_service.dart';

class DisplayModeWrapper extends ConsumerStatefulWidget {
  final Widget child;
  final bool enableOnMount;

  const DisplayModeWrapper({
    super.key,
    required this.child,
    this.enableOnMount = true,
  });

  @override
  ConsumerState<DisplayModeWrapper> createState() =>
      _DisplayModeWrapperState();
}

class _DisplayModeWrapperState extends ConsumerState<DisplayModeWrapper>
    with WidgetsBindingObserver {
  final DisplayModeService _displayModeService = DisplayModeService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ref.listenManual(appPreferencesProvider.select((p) => p.refreshRateMode),
        (_, __) => _applyRefreshRate('preference'));
    if (widget.enableOnMount) {
      _applyRefreshRate('mount');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _applyRefreshRate('resume');
    }
  }

  Future<void> _applyRefreshRate(String reason) async {
    final mode = ref.read(appPreferencesProvider).refreshRateMode;
    devLog('DisplayMode[wrapper]: apply refreshRateMode=$mode ($reason)');
    switch (mode) {
      case 'standard':
        await _displayModeService.setLowRefreshRate();
      case 'adaptive':
        await _displayModeService.resetToAuto();
      default:
        await _displayModeService.setHighRefreshRate();
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
