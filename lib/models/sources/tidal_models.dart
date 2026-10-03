import '../../models/song.dart';

/// Represents a vibe / mood filter tab in the TIDAL Home Feed.
class TidalHomeTab {
  final String name;
  final String type;
  final String slug;

  const TidalHomeTab({
    required this.name,
    required this.type,
    required this.slug,
  });

  factory TidalHomeTab.fromJson(Map<String, dynamic> json) {
    final name = json['name'] as String? ?? '';
    final type = json['type'] as String? ?? '';
    final slug = type.toLowerCase();
    return TidalHomeTab(name: name, type: type, slug: slug);
  }

  Map<String, dynamic> toJson() => {'name': name, 'type': type, 'slug': slug};
}

/// Represents an individual item in a TIDAL Home Feed section.
///
/// Can represent a Mix, Playlist, Album, Track, or Artist.
class TidalHomeItem {
  final String id;
  final String title;
  final String? subtitle;
  final String? imageUrl;
  final String type; // MIX, PLAYLIST, ALBUM, TRACK, ARTIST, etc.
  final Map<String, dynamic> raw;

  const TidalHomeItem({
    required this.id,
    required this.title,
    this.subtitle,
    this.imageUrl,
    required this.type,
    this.raw = const {},
  });

  bool get isMix {
    final t = type.toUpperCase();
    if (t == 'MIX' || t == 'MIX_ITEM' || t.contains('MIX')) return true;
    if (raw['mixType'] != null ||
        raw['mixImages'] != null ||
        raw['mixId'] != null) {
      return true;
    }
    return false;
  }

  bool get isPlaylist {
    final t = type.toUpperCase();
    if (t == 'PLAYLIST' || t == 'PLAYLIST_ITEM') return true;
    if (raw['uuid'] != null) return true;
    if (id.contains('-') && id.length >= 32) return true;
    if (raw['numberOfTracks'] != null && raw['creator'] != null) return true;
    return false;
  }

  bool get isArtist {
    final t = type.toUpperCase();
    if (t == 'ARTIST' || t == 'ARTIST_LIST') return true;
    if (raw['picture'] != null &&
        raw['cover'] == null &&
        raw['album'] == null &&
        raw['images'] == null &&
        raw['mixType'] == null) {
      return true;
    }
    return false;
  }

  bool get isTrack {
    final t = type.toUpperCase();
    if (t == 'TRACK' || t == 'TRACK_ITEM') return true;
    if (raw['duration'] != null &&
        (raw['artist'] != null || raw['artists'] != null) &&
        raw['album'] != null) {
      return true;
    }
    return false;
  }

  bool get isMyTracks {
    if (type.toUpperCase() == 'MY_TRACKS') return true;
    if (id == 'tidal://my-collection/tracks') return true;
    if (raw['url'] == 'tidal://my-collection/tracks') return true;
    if (title == 'My Tracks' && !isPlaylist && !isMix) return true;
    return false;
  }

  bool get isAlbum {
    final t = type.toUpperCase();
    if (t == 'ALBUM' || t == 'ALBUM_ITEM') return true;
    if (!isMix && !isPlaylist && !isArtist && !isTrack && !isMyTracks) {
      if (raw['cover'] != null) return true;
      if (id.isNotEmpty && !id.contains('-') && int.tryParse(id) != null) {
        return true;
      }
    }
    return false;
  }

  /// Extract a TidalHomeItem from either a flat object or a `{ type, data }` wrapper.
  factory TidalHomeItem.fromJson(
    Map<String, dynamic> json, {
    String? typeHint,
  }) {
    final Map<String, dynamic> data;
    if (json.containsKey('data') && json['data'] is Map<String, dynamic>) {
      data = Map<String, dynamic>.from(json['data'] as Map<String, dynamic>);
      json.forEach((k, v) {
        if (k != 'data' && !data.containsKey(k)) {
          data[k] = v;
        }
      });
    } else if (json.containsKey('item') &&
        json['item'] is Map<String, dynamic>) {
      data = Map<String, dynamic>.from(json['item'] as Map<String, dynamic>);
      json.forEach((k, v) {
        if (k != 'item' && !data.containsKey(k)) {
          data[k] = v;
        }
      });
    } else if (json.containsKey('artist') &&
        json['artist'] is Map<String, dynamic>) {
      data = Map<String, dynamic>.from(json['artist'] as Map<String, dynamic>);
      json.forEach((k, v) {
        if (k != 'artist' && !data.containsKey(k)) {
          data[k] = v;
        }
      });
    } else {
      data = Map<String, dynamic>.from(json);
    }

    final rawType =
        (json['type'] as String?) ??
        (data['_itemType'] as String?) ??
        (data['type'] as String?) ??
        '';

    final id = _extractId(data, json);
    final title = _extractTitle(data);
    final subtitle = _extractSubtitle(data);
    final imageUrl = _extractImageUrl(data);
    final resolvedType = _resolveItemType(
      rawType,
      data,
      json,
      id: id,
      typeHint: typeHint,
    );

    return TidalHomeItem(
      id: id,
      title: title,
      subtitle: subtitle,
      imageUrl: imageUrl,
      type: resolvedType,
      raw: data,
    );
  }

  static String _resolveItemType(
    String rawType,
    Map<String, dynamic> data,
    Map<String, dynamic> root, {
    required String id,
    String? typeHint,
  }) {
    final t = rawType.toUpperCase();
    if (id == 'tidal://my-collection/tracks' ||
        data['url'] == 'tidal://my-collection/tracks' ||
        data['title'] == 'My Tracks') {
      return 'MY_TRACKS';
    }
    if (t == 'MIX' ||
        t.contains('MIX') ||
        data['mixType'] != null ||
        data['mixImages'] != null ||
        data['mixId'] != null ||
        typeHint == 'MIX_LIST') {
      return 'MIX';
    }
    if (t == 'PLAYLIST' ||
        t == 'PLAYLIST_ITEM' ||
        data['uuid'] != null ||
        root['uuid'] != null ||
        typeHint == 'PLAYLIST_LIST') {
      return 'PLAYLIST';
    }
    if (t == 'ARTIST' ||
        t == 'ARTIST_LIST' ||
        typeHint == 'ARTIST_LIST' ||
        (data['picture'] != null &&
            data['cover'] == null &&
            data['album'] == null &&
            data['images'] == null)) {
      return 'ARTIST';
    }
    if (t == 'TRACK' ||
        t == 'TRACK_ITEM' ||
        typeHint == 'TRACK_LIST' ||
        (data['duration'] != null && data['album'] != null)) {
      return 'TRACK';
    }
    if (t == 'ALBUM' || t == 'ALBUM_ITEM' || typeHint == 'ALBUM_LIST') {
      return 'ALBUM';
    }
    // Artifact promotion routing
    final artifactId = data['artifactId'] ?? root['artifactId'];
    if (artifactId != null) {
      if (t == 'PLAYLIST') return 'PLAYLIST';
      if (t == 'ALBUM') return 'ALBUM';
      if (t == 'ARTIST') return 'ARTIST';
    }
    // UUID identifier => playlist
    if (id.contains('-') && id.length >= 32) {
      return 'PLAYLIST';
    }
    // Numeric identifier or cover => album
    if (data['cover'] != null || int.tryParse(id) != null) {
      return 'ALBUM';
    }
    return t.isNotEmpty ? t : (typeHint ?? 'UNKNOWN');
  }

  static String _extractId(
    Map<String, dynamic> data,
    Map<String, dynamic> root,
  ) {
    if (data['id'] != null) return data['id'].toString();
    if (data['uuid'] != null) return data['uuid'].toString();
    if (data['mixId'] != null) return data['mixId'].toString();
    if (data['artifactId'] != null) return data['artifactId'].toString();
    if (root['id'] != null) return root['id'].toString();
    if (root['uuid'] != null) return root['uuid'].toString();
    if (root['mixId'] != null) return root['mixId'].toString();
    if (root['artifactId'] != null) return root['artifactId'].toString();
    return '';
  }

  static String _extractTitle(Map<String, dynamic> data) {
    if (data['title'] is String && (data['title'] as String).isNotEmpty) {
      return data['title'] as String;
    }
    if (data['name'] is String && (data['name'] as String).isNotEmpty) {
      return data['name'] as String;
    }
    if (data['titleTextInfo'] is Map) {
      final text = data['titleTextInfo']['text'];
      if (text is String && text.isNotEmpty) return text;
    }
    if (data['shortHeader'] is String &&
        (data['shortHeader'] as String).isNotEmpty) {
      return data['shortHeader'] as String;
    }
    return '';
  }

  static String? _extractSubtitle(Map<String, dynamic> data) {
    if (data['subTitle'] is String && (data['subTitle'] as String).isNotEmpty) {
      return data['subTitle'] as String;
    }
    if (data['shortSubtitle'] is String &&
        (data['shortSubtitle'] as String).isNotEmpty) {
      return data['shortSubtitle'] as String;
    }
    if (data['subtitleTextInfo'] is Map) {
      final text = data['subtitleTextInfo']['text'];
      if (text is String && text.isNotEmpty) return text;
    }
    if (data['artists'] is List && (data['artists'] as List).isNotEmpty) {
      final names = (data['artists'] as List)
          .map((a) => a is Map ? a['name']?.toString() : null)
          .whereType<String>()
          .toList();
      if (names.isNotEmpty) return names.join(', ');
    }
    if (data['artist'] is Map && data['artist']['name'] is String) {
      return data['artist']['name'] as String;
    }
    if (data['creator'] is Map) {
      final creator = data['creator'] as Map;
      final name = creator['name']?.toString();
      final id = creator['id'];
      final creatorName = (id == 0)
          ? 'By TIDAL'
          : (name != null ? 'By $name' : null);
      final numTracks = data['numberOfTracks'];
      if (creatorName != null && numTracks != null) {
        return '$creatorName · $numTracks tracks';
      }
      if (creatorName != null) return creatorName;
      if (numTracks != null) return '$numTracks tracks';
    }
    if (data['numberOfTracks'] != null) {
      return '${data['numberOfTracks']} tracks';
    }
    if (data['description'] is String &&
        (data['description'] as String).isNotEmpty) {
      return data['description'] as String;
    }
    return null;
  }

  static String? _extractImageUrl(Map<String, dynamic> data, {int size = 640}) {
    // 1. Mix images (images.LARGE / MEDIUM / SMALL)
    if (data['images'] is Map) {
      final images = data['images'] as Map;
      final large = images['LARGE'];
      if (large is Map && large['url'] is String) return large['url'] as String;
      final med = images['MEDIUM'];
      if (med is Map && med['url'] is String) return med['url'] as String;
      final sm = images['SMALL'];
      if (sm is Map && sm['url'] is String) return sm['url'] as String;
    }

    // 2. Mix images array (mixImages)
    if (data['mixImages'] is List && (data['mixImages'] as List).isNotEmpty) {
      final first = (data['mixImages'] as List).first;
      if (first is Map && first['url'] is String) return first['url'] as String;
    }

    // 3. Detail mix images (detailMixImages)
    if (data['detailMixImages'] is List &&
        (data['detailMixImages'] as List).isNotEmpty) {
      final first = (data['detailMixImages'] as List).first;
      if (first is Map && first['url'] is String) return first['url'] as String;
    }

    // 4. Detail images object (detailImages)
    if (data['detailImages'] is Map) {
      final dImages = data['detailImages'] as Map;
      final med = dImages['MEDIUM'];
      if (med is Map && med['url'] is String) return med['url'] as String;
      final sm = dImages['SMALL'];
      if (sm is Map && sm['url'] is String) return sm['url'] as String;
    }

    // 5. Album / Playlist Cover UUID
    final square = data['squareImage'] ?? data['squareImageUuid'];
    if (square is String && square.isNotEmpty) {
      return _buildTidalImageUrl(square, size: size);
    }
    final cover = data['cover'];
    if (cover is String && cover.isNotEmpty) {
      return _buildTidalImageUrl(cover, size: size);
    }
    final image = data['image'];
    if (image is String && image.isNotEmpty) {
      return _buildTidalWideImageUrl(image, width: size > 160 ? 640 : 480);
    }

    // 6. Artist picture UUID
    final picture = data['picture'] ?? data['artworkId'];
    if (picture is String && picture.isNotEmpty) {
      return _buildTidalImageUrl(picture, size: size);
    }

    // 7. Nested album cover
    if (data['album'] is Map) {
      final albumCover = data['album']['cover'];
      if (albumCover is String && albumCover.isNotEmpty) {
        return _buildTidalImageUrl(albumCover, size: size);
      }
    }

    // 8. Nested artist picture
    if (data['artist'] is Map) {
      final artistPic =
          data['artist']['picture'] ??
          data['artist']['squareImage'] ??
          data['artist']['artworkId'];
      if (artistPic is String && artistPic.isNotEmpty) {
        return _buildTidalImageUrl(artistPic, size: size);
      }
    }

    // 9. Nested item container
    if (data['item'] is Map<String, dynamic>) {
      final itemUrl = _extractImageUrl(
        data['item'] as Map<String, dynamic>,
        size: size,
      );
      if (itemUrl != null && itemUrl.isNotEmpty) return itemUrl;
    }

    // 10. Direct imageUrl string
    if (data['imageUrl'] is String && (data['imageUrl'] as String).isNotEmpty) {
      return data['imageUrl'] as String;
    }

    return null;
  }

  static String _buildTidalImageUrl(String uuid, {int size = 640}) {
    final clean = uuid.replaceAll('-', '');
    if (clean.length < 5 || clean.replaceAll('0', '').isEmpty) return '';
    final String path;
    if (clean.length == 32) {
      path =
          '${clean.substring(0, 8)}/${clean.substring(8, 12)}/${clean.substring(12, 16)}/${clean.substring(16, 20)}/${clean.substring(20)}';
    } else {
      path = uuid.replaceAll('-', '/');
    }
    return 'https://resources.tidal.com/images/$path/${size}x$size.jpg';
  }

  static String _buildTidalWideImageUrl(String uuid, {int width = 480}) {
    final clean = uuid.replaceAll('-', '');
    if (clean.length < 5 || clean.replaceAll('0', '').isEmpty) return '';
    final String path;
    if (clean.length == 32) {
      path =
          '${clean.substring(0, 8)}/${clean.substring(8, 12)}/${clean.substring(12, 16)}/${clean.substring(16, 20)}/${clean.substring(20)}';
    } else {
      path = uuid.replaceAll('-', '/');
    }
    final int targetW;
    final int targetH;
    if (width <= 320) {
      targetW = 320;
      targetH = 214;
    } else if (width <= 480) {
      targetW = 480;
      targetH = 320;
    } else if (width <= 640) {
      targetW = 640;
      targetH = 428;
    } else if (width <= 750) {
      targetW = 750;
      targetH = 500;
    } else {
      targetW = 1080;
      targetH = 720;
    }
    return 'https://resources.tidal.com/images/$path/${targetW}x$targetH.jpg';
  }
}

/// Represents a section in the TIDAL Home Feed (e.g. SHORTCUT_LIST, HORIZONTAL_LIST).
class TidalHomeSection {
  final String title;
  final String
  sectionType; // SHORTCUT_LIST, HORIZONTAL_LIST, TRACK_LIST, MIXED_LIST, etc.
  final List<TidalHomeItem> items;
  final bool hasMore;
  final String? apiPath;

  const TidalHomeSection({
    required this.title,
    required this.sectionType,
    required this.items,
    this.hasMore = false,
    this.apiPath,
  });

  bool get isShortcutList => sectionType == 'SHORTCUT_LIST';
  bool get isHorizontalList =>
      sectionType == 'HORIZONTAL_LIST' ||
      sectionType == 'HORIZONTAL_LIST_WITH_CONTEXT' ||
      sectionType == 'MIXED_LIST';
}

/// Aggregated TIDAL Home Feed containing tabs, sections, and an optional pagination cursor.
class TidalHomeFeed {
  final List<TidalHomeTab> tabs;
  final List<TidalHomeSection> sections;
  final String? cursor;

  const TidalHomeFeed({
    this.tabs = const [],
    this.sections = const [],
    this.cursor,
  });

  static const empty = TidalHomeFeed();
}

/// Complete details and tracklist for a TIDAL Mix or Station.
class TidalMix {
  final String mixId;
  final String title;
  final String? subTitle;
  final String? imageUrl;
  final String? mixType;
  final List<Song> tracks;

  const TidalMix({
    required this.mixId,
    required this.title,
    this.subTitle,
    this.imageUrl,
    this.mixType,
    this.tracks = const [],
  });
}
