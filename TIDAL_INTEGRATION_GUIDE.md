# TIDAL In-App Integration Guide for AI Coding Assistant

> **Target Codebase**: `/home/shinsekai/Flick` (or `~/Flick`)  
> **Application**: Flick (Audiophile-grade Android Music Player, Flutter + Rust UAC 2.0 Engine)  
> **Goal**: Enable full interactive in-app TIDAL streaming (search, browse catalog/albums/playlists, stream on-the-fly with bit-perfect DAC output).

---

## 1. Executive Summary & Codebase Reality (MUST READ FIRST)

**Do NOT rewrite the audio engine or database from scratch.** Flick already has 80% of the plumbing implemented in the existing codebase:

### What Flick ALREADY HAS:
1. **Rust HTTP Streaming Engine**:
   - `rust/src/audio/http_source.rs` implements `HttpMediaSource`, a seekable HTTP stream reader using `ureq` and HTTP `Range: bytes=N-`.
   - `rust/src/audio/source.rs` supports `http_origin: Option<(String, HashMap<String, String>)>`.
   - `lib/services/rust_audio_service.dart` has `playHttp(url, headers)`.
   - `lib/services/rust_audio_engine.dart` resolves HTTP sources via `_resolveHttpSource` and calls `playHttp`.
   - Symphonia decodes the incoming FLAC/MP3 stream and routes PCM directly to UAC 2.0 (bit-perfect USB DAC) or Oboe (low-latency AAudio).
2. **Tidal Backend Service**:
   - `lib/services/sources/tidal_service.dart` already implements `NetworkSourceService`.
   - It already has OAuth2 Device Code login (`_authBase/device_authorization`, `_authBase/token`) with credentials `clientId` and `clientSecret`.
   - It already resolves stream URLs via `/tracks/$trackId/playbackinfopostpaywall` and decodes `vnd.tidal.bts` manifests.
   - It maps cover art via `coverUrl(uuid)`.
3. **Database & Entity Integration**:
   - `lib/data/entities/song_entity.dart` has `sourceType` (can be `NetworkProtocol.tidal`) and `remoteId`.
   - `lib/models/song.dart` has `isNetworkSource`, `sourceType`, `remoteId`.

### What is MISSING (What YOU Must Implement):
Currently, TIDAL in Flick is only a background "Network Source" synced in `Settings > Network Sources` that imports the user's favorite tracks in bulk.
There is **NO interactive in-app browsing or search**. The user cannot:
1. Search the TIDAL catalog directly in the UI.
2. Browse TIDAL artists, albums, or playlists on-the-fly.
3. Tap and play any track from search results instantly without a prior library sync.
4. Access a dedicated "Tidal" navigation tab or hub.

---

## 2. Architecture of Changes

```
┌────────────────────────────────────────────────────────┐
│                      UI LAYER                          │
│ ┌────────────────────────────────────────────────────┐ │
│ │ lib/features/tidal/screens/                        │ │
│ │  ├── tidal_hub_screen.dart (Home / Browse / Tabs)  │ │
│ │  ├── tidal_search_screen.dart (Instant Search)     │ │
│ │  └── tidal_album_screen.dart (Album Detail)        │ │
│ └────────────────────────────────────────────────────┘ │
│                           │                            │
│                           ▼                            │
│ ┌────────────────────────────────────────────────────┐ │
│ │ lib/features/tidal/providers/                      │ │
│ │  ├── tidal_auth_provider.dart                      │ │
│ │  └── tidal_catalog_provider.dart                   │ │
│ └────────────────────────────────────────────────────┘ │
└───────────────────────────┬────────────────────────────┘
                            │
                            ▼
┌────────────────────────────────────────────────────────┐
│                   SERVICE LAYER                        │
│ lib/services/sources/tidal_service.dart                │
│  ├── [Existing] signIn(), stream(), syncLibrary()      │
│  └── [NEW] search(), getAlbum(), getPlaylist(), etc.   │
└───────────────────────────┬────────────────────────────┘
                            │
                            ▼
┌────────────────────────────────────────────────────────┐
│                  PLAYBACK PIPELINE                     │
│ 1. Wrap Tidal Track as on-the-fly ephemeral `Song`     │
│ 2. PlayerService.playSong(song)                        │
│ 3. RemoteSourceService -> TidalService.streamDescriptor│
│ 4. RustAudioService.playHttp(url)                      │
│ 5. Rust HttpMediaSource -> Symphonia -> UAC 2.0 DAC    │
└────────────────────────────────────────────────────────┘
```

---

## 3. Step-by-Step Implementation Phases

### Phase 1: Extend `TidalService` with Catalog & Search APIs
**File to modify**: `lib/services/sources/tidal_service.dart`

Add methods to query TIDAL's API using the existing `_apiGet` helper:

```dart
// 1. Search Catalog
Future<Map<String, dynamic>> searchCatalog(
  NetworkServerEntity server,
  String query, {
  int limit = 25,
  int offset = 0,
}) async {
  return _apiGet(server, '/search', query: {
    'query': query,
    'limit': '$limit',
    'offset': '$offset',
    'types': 'TRACKS,ALBUMS,ARTISTS,PLAYLISTS',
  });
}

// 2. Get Album Details & Tracks
Future<Map<String, dynamic>> getAlbum(
  NetworkServerEntity server,
  String albumId,
) async {
  return _apiGet(server, '/albums/$albumId');
}

Future<List<Map<String, dynamic>>> getAlbumTracks(
  NetworkServerEntity server,
  String albumId,
) async {
  final res = await _apiGet(server, '/albums/$albumId/tracks');
  final items = (res['items'] as List<dynamic>?) ?? [];
  return items.cast<Map<String, dynamic>>();
}

// 3. Get Artist & Top Tracks
Future<List<Map<String, dynamic>>> getArtistTopTracks(
  NetworkServerEntity server,
  String artistId,
) async {
  final res = await _apiGet(server, '/artists/$artistId/toptracks');
  final items = (res['items'] as List<dynamic>?) ?? [];
  return items.cast<Map<String, dynamic>>();
}

// 4. Get User Playlists
Future<List<Map<String, dynamic>>> getUserPlaylists(
  NetworkServerEntity server,
) async {
  final creds = _creds(server.token);
  if (creds?.userId == null) return [];
  final res = await _apiGet(server, '/users/${creds!.userId}/playlists');
  final items = (res['items'] as List<dynamic>?) ?? [];
  return items.cast<Map<String, dynamic>>();
}

// 5. Build Ephemeral Song (for instant playback without DB sync)
Song buildEphemeralSong(NetworkServerEntity server, Map<String, dynamic> trackJson) {
  final remoteId = trackJson['id'].toString();
  final artists = (trackJson['artists'] as List<dynamic>?)?.cast<Map<String, dynamic>?>();
  final album = trackJson['album'] as Map<String, dynamic>?;
  final durationSec = (trackJson['duration'] as num?)?.toInt() ?? 0;
  final cover = (album?['cover'] as String?) ?? (trackJson['cover'] as String?);
  final quality = trackJson['audioQuality'] as String?;

  return Song(
    id: 'tidal_${server.id}_$remoteId',
    title: trackJson['title'] ?? 'Unknown Track',
    artist: (artists != null && artists.isNotEmpty)
        ? (artists.first?['name'] ?? 'Unknown Artist')
        : (album?['artist']?['name'] ?? 'Unknown Artist'),
    album: album?['title'],
    albumArt: cover != null ? '${TidalService.instance.coverScheme}$cover' : null,
    duration: Duration(seconds: durationSec),
    fileType: TidalService.extForQuality(quality) ?? 'flac',
    sampleRate: quality == 'HI_RES_LOSSLESS' ? 96000 : 44100,
    bitDepth: quality == 'HI_RES_LOSSLESS' ? 24 : 16,
    filePath: '${NetworkProtocol.tidal}://${server.id}/$remoteId',
    sourceType: NetworkProtocol.tidal,
    remoteId: remoteId,
    remoteServerId: server.id,
  );
}
```

---

### Phase 2: Add Tidal Riverpod Providers
**Create Directory**: `lib/features/tidal/providers/`
**File**: `lib/features/tidal/providers/tidal_providers.dart`

Implement Riverpod notifiers:
1. `tidalServerProvider`: Finds the active `NetworkServerEntity` where `protocol == NetworkProtocol.tidal`.
2. `tidalAuthStateProvider`: Indicates whether user is signed in to TIDAL.
3. `tidalSearchProvider`: Manages search query, debouncing, and search results.

---

### Phase 3: Create TIDAL Browsing & Search UI
**Create Directory**: `lib/features/tidal/screens/`

1. **`tidal_hub_screen.dart`**:
   - If not logged in: Banner with "Sign in with TIDAL" (triggers `TidalService.instance.signIn()`).
   - If logged in: Shows quick search bar at top, user favorites, user playlists, and recommended sections.
2. **`tidal_search_screen.dart`**:
   - Instant search with filters (Tracks, Albums, Artists).
   - Tapping a track: Calls `PlayerService().playSong(ephemeralSong)` immediately!
   - Tapping an album: Navigates to `TidalAlbumScreen`.
3. **`tidal_album_screen.dart`**:
   - Displays album art, title, artist, audio quality badge (`LOSSLESS` or `HI_RES_LOSSLESS`).
   - List of tracks with track numbers and duration.
   - "Play All" button (queues all tracks into `QueueService`).

---

### Phase 4: Integrate Navigation
**Files to modify**:
1. `lib/models/nav_bar_config.dart`:
   Add `tidal` to `NavBarButton`:
   ```dart
   enum NavBarButton {
     // ... existing
     tidal(9, 'Tidal', LucideIcons.waves);
   }
   ```
2. `lib/app/app.dart`:
   Add `NavBarButton.tidal => const TidalHubScreen(key: ValueKey('tidal'))` in `_buildScreen`.
3. `lib/features/menu/screens/menu_screen.dart`:
   Add a quick-access tile for "Tidal" in the streaming / network sources section of the main menu.

---

### Phase 5: Verification & Testing
1. Connect Android test device with USB DAC (or emulator for basic playback).
2. Trigger build:
   ```bash
   flutter pub get
   flutter run --release
   ```
3. Test flow:
   - Navigate to Tidal tab.
   - Sign in via Device Code flow.
   - Search for a song (e.g. "Daft Punk").
   - Tap to play → Verify `RustAudioService.playHttp` connects.
   - Connect USB DAC → Verify bit-perfect sample rate switches on DAC screen (e.g. 44.1kHz or 96kHz).

---

## 4. Coding Standards & Guidelines for AI

1. **Follow Flick's existing style**:
   - Dark theme using `AppColors.surface`, `AppColors.glassBorder`, `AppConstants.spacingMd`.
   - Use `context.scaleSize()` for responsive padding/dimensions.
   - Use `lucide_icons_flutter`.
2. **Do NOT run build_runner unless models change**:
   - If you only add helper methods or UI widgets, `build_runner` is NOT needed.
3. **Handle Errors Gracefully**:
   - Wrap network calls with try/catch and show `AppFeedback` or toast on network drops.
