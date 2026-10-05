import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:isar_community/isar.dart';
import 'package:path_provider/path_provider.dart';

import '../services/sources/tidal_token_store.dart';

import 'entities/artist_entity.dart';
import 'entities/folder_entity.dart';
import 'entities/network_server_entity.dart';
import 'entities/recently_played_entity.dart';
import 'entities/song_audio_cache_entity.dart';
import 'entities/song_entity.dart';

export 'entities/artist_entity.dart';
export 'entities/folder_entity.dart';
export 'entities/network_server_entity.dart';
export 'entities/recently_played_entity.dart';
export 'entities/song_audio_cache_entity.dart';
export 'entities/song_entity.dart';

/// Database singleton for Isar operations.
class Database {
  static const String _databaseName = 'flick_player';

  static Isar? _instance;

  static Isar get instance {
    if (_instance == null) {
      throw StateError('Database not initialized. Call Database.init() first.');
    }
    return _instance!;
  }

  /// Initialize the database. Should be called once at app startup.
  static Future<void> init() async {
    if (_instance != null) return;

    final dir = await getApplicationDocumentsDirectory();
    final schemas = [
      SongEntitySchema,
      FolderEntitySchema,
      RecentlyPlayedEntitySchema,
      ArtistEntitySchema,
      SongAudioCacheEntitySchema,
      NetworkServerEntitySchema,
    ];

    try {
      _instance = await Isar.open(
        schemas,
        directory: dir.path,
        name: _databaseName,
      );
    } on IsarError catch (e) {
      if (e.message.contains('MDBX_INCOMPATIBLE')) {
        await _deleteDatabaseFiles(dir.path);
        await _clearFingerprintCache(dir.path);
        _instance = await Isar.open(
          schemas,
          directory: dir.path,
          name: _databaseName,
        );
      } else {
        rethrow;
      }
    }
    await _migrateTidalTokens();
  }

  /// One-time migration: moves legacy plaintext TIDAL refresh tokens out of
  /// Isar and into secure keystore storage (TidalTokenStore).
  static Future<void> _migrateTidalTokens({TidalTokenStore? tokenStore}) async {
    try {
      final servers = await networkServers.where().findAll();
      final store = tokenStore ?? TidalTokenStore();
      for (final server in servers) {
        if (server.protocol == 'tidal' &&
            server.token != null &&
            server.token!.isNotEmpty) {
          try {
            final j = jsonDecode(server.token!) as Map<String, dynamic>;
            final refresh = j['refresh_token'] as String?;
            if (refresh != null && refresh.isNotEmpty) {
              await store.write(server.id, refresh);
              j.remove('refresh_token');
              server.token = jsonEncode(j);
              await instance.writeTxn(() async {
                await networkServers.put(server);
              });
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  @visibleForTesting
  static Future<void> migrateTidalTokensForTesting({
    TidalTokenStore? tokenStore,
  }) => _migrateTidalTokens(tokenStore: tokenStore);

  static Future<void> _deleteDatabaseFiles(String directory) async {
    final paths = [
      '$directory/$_databaseName.isar',
      '$directory/$_databaseName.isar.lock',
    ];

    for (final path in paths) {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    }

    // Defensive cleanup for older recovery code that treated the database file
    // path as a directory.
    final legacyDirectory = Directory('$directory/$_databaseName.isar');
    if (await legacyDirectory.exists()) {
      await legacyDirectory.delete(recursive: true);
    }
  }

  static const String _fingerprintCacheDirName = 'flick_fingerprints';

  static Future<void> _clearFingerprintCache(String directory) async {
    final cacheDir = Directory('$directory/$_fingerprintCacheDirName');
    if (await cacheDir.exists()) {
      await cacheDir.delete(recursive: true);
    }
  }

  /// Close the database connection.
  static Future<void> close() async {
    await _instance?.close();
    _instance = null;
  }

  /// Get the songs collection.
  static IsarCollection<SongEntity> get songs => instance.songEntitys;

  /// Get the folders collection.
  static IsarCollection<FolderEntity> get folders => instance.folderEntitys;

  /// Get the recently played collection.
  static IsarCollection<RecentlyPlayedEntity> get recentlyPlayed =>
      _instance!.recentlyPlayedEntitys;

  /// Get the artists collection.
  static IsarCollection<ArtistEntity> get artists => _instance!.artistEntitys;

  /// Get the song audio cache collection.
  static IsarCollection<SongAudioCacheEntity> get songAudioCache =>
      _instance!.songAudioCacheEntitys;

  /// Get the network server collection.
  static IsarCollection<NetworkServerEntity> get networkServers =>
      _instance!.networkServerEntitys;
}
