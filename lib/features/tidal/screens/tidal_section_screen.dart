import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/tidal_section_provider.dart';
import 'tidal_collection_screen.dart';
import 'tidal_hub_screen.dart';
import 'tidal_search_screen.dart';

class TidalSectionScreen extends ConsumerStatefulWidget {
  const TidalSectionScreen({super.key});

  @override
  ConsumerState<TidalSectionScreen> createState() => _TidalSectionScreenState();
}

class _TidalSectionScreenState extends ConsumerState<TidalSectionScreen> {
  var _hasOpenedSearch = false;
  var _hasOpenedCollection = false;

  @override
  Widget build(BuildContext context) {
    final section = ref.watch(tidalSectionProvider);
    _hasOpenedSearch |= section == TidalSection.search;
    _hasOpenedCollection |= section == TidalSection.collection;

    final children = <Widget>[
      TickerMode(
        enabled: section == TidalSection.hub,
        child: TidalHubScreen(key: const ValueKey('tidal-hub')),
      ),
      if (_hasOpenedSearch)
        TickerMode(
          enabled: section == TidalSection.search,
          child: const TidalSearchScreen(
            key: ValueKey('tidal-section-search'),
            showBackButton: false,
          ),
        ),
      if (_hasOpenedCollection)
        TickerMode(
          enabled: section == TidalSection.collection,
          child: const TidalCollectionScreen(key: ValueKey('tidal-collection')),
        ),
    ];
    final index = switch (section) {
      TidalSection.hub => 0,
      TidalSection.search => 1,
      TidalSection.collection => _hasOpenedSearch ? 2 : 1,
    };

    return IndexedStack(index: index, children: children);
  }
}
