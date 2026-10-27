import 'package:flutter_riverpod/flutter_riverpod.dart';

enum TidalSection { hub, search, collection }

class TidalSectionNotifier extends Notifier<TidalSection> {
  @override
  TidalSection build() => TidalSection.hub;

  void show(TidalSection section) => state = section;

  void reset() => state = TidalSection.hub;
}

final tidalSectionProvider =
    NotifierProvider<TidalSectionNotifier, TidalSection>(
      TidalSectionNotifier.new,
    );
