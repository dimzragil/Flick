import 'package:flutter/foundation.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flick/core/utils/dev_log.dart';

class DisplayModeService {
  static final DisplayModeService _instance = DisplayModeService._internal();
  factory DisplayModeService() => _instance;
  DisplayModeService._internal();

  List<DisplayMode> _availableModes = [];
  DisplayMode? _currentMode;
  DisplayMode? _preferredMode;

  List<DisplayMode> get availableModes => _availableModes;
  DisplayMode? get currentMode => _currentMode;
  DisplayMode? get preferredMode => _preferredMode;

  bool get isSupported => defaultTargetPlatform == TargetPlatform.android;

  static String _describe(DisplayMode? mode) {
    if (mode == null) return 'unknown';
    if (mode.id == 0) return 'auto';
    return '#${mode.id} ${mode.width}x${mode.height}@${mode.refreshRate}Hz';
  }

  Future<void> _logState(String tag) async {
    try {
      _currentMode = await FlutterDisplayMode.active;
      _preferredMode = await FlutterDisplayMode.preferred;
    } catch (e) {
      devLog('DisplayMode[$tag]: failed to read state: $e');
      return;
    }
    devLog(
      'DisplayMode[$tag]: active=${_describe(_currentMode)} '
      'preferred=${_describe(_preferredMode)}',
    );
  }

  Future<void> initialize() async {
    if (!isSupported) return;
    try {
      _availableModes = await FlutterDisplayMode.supported;
      _currentMode = await FlutterDisplayMode.active;
      _preferredMode = await FlutterDisplayMode.preferred;
      devLog(
        'DisplayMode[init]: supported='
        '${_availableModes.map(_describe).join(', ')}',
      );
      devLog(
        'DisplayMode[init]: active=${_describe(_currentMode)} '
        'preferred=${_describe(_preferredMode)}',
      );
    } catch (e) {
      devLog('Failed to initialize display modes: $e');
    }
  }

  Future<void> setHighRefreshRate() async {
    if (!isSupported) return;
    try {
      await FlutterDisplayMode.setHighRefreshRate();
      await _logState('setHigh');
    } catch (e) {
      devLog('Failed to set high refresh rate: $e');
    }
  }

  Future<void> setLowRefreshRate() async {
    if (!isSupported) return;
    try {
      await FlutterDisplayMode.setLowRefreshRate();
      await _logState('setLow');
    } catch (e) {
      devLog('Failed to set low refresh rate: $e');
    }
  }

  Future<void> setPreferredMode(DisplayMode mode) async {
    if (!isSupported) return;
    try {
      await FlutterDisplayMode.setPreferredMode(mode);
      await _logState('setPreferred ${_describe(mode)}');
    } catch (e) {
      devLog('Failed to set preferred mode: $e');
    }
  }

  /// Clears any forced display mode so the system decides again.
  Future<void> resetToAuto() async {
    if (!isSupported) return;
    try {
      await FlutterDisplayMode.setPreferredMode(DisplayMode.auto);
      await _logState('resetAuto');
    } catch (e) {
      devLog('Failed to reset display mode: $e');
    }
  }

  DisplayMode? get highestRefreshRateMode {
    if (_availableModes.isEmpty) return null;
    return _availableModes.reduce(
      (a, b) => a.refreshRate > b.refreshRate ? a : b,
    );
  }

  DisplayMode? get highestResolutionMode {
    if (_availableModes.isEmpty) return null;
    return _availableModes.reduce((a, b) {
      final aPixels = (a.width * a.height);
      final bPixels = (b.width * b.height);
      return aPixels > bPixels ? a : b;
    });
  }

  DisplayMode? get optimalMode {
    if (_availableModes.isEmpty) return null;
    return _availableModes.reduce((a, b) {
      final aScore = a.refreshRate * (a.width * a.height);
      final bScore = b.refreshRate * (b.width * b.height);
      return aScore > bScore ? a : b;
    });
  }
}
