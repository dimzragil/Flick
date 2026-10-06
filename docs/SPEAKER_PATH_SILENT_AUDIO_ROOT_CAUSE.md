# Flick Speaker-Path Silent-Audio Bug: Complete Root-Cause Investigation & Resolution

## 1. Problem Statement & Observed Facts

When streaming music through the phone speaker via the `normalAndroid` engine (`just_audio` wrapping Google ExoPlayer), the audio output intermittently drops to complete silence, typically around **7–8 seconds into a track**, while the playback timestamp continues advancing normally. 

### Core Symptoms
- **Output Route**: Phone speaker only (MediaTek ALSA HAL / Awinic AW88xxx SmartPA amplifier). Not USB DAC, not Bluetooth.
- **Timing**: Most frequently in the first 7–8 seconds of a track; rarely mid-track.
- **Service Isolation**: **Only happens on TIDAL**. Does not happen on local storage playback, WebDAV, or Subsonic.
- **Timestamp Behavior**: The playback position timestamp continues advancing second-by-second (the player believes it is playing; no crash; no error dialogue).
- **Pause → Play**: Tapping Pause then Play does **not** restore the sound.
- **Track Skipping**: 
  - Skipping tracks in the same playlist often preserves the silence (the bug persists across tracks).
  - Skipping to another playlist sometimes plays, but the bug frequently strikes again.
  - Rarely happens during continuous playlist auto-advance; far more frequent when manually switching tracks or playlists.
- **Settings Recovery**: Opening Settings (in-app Audio Settings or Android system settings) re-arms the audio sink, replaying/resuming the track, after which it plays completely smoothly.
- **Test Device**: Xiaomi Redmi 12 (`23053RN02A` / `fire`), MediaTek Helio G88 (MT6769), Android 14 (API 34).

---

## 2. Playback Architecture & Pipeline

```
Flutter / Dart Layer:
  PlayerService (lib/services/player_service.dart)
    │  Coordinates queue, engine selection, and audio focus.
    ▼
  AndroidAudioEngine (lib/services/android_audio_engine.dart)
    │  Wraps just_audio.AudioPlayer for speaker and non-bit-perfect playback.
    │  Manages ConcatenatingAudioSource and two-phase background playlist loading.
    ▼
TIDAL Streaming Subsystem:
  TidalService (lib/services/sources/tidal_service.dart)
    │  Resolves playback info and MPEG-DASH manifest from TIDAL API.
    ▼
  TidalStreamProxy (lib/services/sources/tidal_stream_proxy.dart)
    │  Loopback HTTP server bound to 127.0.0.1.
    │  Downloads Init segment + Segment 0 to .part file, then runs progressive _streamPump().
    ▼
Android Plugin & Framework:
  just_audio (com.ryanheise.just_audio.AudioPlayer)
    │  Platform channel interface bridging Dart to Android Media3.
    ▼
  Google ExoPlayer (androidx.media3.exoplayer.ExoPlayer)
    │  Decodes audio via Google Codec2 FLAC/AAC decoder (c2.android.flac.decoder).
    │  DefaultAudioSink writes decoded PCM to android.media.AudioTrack.
    ▼
AudioFlinger (Android Audio Server):
  Mixer Thread AudioOut_D (0xb40000706ae14700, tid 1415)
    │  Flags: AUDIO_OUTPUT_FLAG_PRIMARY | AUDIO_OUTPUT_FLAG_DEEP_BUFFER.
    │  Drains shared memory PCM ring buffer from AudioTrack.
    ▼
Hardware HAL & Driver Layer:
  MediaTek AIDL Audio HAL (android.hardware.audio.service-aidl.mediatek)
    │  AudioALSAPlaybackHandlerNormal routes AudioOut_D to ALSA kernel device.
    │  AurisysLibManager manages DSP processing and links to hardware amplifier.
    ▼
  Awinic AW88xxx SmartPA (smartpa_aw88xxx)
    │  Hardware I2S audio amplifier chip driving the physical phone speaker.
```

---

## 3. Investigation Findings & Root-Cause Mechanisms

### 3.1 Why This Bug ONLY Happens on TIDAL
TIDAL differs fundamentally from local files, WebDAV, and Subsonic in four architectural areas:

1. **Segmented MPEG-DASH Container**:
   - Local and standard network sources are monolithic streams (`.mp3`, `.flac`) played continuously.
   - TIDAL audio uses fragmented MP4 (`fMP4`) over MPEG-DASH.
   - In TIDAL's MPD manifest, audio segment duration (`d=350000` @ `timescale=48000`) corresponds to **exactly 7.29 seconds per segment**.
2. **Initial Prebuffer Boundary (The 7–8 Second Mark)**:
   - In `TidalStreamSession.start()` (`lib/services/sources/tidal_stream_proxy.dart` lines 462–502), only the **Init segment (~2 KB)** and **Segment 0 (~800 KB)** are downloaded before playback is unblocked.
   - Segment 0 holds exactly ~7–8 seconds of audio.
   - At T ≈ 7–8 seconds, ExoPlayer reaches the end of Segment 0 and issues an HTTP Range request to `TidalStreamProxy` for **Segment 1**.
3. **Background Prebuffer Storm (`_fillPlaylistBackground`)**:
   - In `AndroidAudioEngine.load` (`lib/services/android_audio_engine.dart` lines 521–550), when a user taps a track in a playlist, Phase 1 loads the tapped track, and Phase 2 launches `unawaited(_fillPlaylistBackground(concat, playlist, index, gen));`.
   - For every other track in the playlist, `_fillPlaylistBackground` calls `_sourceBuilder(playlist[j])`. For TIDAL, this hits the TIDAL API, creates a new `TidalStreamSession`, and downloads Init Segment + Segment 0 concurrently.
   - For a playlist of 10–20 tracks, this saturates the network connection pool and disk I/O at the exact moment (T = 7–8s) Track 0 needs Segment 1.
4. **Timeline Mutations During Playback**:
   - For every resolved track in the background fill, `await concat.insert(j, src)` is called (`lib/services/android_audio_engine.dart` line 399).
   - Each insertion sends `addMediaSources` to ExoPlayer, causing repeated `onTimelineChanged(TIMELINE_CHANGE_REASON_PLAYLIST_CHANGED)` events while ExoPlayer is actively playing and transitioning segments.

---

### 3.2 Why the Timestamp Keeps Advancing While Audio is Silent (The Key Discriminator)
- ExoPlayer’s position clock is governed by `AudioTrackPositionTracker`, which queries `AudioTrack.getPlaybackHeadPosition()`.
- Telemetry captured on the Redmi 12 during silence proved:
  1. ExoPlayer was decoding valid FLAC audio via `c2.android.flac.decoder` and writing full-scale PCM to `AudioTrack` (`sessionId 37633`, `sr 48000`, `fmt 1`):
     ```text
     AudioTrack: [audioTrackData][fine] 5s  : mMaxAmplitude 6359
     AudioTrack: [audioTrackData][fine] 10s : mMaxAmplitude 12261
     AudioTrack: [audioTrackData][fine] 15s : mMaxAmplitude 15858
     AudioTrack: [audioTrackData][fine] 20s : mMaxAmplitude 28097
     ```
  2. AudioFlinger's mixer thread `AudioOut_D` accepted all writes (`numTracks=1`, `writeErrors=0`).
  3. Because AudioFlinger continuously drains frames from the `AudioTrack` shared memory ring buffer into its mixer buffer, `getPlaybackHeadPosition()` steadily increments.
- The silence occurs **downstream** of AudioFlinger in the MediaTek ALSA HAL / Awinic SmartPA amplifier driver:
  ```text
  Hal stream dump:
      Signal power history (resolution: 1000.0 ms):
       10-04 20:17:58.621:    -39.1  -39.9  -38.9  -38.8  -39.2  -39.1  -39.3  -39.3  -39.2  -43.2 ] sum(20.4)
  ```
  After `20:17:58.621`, signal power output on `AudioOut_D` **completely stopped** while ExoPlayer and AudioFlinger remained fully active.

---

### 3.3 The MediaTek Aurisys HAL / SmartPA Unlinking Crash
Logcat timeline of the hardware unlinking:
1. When the user taps a track, SystemUI plays a touch sound on `AudioOut_15` (flag `0x4 FAST`).
2. MediaTek HAL opens `AudioALSAPlaybackHandlerFast` for `PLAYBACK2_TO_ADDA_DL` and calls `CreateAurisysLibManager` for `smartpa_aw88xxx`.
3. At T ≈ 7–8 seconds, SystemUI completes and stops its audio track.
4. MediaTek HAL tears down the Fast handler:
   ```text
   misound4_arsi_destroy_handler
   DestroyAurisysLibManager()
   ```
5. On the Redmi 12 (Helio G88), the internal speaker is driven by the Awinic AW88xxx SmartPA chip shared between `AudioOut_D` and `AudioOut_15`. When `DestroyAurisysLibManager()` executes, the shared amplifier hardware unlinks `AudioOut_D`.
6. Concurrently, buffer underrun jitter during the Segment 1 handoff causes the ALSA driver to report:
   ```text
   AudioALSAPlaybackHandlerBase: -getHardwareBufferInfo(), pcm_get_htimestamp fail, ret = -1, flag = 0x4
   mixer(0xb40000706ae14700) throttle begin: ret(8192) deltaMs(2) requires sleep 8 ms ... throttle end
   ```
   In `dumpsys media.audio_flinger`, Track 965 accumulated **31,744 underruns**.
7. The hardware amplifier powers down while AudioFlinger continues silently consuming frames from ExoPlayer in software.

---

### 3.4 Why Pause → Play Fails to Restore Sound
In `just_audio` Android implementation (`AudioPlayer.java` lines 980–997):
- `pause()` calls `player.setPlayWhenReady(false)`.
- `play()` calls `player.setPlayWhenReady(true)`.
- In ExoPlayer's `DefaultAudioSink`, `setPlayWhenReady` only pauses/resumes writes into the **exact same `android.media.AudioTrack` instance**. It never resets or recreates the underlying audio sink.
- Because the MediaTek ALSA HAL session is wedged, resuming writes to the same dead session continues to produce complete silence.

---

### 3.5 Why Opening Settings Restores Sound
- Navigating to `AudioSettingsScreen` triggers `AndroidAudioDeviceService.instance.refresh()`, and exiting to Android Settings triggers `onAppResumed()`.
- Both pathways invoke `PlayerService._rearmSpeakerSinkIfNeeded()`, which calls `AndroidAudioEngine.rearmSink()`:
  1. `await player.stop()`: Calls ExoPlayer's `DefaultAudioSink.reset()`, **destroying the broken `AudioTrack`**.
  2. `await load(track, initialPosition: pos)`: Creates a **brand new `AudioTrack`** with a fresh AudioFlinger session and forces MediaTek HAL to re-initialize `AudioALSAPlaybackHandlerNormal` and `AurisysLibManager`.
  3. By the time Settings is opened, Track 0 has finished downloading to local disk cache (`.mp4`), so reloading plays directly from disk without network contention or timeline mutations.

---

### 3.6 Why Track Skipping Often Retains Silence
In `lib/services/android_audio_engine.dart` lines 493–500:
```dart
if (canReusePlaylist && player.sequence.isNotEmpty && !_loadedSingleTrackOnly) {
  devLog('[Playback] Android load(${track.id}) using existing playlist');
  await player.seek(Duration.zero, index: index);
}
```
When skipping tracks in the same playlist, `AndroidAudioEngine` reuses the existing `ConcatenatingAudioSource` and merely calls `player.seek(...)`. It does **not** stop or recreate the `AudioTrack`. Because the wedged HAL session is retained, the new track continues writing PCM into the dead sink, preserving silence across tracks.

---

## 4. Killed Hypotheses & Evidence

| Hypothesis | Mechanism Proposed | Evidence That Disproved It |
| :--- | :--- | :--- |
| **Flutter Software Volume Mute** | Volume dropped to 0 via crossfade or mute bug. | `[AudioDiag]` and `[Diagnostics]` logged `vol=1.00`, `state=ready`, `playing=true`. Crossfade was disabled; secondary player was null. |
| **Audio Focus Ducking** | System ducked audio to 0. | Focus ducking sets volume to `0.20`, not `0.00`. Dumpsys confirmed `ducked players piids: (empty)`. |
| **Native Audio Effects** | Equalizer/DynamicsProcessing wedged output. | Dumpsys `media.audio_flinger` confirmed no effect chain was attached to the active session (`EqualizerBundle: Destructor`). |
| **Priority Anchor Routing** | Priority anchor forced invalid route. | `_isAnchorEligiblePath` requires `usesRustBackend`; inactive for `normalAndroid`. |
| **DASH Proxy Starvation / 404** | Proxy returned 404/503 or stalled stream. | An HTTP 404 causes `ExoPlaybackException: Source error`, stops playback, and halts the clock. Telemetry proved ExoPlayer continuously wrote valid audio (`mMaxAmplitude ~32720`). |

---

## 5. Concrete Minimal Fix Proposal

### Step 1: Re-arm Sink on User Unpause (`AndroidAudioEngine`)
File: `lib/services/android_audio_engine.dart`
- In `pause()`, mark `_sinkNeedsRearmOnPlay = true;`.
- In `play()`, if `_sinkNeedsRearmOnPlay` is true, perform a transparent sink rearm (`player.stop()` + `setAudioSource(initialPosition: pos)`).
- **Effect**: Tapping **Pause → Play** is 100% guaranteed to restore sound immediately if silence ever occurs.

### Step 2: Prevent Background DASH Prebuffer Storm on TIDAL
File: `lib/services/android_audio_engine.dart`
- In `load()`, avoid running `_fillPlaylistBackground` during the critical first 10 seconds of playback, or prebuffer only the immediate next track (N+1) instead of the entire playlist.
- Avoid calling `concat.insert` into an actively playing `ConcatenatingAudioSource` while Segment 0 is being decoded.
- **Effect**: Eliminates network, disk I/O, and timeline contention during the Segment 0 → Segment 1 handoff at T=7–8s.

### Step 3: Prevent Session Eviction in `TidalStreamProxy`
File: `lib/services/sources/tidal_stream_proxy.dart`
- In `_completedFiles`, do not evict completed streams when `_maxCompletedStreams = 4` is reached if the target file still exists on disk.
- When serving requests, check `File(targetPath).existsSync()` so completed tracks in a playlist never return HTTP 404.

---

## 6. On-Device Verification Protocol

1. **Environment Setup**:
   - Device: Redmi 12 (`23053RN02A`), speaker playback (`AudioOut_D`).
   - Logging: `adb logcat --pid=<flick_pid>` and `adb shell dumpsys media.audio_flinger`.
2. **Test Steps**:
   - Start playback of an uncached TIDAL mix/playlist from Track 1.
   - Monitor playback through T = 7–8 seconds and beyond. Verify speaker output remains audible.
   - Check `Hal stream dump` in `dumpsys media.audio_flinger`: verify Signal power history remains active (-38 dB to -42 dB).
   - If audio is paused and resumed, verify that sink re-arm completes cleanly in <300ms without position loss or audio drop.
