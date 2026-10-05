import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:flick/services/library_scan_preferences_service.dart';

/// Persistence-layer tests for the local-library toggle.
///
/// Each test boots a fresh mock store; the "restart" tests additionally throw
/// away the cached [SharedPreferences] instance and re-seed a new store with
/// whatever the previous session wrote, faithfully simulating a process
/// restart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Simulates a process restart: returns the raw contents the previous
  /// session persisted, then boots a brand-new store + cached instance from
  /// them, like the OS handing the app its persisted preferences back.
  Future<void> simulateRestart() async {
    final persisted = await SharedPreferencesStorePlatform.instance.getAll();
    SharedPreferences.setMockInitialValues(persisted);
  }

  test('local library defaults to OFF on a fresh install', () async {
    SharedPreferences.setMockInitialValues({});

    final service = LibraryScanPreferencesService();
    expect(await service.isLocalLibraryEnabled(), isFalse);
    expect((await service.getPreferences()).localLibraryEnabled, isFalse);
  });

  test('enabling persists across a simulated restart', () async {
    SharedPreferences.setMockInitialValues({});

    await LibraryScanPreferencesService().setLocalLibraryEnabled(true);
    await simulateRestart();

    final freshService = LibraryScanPreferencesService();
    expect(await freshService.isLocalLibraryEnabled(), isTrue);
    expect((await freshService.getPreferences()).localLibraryEnabled, isTrue);
  });

  test('disabling persists across a simulated restart', () async {
    SharedPreferences.setMockInitialValues(const {
      'library_scan_local_library_enabled': true,
    });

    await LibraryScanPreferencesService().setLocalLibraryEnabled(false);
    await simulateRestart();

    expect(
      await LibraryScanPreferencesService().isLocalLibraryEnabled(),
      isFalse,
    );
  });

  test('toggle writes reach the underlying store', () async {
    SharedPreferences.setMockInitialValues({});

    await LibraryScanPreferencesService().setLocalLibraryEnabled(true);

    final stored = await SharedPreferencesStorePlatform.instance.getAll();
    expect(stored['flutter.library_scan_local_library_enabled'], isTrue);
  });
}
