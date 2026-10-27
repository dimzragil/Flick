import 'package:flick/features/tidal/providers/tidal_section_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TIDAL section starts at Hub and supports section switches', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(tidalSectionProvider), TidalSection.hub);
    container.read(tidalSectionProvider.notifier).show(TidalSection.search);
    expect(container.read(tidalSectionProvider), TidalSection.search);
    container.read(tidalSectionProvider.notifier).show(TidalSection.collection);
    expect(container.read(tidalSectionProvider), TidalSection.collection);
  });
}
