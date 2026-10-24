import 'package:flutter/foundation.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flick/core/utils/dev_log.dart';

class DisplayModeService {
  static final DisplayModeService _instance = DisplayModeService._internal();
  factory DisplayModeService() => _instance;
  DisplayModeService._internal();

  bool get isSupported => defaultTargetPlatform == TargetPlatform.android;

  Future<void> initialize() async {
    if (!isSupported) return;
    try {
      await FlutterDisplayMode.setHighRefreshRate();
    } catch (e) {
      devLog('Failed to initialize display modes: $e');
    }
  }

  Future<void> setHighRefreshRate() async {
    if (!isSupported) return;
    try {
      await FlutterDisplayMode.setHighRefreshRate();
    } catch (e) {
      devLog('Failed to set high refresh rate: $e');
    }
  }

  Future<void> setLowRefreshRate() async {
    if (!isSupported) return;
    try {
      await FlutterDisplayMode.setLowRefreshRate();
    } catch (e) {
      devLog('Failed to set low refresh rate: $e');
    }
  }

  Future<void> setPreferredMode(DisplayMode mode) async {
    if (!isSupported) return;
    try {
      await FlutterDisplayMode.setPreferredMode(mode);
    } catch (e) {
      devLog('Failed to set preferred mode: $e');
    }
  }

  /// Applies a persisted refresh-rate preference (`'standard'`, `'adaptive'`,
  /// or anything else = high). Single source of truth for the mapping, so the
  /// screen wrapper, the tab-change guard and the lifecycle hook cannot drift.
  Future<void> applyPreference(String mode) async {
    switch (mode) {
      case 'standard':
        await setLowRefreshRate();
      case 'adaptive':
        // Adaptive leaves the platform alone (LTPO decides per content).
        break;
      default:
        await setHighRefreshRate();
    }
  }
}
