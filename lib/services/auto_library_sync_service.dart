import 'dart:io';
import 'library_scan_preferences_service.dart';
import 'mediastore_observer_service.dart';
import 'background_metadata_service.dart';
import 'package:flick/core/utils/dev_log.dart';

class AutoLibrarySyncService {
  final MediaStoreObserverService? _observerService;
  final BackgroundMetadataService? _backgroundMetadataService;
  final Future<bool> Function() _isLocalLibraryEnabled;

  bool _isRunning = false;

  AutoLibrarySyncService({
    MediaStoreObserverService? observerService,
    BackgroundMetadataService? backgroundMetadataService,
    Future<bool> Function()? isLocalLibraryEnabled,
  })  : _observerService = observerService,
        _backgroundMetadataService = backgroundMetadataService,
        _isLocalLibraryEnabled =
            isLocalLibraryEnabled ??
            LibraryScanPreferencesService().isLocalLibraryEnabled;

  /// Starts the auto-rescan observer and the periodic background metadata
  /// pass. Local library is opt-in: when the toggle is off this is a no-op
  /// so no observer is registered and no periodic DB queries run.
  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;

    if (!await _isLocalLibraryEnabled()) {
      _isRunning = false;
      devLog('Auto library sync skipped: local library disabled');
      return;
    }

    devLog('Auto library sync started (event-driven)');

    if (Platform.isAndroid && _observerService != null) {
      _observerService.start();
    }

    _backgroundMetadataService?.startPeriodicExtraction();
  }

  void stop() {
    _observerService?.stop();
    _backgroundMetadataService?.stop();
    _isRunning = false;
    devLog('Auto library sync stopped');
  }

  void notifyPaused() {
    if (!_isRunning) return;
    _observerService?.notifyPaused();
  }

  void notifyResumed() {
    if (!_isRunning) return;
    _observerService?.notifyResumed();
  }

  bool get isRunning => _isRunning;
}
