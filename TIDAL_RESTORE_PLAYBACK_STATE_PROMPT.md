# Task Prompt: Persistence & Restoration of TIDAL Playback State on App Restart / Process Kill

Dokumen ini adalah instruksi prompt lengkap bagi AI Agent atau pengembang untuk mengimplementasikan fitur penyimpanan dan pemulihan (*persistence & restoration*) status pemutaran lagu TIDAL saat aplikasi ditutup, di-*kill*, atau dihapus dari *recent apps* (multitasking). Setelah fitur ini aktif, lagu TIDAL yang terakhir diputar akan tetap muncul di *mini player* / *player* tepat di menit dan detik terakhir, lengkap dengan *metadata*, *artwork*, serta *playlist context*, sama persis seperti pemutaran lagu *offline* lokal bawaan Flick.

---

# 1. Background & Root Cause Analysis

### Masalah
Pada Flick, pemutaran lagu *offline* lokal (lagu di penyimpanan perangkat) memiliki fitur *state restoration*: saat pengguna keluar dari aplikasi atau mematikan aplikasi lalu membukanya kembali, lagu terakhir yang diputar otomatis dipulihkan pada *timestamp* terakhir (misal menit 02:45). Namun, untuk lagu streaming **TIDAL**, ketika aplikasi ditutup atau di-*kill*, player kembali ke status kosong (*idle* tanpa lagu).

### Mengapa Lagu Offline Berhasil, tetapi Lagu TIDAL Gagal?
1. **Penyimpanan ID Saja di `LastPlayedService`**:
   `LastPlayedService.saveLastPlayed()` (`lib/services/last_played_service.dart`) saat ini hanya menyimpan ID lagu (`prefs.setString(_lastSongIdKey, songId)`) dan daftar ID playlist (`_lastPlaylistSongIdsKey`).
2. **Ketergantungan ke Database Isar Lokal pada `getLastPlayed()`**:
   Saat aplikasi dibuka, `main.dart` memanggil `playerService.restoreLastPlayed()`, yang kemudian memanggil `LastPlayedService.getLastPlayed()`. Di dalam `getLastPlayed()`:
   ```dart
   final songId = prefs.getString(_lastSongIdKey);
   if (songId == null) return null;

   // Mencari lagu di database Isar lokal:
   final allSongs = await _songRepository.getAllSongs();
   final song = allSongs.where((s) => s.id == songId).firstOrNull;

   if (song == null) return null;
   ```
   - Lagu *offline* tersimpan di database lokal Isar (`_songRepository.getAllSongs()`), sehingga pencarian berdasarkan ID berhasil.
   - Lagu **TIDAL** adalah objek *ephemeral* (`TidalService.makeEphemeralSong`) dengan format ID `tidal_<serverId>_<remoteId>`. Lagu TIDAL **TIDAK PERNAH** dimasukkan ke dalam database Isar lokal.
   - Akibatnya, `allSongs.where((s) => s.id == songId).firstOrNull` selalu menghasilkan **`null`**!
   - `getLastPlayed()` langsung mengembalikan `null`, dan pemulihan lagu TIDAL batal total.
3. **Model `Song` Belum Memiliki Serialisasi JSON**:
   `Song` (`lib/models/song.dart`) belum memiliki metode `toJson()` dan `factory Song.fromJson()`.
4. **Engine & PlayerService Sebenarnya Sudah Siap 100%**:
   Di `lib/services/player_service.dart:5042-5048` dan `lib/services/audio_engine_manager.dart:123-138`, pemutar audio (`playTrack`) **sudah memiliki parameter `initialPosition`** dan logika `seek(initialPosition)` serta resolusi HTTP streaming (`RemoteSourceService.resolveHttpPlayback`). Jadi satu-satunya mata rantai yang terputus adalah lapisan penyimpanan (*persistence layer*).

---

# 2. Objectives

1. Tambahkan metode serialisasi `toJson()` dan `Song.fromJson()` yang lengkap dan aman di `lib/models/song.dart`.
2. Perbarui `lib/services/last_played_service.dart`:
   - Simpan representasi JSON lengkap dari `Song` dan `playlist` ke `SharedPreferences` menggunakan key baru (`last_played_song_data` dan `last_played_playlist_data`), sambil tetap menyimpan key lama untuk kompatibilitas ke belakang (*backward compatibility*).
   - Di `getLastPlayed()`, prioritaskan pemulihan dari JSON `Song.fromJson()` terlebih dahulu. Jika ada, lagu TIDAL langsung berhasil dipulihkan secara instan tanpa perlu query database lokal. Jika tidak ada (data lama), lakukan *fallback* ke `_songRepository.getAllSongs()`.
   - Lakukan hal yang sama untuk pemulihan `playlist` (prioritaskan JSON, fallback ke ID list).
3. Perbarui `lib/services/player_service.dart`:
   - Di `_savePosition()`, kirimkan objek `Song` penuh dan daftar `playlist` ke `saveLastPlayed`.
   - Panggil `_savePosition()` secara sigap saat `pause()` dan `seek()`, melengkapi timer 5 detik dan event `didChangeAppLifecycleState` (`AppLifecycleState.paused` & `detached`).
4. Buat unit test di `test/services/last_played_service_test.dart` untuk memastikan penyimpanan dan pemulihan lagu TIDAL berjalan sempurna tanpa regresi.

---

# 3. Target Files
1. `lib/models/song.dart`
2. `lib/services/last_played_service.dart`
3. `lib/services/player_service.dart`
4. `test/services/last_played_service_test.dart` *(file baru)*

---

# 4. Detailed Step-by-Step Implementation

### Step 1: Tambahkan `toJson()` dan `Song.fromJson()` di `lib/models/song.dart`

Buka `lib/models/song.dart` dan tambahkan metode berikut di dalam `class Song`:

```dart
  /// Convert [Song] to a JSON-serializable Map for state persistence.
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'albumArt': albumArt,
    'durationMs': duration.inMilliseconds,
    'fileType': fileType,
    'resolution': resolution,
    'sampleRate': sampleRate,
    'bitDepth': bitDepth,
    'replaygainTrackGain': replaygainTrackGain,
    'replaygainTrackPeak': replaygainTrackPeak,
    'replaygainAlbumGain': replaygainAlbumGain,
    'replaygainAlbumPeak': replaygainAlbumPeak,
    'startOffsetMs': startOffsetMs,
    'endOffsetMs': endOffsetMs,
    'ripper': ripper,
    'readMode': readMode,
    'accurateRip': accurateRip,
    'testCrc': testCrc,
    'copyCrc': copyCrc,
    'album': album,
    'albumArtist': albumArtist,
    'trackNumber': trackNumber,
    'discNumber': discNumber,
    'year': year,
    'genre': genre,
    'filePath': filePath,
    'folderUri': folderUri,
    'dateAdded': dateAdded?.toIso8601String(),
    'isExternal': isExternal,
    'sourcePackage': sourcePackage,
    'sourceType': sourceType,
    'remoteId': remoteId,
    'remoteServerId': remoteServerId,
  };

  /// Recreate a [Song] instance from a serialized JSON Map.
  factory Song.fromJson(Map<String, dynamic> json) {
    return Song(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      albumArt: json['albumArt'] as String?,
      duration: Duration(
        milliseconds: (json['durationMs'] as num?)?.toInt() ??
            (json['duration'] as num?)?.toInt() ??
            0,
      ),
      fileType: json['fileType'] as String? ?? 'flac',
      resolution: json['resolution'] as String?,
      sampleRate: (json['sampleRate'] as num?)?.toInt(),
      bitDepth: (json['bitDepth'] as num?)?.toInt(),
      replaygainTrackGain: (json['replaygainTrackGain'] as num?)?.toDouble(),
      replaygainTrackPeak: (json['replaygainTrackPeak'] as num?)?.toDouble(),
      replaygainAlbumGain: (json['replaygainAlbumGain'] as num?)?.toDouble(),
      replaygainAlbumPeak: (json['replaygainAlbumPeak'] as num?)?.toDouble(),
      startOffsetMs: (json['startOffsetMs'] as num?)?.toInt(),
      endOffsetMs: (json['endOffsetMs'] as num?)?.toInt(),
      ripper: json['ripper'] as String?,
      readMode: json['readMode'] as String?,
      accurateRip: json['accurateRip'] as bool?,
      testCrc: json['testCrc'] as String?,
      copyCrc: json['copyCrc'] as String?,
      album: json['album'] as String?,
      albumArtist: json['albumArtist'] as String?,
      trackNumber: (json['trackNumber'] as num?)?.toInt(),
      discNumber: (json['discNumber'] as num?)?.toInt(),
      year: (json['year'] as num?)?.toInt(),
      genre: json['genre'] as String?,
      filePath: json['filePath'] as String?,
      folderUri: json['folderUri'] as String?,
      dateAdded: json['dateAdded'] != null
          ? DateTime.tryParse(json['dateAdded'] as String)
          : null,
      isExternal: json['isExternal'] as bool? ?? false,
      sourcePackage: json['sourcePackage'] as String?,
      sourceType: json['sourceType'] as String?,
      remoteId: json['remoteId'] as String?,
      remoteServerId: (json['remoteServerId'] as num?)?.toInt(),
    );
  }
```

---

### Step 2: Perbarui `lib/services/last_played_service.dart`

Ganti isi `lib/services/last_played_service.dart` dengan kode yang mendukung penyimpanan dan pemulihan JSON:

```dart
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/models/song.dart';
import 'package:flick/data/repositories/song_repository.dart';

/// Service for persisting and restoring the last played song.
class LastPlayedService {
  static const String _lastSongIdKey = 'last_played_song_id';
  static const String _lastSongDataKey = 'last_played_song_data';
  static const String _lastPositionKey = 'last_played_position_ms';
  static const String _lastPlaylistSongIdsKey = 'last_played_playlist_song_ids';
  static const String _lastPlaylistDataKey = 'last_played_playlist_data';
  static const String _lastPlaylistIndexKey = 'last_played_playlist_index';
  static const String _lastWasPlayingKey = 'last_played_was_playing';

  final SongRepository _songRepository;

  LastPlayedService({SongRepository? songRepository})
    : _songRepository = songRepository ?? SongRepository();

  /// Save the currently playing song and position.
  ///
  /// Stores full song and playlist JSON so ephemeral network tracks (e.g. TIDAL)
  /// and local database tracks can both be restored seamlessly across app restarts.
  Future<void> saveLastPlayed(
    Song song,
    Duration position, {
    List<Song>? playlist,
    int? currentIndex,
    bool wasPlaying = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastSongIdKey, song.id);
    await prefs.setInt(_lastPositionKey, position.inMilliseconds);
    await prefs.setBool(_lastWasPlayingKey, wasPlaying);

    // Persist full song JSON
    try {
      await prefs.setString(_lastSongDataKey, jsonEncode(song.toJson()));
    } catch (_) {
      // Ignore serialization issues
    }

    if (playlist != null && playlist.isNotEmpty) {
      // Legacy IDs for backward compatibility
      await prefs.setString(
        _lastPlaylistSongIdsKey,
        jsonEncode(playlist.map((s) => s.id).toList()),
      );
      // Full playlist JSON for ephemeral / network streams (e.g. TIDAL)
      try {
        await prefs.setString(
          _lastPlaylistDataKey,
          jsonEncode(playlist.map((s) => s.toJson()).toList()),
        );
      } catch (_) {
        // Ignore serialization issues
      }

      if (currentIndex != null && currentIndex >= 0) {
        await prefs.setInt(_lastPlaylistIndexKey, currentIndex);
      }
    } else {
      // Clear stale playlist context when no playlist is active
      await prefs.remove(_lastPlaylistSongIdsKey);
      await prefs.remove(_lastPlaylistDataKey);
      await prefs.remove(_lastPlaylistIndexKey);
    }
  }

  /// Get the last played song and position.
  /// Returns null if no song was previously played.
  Future<
    ({
      Song song,
      Duration position,
      List<Song>? playlist,
      int? playlistIndex,
      bool wasPlaying,
    })?
  >
  getLastPlayed() async {
    final prefs = await SharedPreferences.getInstance();
    final songId = prefs.getString(_lastSongIdKey);
    if (songId == null) return null;

    Song? song;

    // 1. Primary: Restore from serialized song JSON (supports TIDAL & local)
    final songDataRaw = prefs.getString(_lastSongDataKey);
    if (songDataRaw != null && songDataRaw.isNotEmpty) {
      try {
        final dynamic decoded = jsonDecode(songDataRaw);
        if (decoded is Map<String, dynamic>) {
          song = Song.fromJson(decoded);
        }
      } catch (_) {
        // Fallback to repository
      }
    }

    // 2. Fallback: Lookup in local database if JSON not present (backward compatibility)
    if (song == null) {
      final allSongs = await _songRepository.getAllSongs();
      song = allSongs.where((s) => s.id == songId).firstOrNull;
    }

    if (song == null) return null;

    List<Song>? restoredPlaylist;
    int? restoredPlaylistIndex;

    // 1. Primary: Restore playlist from serialized JSON
    final playlistDataRaw = prefs.getString(_lastPlaylistDataKey);
    if (playlistDataRaw != null && playlistDataRaw.isNotEmpty) {
      try {
        final dynamic decoded = jsonDecode(playlistDataRaw);
        if (decoded is List) {
          final mapped = <Song>[];
          for (final item in decoded) {
            if (item is Map<String, dynamic>) {
              mapped.add(Song.fromJson(item));
            }
          }
          if (mapped.isNotEmpty) {
            restoredPlaylist = mapped;
          }
        }
      } catch (_) {
        // Fallback to legacy ID lookup
      }
    }

    // 2. Fallback: Lookup playlist song IDs in local database
    if (restoredPlaylist == null) {
      final playlistSongIdsRaw = prefs.getString(_lastPlaylistSongIdsKey);
      if (playlistSongIdsRaw != null) {
        try {
          final dynamic decoded = jsonDecode(playlistSongIdsRaw);
          if (decoded is List) {
            final playlistSongIds = decoded.whereType<String>().toList();
            if (playlistSongIds.isNotEmpty) {
              final allSongs = await _songRepository.getAllSongs();
              final songsById = {for (final s in allSongs) s.id: s};
              final mapped = <Song>[];
              for (final id in playlistSongIds) {
                final found = songsById[id];
                if (found != null) {
                  mapped.add(found);
                }
              }
              if (mapped.isNotEmpty) {
                restoredPlaylist = mapped;
              }
            }
          }
        } catch (_) {
          // Ignore invalid or stale persisted playlist JSON
        }
      }
    }

    if (restoredPlaylist != null && restoredPlaylist.isNotEmpty) {
      final storedIndex = prefs.getInt(_lastPlaylistIndexKey);
      if (storedIndex != null &&
          storedIndex >= 0 &&
          storedIndex < restoredPlaylist.length &&
          restoredPlaylist[storedIndex].id == song.id) {
        restoredPlaylistIndex = storedIndex;
      } else {
        final songIndex = restoredPlaylist.indexWhere((s) => s.id == song.id);
        restoredPlaylistIndex = songIndex >= 0 ? songIndex : 0;
      }
    }

    final positionMs = prefs.getInt(_lastPositionKey) ?? 0;
    final wasPlaying = prefs.getBool(_lastWasPlayingKey) ?? false;
    return (
      song: song,
      position: Duration(milliseconds: positionMs),
      playlist: restoredPlaylist,
      playlistIndex: restoredPlaylistIndex,
      wasPlaying: wasPlaying,
    );
  }

  /// Clear the last played state.
  Future<void> clearLastPlayed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastSongIdKey);
    await prefs.remove(_lastSongDataKey);
    await prefs.remove(_lastPositionKey);
    await prefs.remove(_lastPlaylistSongIdsKey);
    await prefs.remove(_lastPlaylistDataKey);
    await prefs.remove(_lastPlaylistIndexKey);
    await prefs.remove(_lastWasPlayingKey);
  }
}
```

---

### Step 3: Perbarui `lib/services/player_service.dart`

Di file `lib/services/player_service.dart`:

#### A. Perbarui `_savePosition()` (Baris ~4878)
Ganti implementasi `_savePosition` agar menyusun daftar lagu non-antrean dan mengirimkan objek `Song` penuh:

```dart
  Future<void> _savePosition({Song? song, Duration? position}) async {
    final resolvedSong = song ?? currentSongNotifier.value;
    if (!_shouldPersistSong(resolvedSong)) return;
    final persistedSong = resolvedSong!;

    try {
      int? playlistIndex = _currentIndex;
      final nonQueueSongs = <Song>[];
      for (var i = 0; i < _playlist.length; i++) {
        if (i >= _playlistQueueEntryIds.length ||
            _playlistQueueEntryIds[i] == null) {
          if (i == _currentIndex) {
            playlistIndex = nonQueueSongs.length;
          }
          nonQueueSongs.add(_playlist[i]);
        }
      }

      await _lastPlayedService.saveLastPlayed(
        persistedSong,
        position ?? positionNotifier.value,
        playlist: nonQueueSongs.isNotEmpty ? nonQueueSongs : null,
        currentIndex: playlistIndex,
        wasPlaying: isPlayingNotifier.value,
      );
    } catch (e) {
      _debugLog('Failed to save last played position: $e');
    }
  }
```

#### B. Simpan Posisi Lebih Sigap saat `pause()` & `seek()`
1. Pada `_pauseInternal()` (Baris ~4995):
```dart
    try {
      await _playbackManager.pause();
    } catch (e) {
      _debugLog('Pause failed: $e');
    }
    unawaited(_savePosition()); // <-- Tambahkan ini agar posisi saat pause langsung tersimpan ke SharedPreferences
```

2. Pada `seek(Duration position)` (Baris ~5343):
```dart
    try {
      await _playbackManager.seek(position);
    } catch (e) {
      _debugLog('Seek failed: $e');
    }
    unawaited(_savePosition(position: position)); // <-- Tambahkan ini agar timestamp baru langsung tersimpan
    unawaited(_updateNotificationState());
```

---

### Step 4: Buat Unit Test di `test/services/last_played_service_test.dart`

Buat file baru `test/services/last_played_service_test.dart` untuk memverifikasi fungsionalitas ini:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/last_played_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Song JSON serialization', () {
    test('Song.toJson and Song.fromJson preserve all network/TIDAL fields', () {
      const originalSong = Song(
        id: 'tidal_9_12345678',
        title: 'Starboy',
        artist: 'The Weeknd',
        album: 'Starboy',
        albumArt: 'https://resources.tidal.com/images/123/640x640.jpg',
        duration: Duration(minutes: 3, seconds: 50),
        fileType: 'flac',
        resolution: '16-bit / 44.1kHz / 1411kbps',
        sampleRate: 44100,
        bitDepth: 16,
        filePath: 'tidal://9/12345678',
        sourceType: 'tidal',
        remoteId: '12345678',
        remoteServerId: 9,
      );

      final json = originalSong.toJson();
      final restored = Song.fromJson(json);

      expect(restored.id, originalSong.id);
      expect(restored.title, originalSong.title);
      expect(restored.artist, originalSong.artist);
      expect(restored.album, originalSong.album);
      expect(restored.albumArt, originalSong.albumArt);
      expect(restored.duration, originalSong.duration);
      expect(restored.fileType, originalSong.fileType);
      expect(restored.resolution, originalSong.resolution);
      expect(restored.sampleRate, originalSong.sampleRate);
      expect(restored.bitDepth, originalSong.bitDepth);
      expect(restored.filePath, originalSong.filePath);
      expect(restored.sourceType, originalSong.sourceType);
      expect(restored.remoteId, originalSong.remoteId);
      expect(restored.remoteServerId, originalSong.remoteServerId);
      expect(restored.isNetworkSource, isTrue);
    });
  });

  group('LastPlayedService TIDAL track restoration', () {
    test('saves and restores ephemeral TIDAL song without local DB', () async {
      final service = LastPlayedService();

      const tidalSong = Song(
        id: 'tidal_9_999888',
        title: 'Blinding Lights',
        artist: 'The Weeknd',
        album: 'After Hours',
        albumArt: 'https://resources.tidal.com/images/456/640x640.jpg',
        duration: Duration(minutes: 3, seconds: 20),
        fileType: 'flac',
        filePath: 'tidal://9/999888',
        sourceType: 'tidal',
        remoteId: '999888',
        remoteServerId: 9,
      );

      const tidalSong2 = Song(
        id: 'tidal_9_999889',
        title: 'Save Your Tears',
        artist: 'The Weeknd',
        duration: Duration(minutes: 3, seconds: 35),
        fileType: 'flac',
        filePath: 'tidal://9/999889',
        sourceType: 'tidal',
        remoteId: '999889',
        remoteServerId: 9,
      );

      final playlist = [tidalSong, tidalSong2];

      await service.saveLastPlayed(
        tidalSong,
        const Duration(minutes: 1, seconds: 45),
        playlist: playlist,
        currentIndex: 0,
        wasPlaying: true,
      );

      final result = await service.getLastPlayed();
      expect(result, isNotNull);
      expect(result!.song.id, 'tidal_9_999888');
      expect(result.song.title, 'Blinding Lights');
      expect(result.song.filePath, 'tidal://9/999888');
      expect(result.position, const Duration(minutes: 1, seconds: 45));
      expect(result.wasPlaying, isTrue);
      expect(result.playlist, isNotNull);
      expect(result.playlist!.length, 2);
      expect(result.playlist![0].id, 'tidal_9_999888');
      expect(result.playlist![1].id, 'tidal_9_999889');
      expect(result.playlistIndex, 0);
    });

    test('clearLastPlayed removes both JSON and legacy keys', () async {
      final service = LastPlayedService();
      const tidalSong = Song(
        id: 'tidal_9_1',
        title: 'Test',
        artist: 'Test',
        duration: Duration(seconds: 180),
        fileType: 'flac',
      );

      await service.saveLastPlayed(tidalSong, const Duration(seconds: 30));
      var restored = await service.getLastPlayed();
      expect(restored, isNotNull);

      await service.clearLastPlayed();
      restored = await service.getLastPlayed();
      expect(restored, isNull);
    });
  });
}
```

---

# 5. Verification Commands

Jalankan perintah pengujian untuk memverifikasi perubahan:

```bash
# 1. Jalankan unit test LastPlayedService
flutter test test/services/last_played_service_test.dart

# 2. Pastikan static analysis bersih tanpa error atau warning
dart analyze lib/models/song.dart lib/services/last_played_service.dart lib/services/player_service.dart

# 3. Jalankan suite test TIDAL yang sudah ada untuk memastikan tidak ada efek samping
flutter test test/features/tidal/tidal_screens_test.dart
```

---

# 6. Manual QA Verification Checklist

1. Buka aplikasi Flick dan navigasi ke menu **TIDAL**.
2. Putar sebuah lagu dari TIDAL (misal: "Starboy").
3. Biarkan lagu berputar sampai menit `01:30` (atau geser slider/seek ke `01:30`), lalu tekan **Pause** (atau biarkan tetap playing).
4. Tutup aplikasi atau buang Flick dari layar *Recent Apps* (*kill* aplikasi).
5. Buka kembali aplikasi Flick.
6. **Verifikasi**:
   - Di *mini player* bagian bawah, lagu TIDAL tetap muncul (Judul, Artis, Album Art).
   - Indikator posisi (*progress bar* / *timestamp*) menunjukkan tepat pada posisi saat ditinggalkan (`01:30`).
   - Latar belakang *blurred album art* (fitur yang sebelumnya dibuat) langsung menampilkan warna cover album lagu TIDAL tersebut.
   - Tekan tombol **Play** pada *mini player*: lagu TIDAL langsung menyambung (*resume*) pemutarannya dari posisi menit `01:30`.
