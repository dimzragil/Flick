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

  /// Path of the backed-up database file, set when [init] recovers from an
  /// incompatible database format. Null during normal startup. The UI layer
  /// checks this to inform the user that their library was reset.
  static String? recoveredBackupPath;

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
        // Don't silently destroy user data: back the old file up instead of
        // deleting it, and let the UI inform the user (see recoveredBackupPath).
        recoveredBackupPath = await _backupDatabaseFiles(dir.path);
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

  /// Backs up (renames, never deletes) the database files when the format is
  /// incompatible. Returns the backup path of the main .isar file, or null
  /// if there was nothing to back up.
  static Future<String?> _backupDatabaseFiles(String directory) async {
    String? backupPath;
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    final dbFile = File('$directory/$_databaseName.isar');
    if (await dbFile.exists()) {
      backupPath = '$directory/$_databaseName.isar.backup_$timestamp';
      await dbFile.rename(backupPath);
    }

    // Lock file holds no user data — safe to drop.
    final lockFile = File('$directory/$_databaseName.isar.lock');
    if (await lockFile.exists()) {
      await lockFile.delete();
    }

    // Defensive handling for older recovery code that treated the database
    // file path as a directory.
    final legacyDirectory = Directory('$directory/$_databaseName.isar');
    if (await legacyDirectory.exists()) {
      await legacyDirectory.rename(
        '$directory/$_databaseName.isar.backup_$timestamp',
      );
      backupPath ??= '$directory/$_databaseName.isar.backup_$timestamp';
    }

    return backupPath;
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

  /// Get the network server collection.
  static IsarCollection<NetworkServerEntity> get networkServers =>
      _instance!.networkServerEntitys;
}
