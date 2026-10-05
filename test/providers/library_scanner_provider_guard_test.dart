import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flick/providers/library_scanner_provider.dart';

/// The [LibraryScannerNotifier] scan triggers must no-op while the local
/// library toggle is off. The guard runs before the scanner service provider
/// is even built, so these tests never touch the database.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer();
  });

  tearDown(() => container.dispose());

  test('scanFolder no-ops while the toggle is off', () async {
    final notifier = container.read(libraryScannerProvider.notifier);

    await notifier.scanFolder('content://example/tree/music', 'Music');

    final state = container.read(libraryScannerProvider);
    expect(state.isScanning, isFalse);
    expect(state.songsFound, 0);
    expect(state.errorMessage, isNull);
  });

  test('scanAllFolders no-ops while the toggle is off', () async {
    final notifier = container.read(libraryScannerProvider.notifier);

    await notifier.scanAllFolders();

    final state = container.read(libraryScannerProvider);
    expect(state.isScanning, isFalse);
    expect(state.songsFound, 0);
    expect(state.errorMessage, isNull);
  });

  test('no scan state churn happens while the toggle is off', () async {
    final states = <ScanState>[];
    final sub = container.listen<ScanState>(
      libraryScannerProvider,
      (previous, next) => states.add(next),
      fireImmediately: true,
    );

    final notifier = container.read(libraryScannerProvider.notifier);
    await notifier.scanFolder('content://example/tree/music', 'Music');
    await notifier.scanAllFolders();

    // Only the initial fireImmediately emission: the guard returns before any
    // state is written, so listeners never see a scan start.
    expect(states, hasLength(1));
    expect(states.single.isScanning, isFalse);

    sub.close();
  });
}
