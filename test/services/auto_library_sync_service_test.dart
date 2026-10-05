import 'package:flutter_test/flutter_test.dart';

import 'package:flick/services/auto_library_sync_service.dart';
import 'package:flick/services/mediastore_observer_service.dart';

class _SpyObserver extends MediaStoreObserverService {
  int starts = 0;
  int stops = 0;

  @override
  void start() => starts++;

  @override
  void stop() => stops++;
}

/// The auto-sync gate: with the local library toggle off, [start] must not
/// register the MediaStore observer (or start periodic metadata work); with
/// it on, the machinery runs. The observer itself is Android-only, so on the
/// test VM the enabled case is observed through [isRunning].
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AutoLibrarySyncService makeService({
    required bool enabled,
    _SpyObserver? observer,
  }) => AutoLibrarySyncService(
    observerService: observer ?? _SpyObserver(),
    backgroundMetadataService: null,
    isLocalLibraryEnabled: () async => enabled,
  );

  test('start() is a no-op while the toggle is off', () async {
    final observer = _SpyObserver();
    final service = makeService(enabled: false, observer: observer);

    await service.start();

    expect(observer.starts, 0);
    expect(service.isRunning, isFalse);
  });

  test('start() proceeds while the toggle is on', () async {
    final service = makeService(enabled: true);

    await service.start();

    expect(service.isRunning, isTrue);
  });

  test('stop() unregisters the observer', () async {
    final observer = _SpyObserver();
    final service = makeService(enabled: true, observer: observer);

    await service.start();
    service.stop();

    expect(observer.stops, 1);
    expect(service.isRunning, isFalse);
  });

  test('a second start() while running does not double-start', () async {
    final service = makeService(enabled: true);

    await service.start();
    await service.start();

    expect(service.isRunning, isTrue);
  });
}
