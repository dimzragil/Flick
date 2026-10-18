import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/src/rust/frb_generated.dart';
import 'package:flick/app/app.dart';
import 'package:flick/data/database.dart';
import 'package:flick/services/external_playback_service.dart';
import 'package:flick/services/permission_service.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/playback_cache_maintenance.dart';
import 'package:flick/services/process_exit_diagnostics_service.dart';
import 'package:flick/services/uac2_preferences_service.dart';
import 'package:flick/services/uac2_service.dart';
import 'package:flick/core/utils/app_log.dart';
import 'package:flick/core/utils/dev_log.dart';
import 'package:flick/core/navigation/root_navigator.dart';
import 'package:flick/src/rust/api/logging.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  await AppLog.instance.initializePersistence();

  FlutterError.onError = (details) {
    AppLog.instance.add(
      '${details.exception}\n${details.stack}',
      source: LogSource.crash,
    );
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.instance.add('$error\n$stack', source: LogSource.platform);
    debugPrint('PlatformDispatcher.onError: $error\n$stack');
    return true;
  };

  try {
    await RustLib.init();
    _subscribeRustLogs();
    unawaited(ProcessExitDiagnosticsService().reportPreviousExits());

    await Database.init();

    final externalPlaybackHandled = await ExternalPlaybackService().initialize();
    if (!externalPlaybackHandled) {
      await _restoreLastPlayedSong();
    }
  } catch (error, stack) {
    AppLog.instance.add('Startup error: $error\n$stack', source: LogSource.crash);
    debugPrint('Startup initialization failed: $error\n$stack');
    runApp(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: SingleChildScrollView(
                child: Text(
                  'Flick failed to start:\n\n$error\n\n$stack',
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontFamily: 'monospace',
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return;
  }

  runZonedGuarded(() {
    runApp(const ProviderScope(child: FlickPlayerApp()));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_bootstrapAppAfterFirstFrame());
    });
  }, (error, stack) {
    AppLog.instance.add('$error\n$stack', source: LogSource.zone);
  });
}

void _subscribeRustLogs() {
  registerLogSink().listen(
    (msg) => AppLog.instance.add(msg, source: LogSource.rust),
    onError: (Object e) =>
        AppLog.instance.add('rust log stream error: $e', source: LogSource.rust),
  );
}

Future<void> _bootstrapAppAfterFirstFrame() async {
  // Eagerly hydrate the UAC2 notifiers (resampler engine, bit-perfect) so the
  // settings UI reflects persisted values even if the Rust audio engine never
  // initializes (speaker/Bluetooth playback skips Rust init entirely).
  try {
    await Uac2PreferencesService().getResamplerPreference();
    await Uac2PreferencesService().getBitPerfectEnabled();
  } catch (e) {
    devLog('Failed to restore UAC2 audio preferences: $e');
  }
  unawaited(_setOptimalDisplayMode());
  unawaited(_showDatabaseRecoveryNotice());
  unawaited(
    _requestNotificationPermission().catchError(
      (Object e) => devLog('Notification permission request failed: $e'),
    ),
  );
  unawaited(
    Uac2Service.instance
        .initializeAndroidRouteMonitoring()
        .catchError((Object e) => devLog('USB route probe failed: $e')),
  );
  unawaited(
    PlayerService().prepareForAppLaunch().catchError(
      (Object e) => devLog('Audio prewarm failed: $e'),
    ),
  );
  unawaited(
    runPlaybackCacheMaintenance().catchError(
      (Object e) => devLog('Playback cache maintenance failed: $e'),
    ),
  );
}

Future<void> _setOptimalDisplayMode() async {
  try {
    await FlutterDisplayMode.setHighRefreshRate();
  } catch (e) {
    devLog('Display mode not supported: $e');
  }
}

/// Informs the user if the database was reset due to an incompatible format.
/// The old file is kept as a backup (see Database.recoveredBackupPath) —
/// never silently destroyed.
Future<void> _showDatabaseRecoveryNotice() async {
  final backupPath = Database.recoveredBackupPath;
  if (backupPath == null) return;
  // Clear so the notice shows only once per recovery.
  Database.recoveredBackupPath = null;

  final context = rootNavigatorKey.currentContext;
  if (context == null) return;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('Library was reset'),
      content: const Text(
        'The music database format changed and could not be opened, '
        'so the library was started fresh. Your old database was kept '
        'as a backup file instead of being deleted.\n\n'
        'You may need to rescan your folders and sign in to TIDAL again.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

Future<void> _requestNotificationPermission() async {
  final permissionService = PermissionService();
  final hasPermission = await permissionService.hasNotificationPermission();
  if (!hasPermission) {
    await permissionService.requestNotificationPermission();
  }
}

Future<void> _restoreLastPlayedSong() async {
  try {
    final playerService = PlayerService();
    await playerService.restorePlaybackModes();
    await playerService.restoreLastPlayed();
  } catch (e) {
    devLog('Failed to restore last played song: $e');
  }
}
