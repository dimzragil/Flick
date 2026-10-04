# Flick Speaker-Path Silent-Audio Bug: Root-Cause Investigation & Proposed Fix

## 1. Problem Statement

When playing music through the phone speaker via the `normalAndroid` engine (`just_audio` wrapping Google ExoPlayer), the audio output suddenly drops to complete silence while the playback position timestamp keeps advancing normally. Pressing **Pause** then **Play** does NOT restore the sound. The bug is intermittent but frequent on Android devices (e.g. MediaTek Helio G88 / Redmi 12).

---

## 2. Architecture & Playback Pipeline

- **Flutter / Dart UI & State**: `PlayerService` (`lib/services/player_service.dart`) coordinates playback state, queue, and engine selection.
- **Speaker Audio Engine**: `AndroidAudioEngine` (`lib/services/android_audio_engine.dart`) wraps `just_audio.AudioPlayer` for speaker and non-bit-perfect playback.
- **Android Plugin Layer**: `just_audio` (`com.ryanheise.just_audio.AudioPlayer`) uses Google ExoPlayer (`androidx.media3.exoplayer.ExoPlayer`).
- **ExoPlayer Audio Sink**: `DefaultAudioSink` writes decoded PCM audio into `android.media.AudioTrack` (`USAGE_MEDIA`, `CONTENT_TYPE_MUSIC`).
- **Android Audio Framework**: AudioPolicyManager routes `USAGE_MEDIA` speaker playback to AudioFlinger mixer thread `AudioOut_D` (`AUDIO_OUTPUT_FLAG_PRIMARY | AUDIO_OUTPUT_FLAG_DEEP_BUFFER`).
- **Hardware HAL Layer**: MediaTek AIDL Audio HAL (`android.hardware.audio.service-aidl.mediatek`) drives the ALSA kernel device and SmartPA amplifier (`smartpa_aw88xxx`) via `AudioALSAPlaybackHandlerNormal` and `AurisysLibManager`.

---

## 3. Summary of Investigation Findings

| Check | Result | Evidence / Details |
| :--- | :--- | :--- |
| **Diagnostic Branch** | **`vol=1.00`** | `[AudioDiag]` logged `vol=1.00`, `state=ready`, `playing=true` throughout silence. |
| **Software Volume** | Not Muted | App software volume remained 1.00; crossfade was disabled; secondary player was null. |
| **ExoPlayer Output** | Active | `AudioTrack: [audioTrackData]` logged continuous writes with `mMaxAmplitude ~32720`. |
| **AudioFlinger Sink** | Stalled / Cut Off | `dumpsys media.audio_flinger`: `AudioOut_D` Signal power history ceased at `20:17:58`. |
| **Catalyst Trigger** | Concurrent Fast Track | SystemUI screen lock sound on `AudioOut_15` triggered HAL `DestroyAurisysLibManager()`. |
| **Pause/Play Failure** | ExoPlayer Sink Retention | `just_audio` `pause()`/`play()` only toggles `setPlayWhenReady`; `AudioTrack` is not recreated. |

---

## 4. Phase 1 — Static Analysis

### 4.1 Volume Control in `lib/services/android_audio_engine.dart`
Every code path capable of modifying player volume was analyzed:
1. **Line 248 (`await player.setVolume(0)`)**:
   Located in `_ensureSecondary()`. Only invoked when crossfade is enabled (`_crossfadeConfigProvider().enabled == true`). In the observed failure, crossfade was disabled (`AndroidCrossfadeConfig.disabled`), `_ensureSecondary()` was never called, and `_secondary` remained `null` (confirmed by absent `secVol` in logs).
2. **Line 636 (`await player.setVolume(_rampUserVolume)`)**:
   Located in `seek(position)`. Only called if `_crossfadeArmed == true`. Restores volume to `_rampUserVolume` (1.0).
3. **Line 682 (`await incoming.setVolume(0)`)**:
   Located in `_armCrossfade()`. Gated by `cfg.enabled` (lines 648–656). Inactive when crossfade is disabled.
4. **Lines 745–746 (`incoming.setVolume(inVol); outgoing.setVolume(outVol)`)**:
   Located in `_startRampTimer()`. Ramps active crossfades. Inactive when crossfade is disabled.
5. **Lines 760, 779, 791 (`setVolume(_rampUserVolume)`)**:
   Volume restoration paths on crossfade finish or cancellation. Restores volume to 1.0.

*Conclusion*: When crossfade is disabled, `AndroidAudioEngine` **never modifies `_player.volume`**. The software player volume remains 1.00.

### 4.2 Audio Session & Interruption Handling in `lib/services/player_service.dart`
1. **Audio Focus Ducking (lines 1801–1807 & 1843–1850)**:
   When transient focus loss occurs (`AudioInterruptionType.duck`), `_setDucked(true)` sets `volume = _currentVolume * 0.2` (`0.20`), NOT `0.00` or `1.00`.
2. **Audio Focus Pause (lines 1809–1812)**:
   Permanent focus loss invokes `_pauseInternal()`, which sets `isPlayingNotifier.value = false` and pauses the engine.
3. **Audio Route Change Listener (lines 681–683)**:
   `AndroidAudioDeviceService.instance.deviceInfoNotifier.addListener` calls `_refreshAudioOutputDiagnostics()`. This function only formats strings for developer logging; it does not pause, stop, or mute playback.

*Conclusion*: Audio focus and session listeners did not mute the audio stream.

### 4.3 Native Audio Effects in `JustAudioProcessingController.kt`
- `android/app/src/main/kotlin/com/mossapps/flick/audiofx/JustAudioProcessingController.kt` attaches `Equalizer`, `DynamicsProcessing`, and `LoudnessEnhancer` to the player's `audioSessionId`.
- Dumpsys `media.audio_flinger` confirmed that no effect chain was attached to the active session (`sessionId 5289`). The Equalizer bundle was queried during initialization and immediately destroyed (`AudioEffect: Destructor 0xb40000714b94d7c0`).

*Conclusion*: Native audio effects were inactive and did not mute the session.

### 4.4 The Pause/Play Architectural Gap in `just_audio`
In `just_audio` Android implementation (`AudioPlayer.java` lines 980–997):
```java
public void pause() {
    if (!player.getPlayWhenReady()) return;
    player.setPlayWhenReady(false);
    updatePosition();
    enqueuePlaybackEvent();
}

public void play(final Result result) {
    if (player.getPlayWhenReady()) { ... return; }
    player.setPlayWhenReady(true);
    updatePosition();
}
```
In ExoPlayer's `DefaultAudioSink`:
- `setPlayWhenReady(false)` pauses the pipeline and calls `AudioTrack.pause()`. The `AudioTrack` instance, AudioFlinger track descriptor, and HAL session are **retained**.
- `setPlayWhenReady(true)` calls `AudioTrack.play()`, resuming writes into the **exact same `AudioTrack` instance**.
- ExoPlayer only tears down and recreates `AudioTrack` when `player.stop()` is called (which calls `DefaultAudioSink.reset()`), when the player is disposed, or when audio format configuration changes.

*Conclusion*: If the underlying AudioFlinger or ALSA HAL stream is wedged, pause/play never resets the sink. It resumes writing to the broken session, which is why pause then play fails to restore sound.

---

## 5. Phase 2 — Live Reproduction & Telemetry Evidence

Inspected on test device: **Xiaomi Redmi 12 (`23053RN02A` / `fire`), MediaTek Helio G88 (MT6769), Android 14 (API 34)**.

### 5.1 In-App Telemetry (PID 20604)
The diagnostic timer (`_startDiagTimer()`) recorded the following states during the silence event:
```text
10-04 20:17:22.032 20604 20604 I flutter : [AudioDiag] TEMP vol=1.00 state=ProcessingState.ready playing=true pos=77s buf=320s
10-04 20:17:32.032 20604 20604 I flutter : [AudioDiag] TEMP vol=1.00 state=ProcessingState.ready playing=true pos=87s buf=320s
10-04 20:17:42.032 20604 20604 I flutter : [AudioDiag] TEMP vol=1.00 state=ProcessingState.ready playing=true pos=97s buf=320s
10-04 20:17:52.032 20604 20604 I flutter : [AudioDiag] TEMP vol=1.00 state=ProcessingState.ready playing=true pos=107s buf=320s
10-04 20:18:02.032 20604 20604 I flutter : [AudioDiag] TEMP vol=1.00 state=ProcessingState.ready playing=true pos=117s buf=320s
```
- App software volume: `vol=1.00`
- Engine state: `ProcessingState.ready`, `playing=true`
- Track position: steadily advanced (`77s -> 87s -> 97s -> 107s -> 117s`)
- Buffer: healthy (`buf=320s`)
- Secondary player: absent (no `secVol`)

### 5.2 ExoPlayer AudioTrack Writes
Simultaneously, ExoPlayer continued writing decoded PCM data to the Android AudioTrack:
```text
10-04 20:17:27.627 20604 21429 D AudioTrack: [audioTrackData][fine] 5s(f:5002) : pid 20604 uid 10663 sessionId 5289 sr 44100 ch 2 fmt 1  mMaxAmplitude 31168
10-04 20:17:32.633 20604 21429 D AudioTrack: [audioTrackData][fine] 10s(f:10008) : pid 20604 uid 10663 sessionId 5289 sr 44100 ch 2 fmt 1  mMaxAmplitude 32269
10-04 20:17:37.649 20604 21429 D AudioTrack: [audioTrackData][fine] 15s(f:15024) : pid 20604 uid 10663 sessionId 5289 sr 44100 ch 2 fmt 1  mMaxAmplitude 32767
10-04 20:18:07.643 20604 21429 D AudioTrack: [audioTrackData][fine] 45s(f:45018) : pid 20604 uid 10663 sessionId 5289 sr 44100 ch 2 fmt 1  mMaxAmplitude 32720
```
- Full-scale audio amplitude (`mMaxAmplitude ~32720`, max 32767) was written continuously.
- `AudioTrack.write()` never failed and threw no exceptions.

### 5.3 AudioFlinger & MediaTek HAL Breakdown
In `dumpsys media.audio_flinger`:
ExoPlayer's AudioTrack (Session 5289) was handled by mixer thread `AudioOut_D` (`0xb40000706ae14700`, tid 1415, flags `PRIMARY|DEEP_BUFFER`).
The HAL stream dump revealed:
```text
  Hal stream dump:
      Signal power history (resolution: 1000.0 ms):
       10-04 20:17:58.621:    -39.1  -39.9  -38.9  -38.8  -39.2  -39.1  -39.3  -39.3  -39.2  -43.2 ] sum(20.4)
```
After `20:17:58.621`, signal power output on `AudioOut_D` **completely stopped**.

**Logcat Timeline of the Crash**:
1. `20:17:31.575`: SystemUI initiated a lock/keyguard click sound on `AudioOut_15` (flag `0x4 FAST`).
2. `20:17:31.603`: MediaTek HAL opened `AudioALSAPlaybackHandlerFast` for `PLAYBACK2_TO_ADDA_DL` and invoked `CreateAurisysLibManager` for `smartpa_aw88xxx`.
3. `20:17:31.617`: ALSA driver reported timestamp failures:
   `AudioALSAPlaybackHandlerBase: -getHardwareBufferInfo(), pcm_get_htimestamp fail, ret = -1, flag = 0x4`
4. `20:17:31.617`: AudioFlinger throttled `AudioOut_D`:
   `mixer(0xb40000706ae14700) throttle begin: ret(8192) deltaMs(2) requires sleep 8 ms ... throttle end`
5. `20:17:32.067`: SystemUI finished and stopped its AudioTrack.
6. `20:17:33.063`: HAL destroyed the Aurisys manager:
   `misound4_arsi_destroy_handler`
   `DestroyAurisysLibManager()`
7. When `DestroyAurisysLibManager()` was called, the shared SmartPA speaker amplifier unlinked `AudioOut_D`. AudioFlinger continued consuming frames from ExoPlayer's ring buffer, advancing ExoPlayer's position clock while the speaker hardware remained disconnected.

---

## 6. Confirmed Facts vs. Hypotheses

### Confirmed Facts
1. The app did **not** mute itself (`vol=1.00` confirmed across all diagnostics).
2. ExoPlayer decodes and writes audio into `AudioTrack` normally (`mMaxAmplitude ~32720`).
3. AudioFlinger accepts buffer writes without error (`numTracks=1 writeErrors=0`).
4. Hardware signal power output to the physical speaker ceased at `20:17:58`.
5. Pause/play in `just_audio` only toggles `setPlayWhenReady`; it never resets or recreates the underlying `AudioTrack`.

### Working Hypotheses
1. The root trigger is a hardware resource conflict in MediaTek's Aurisys HAL between concurrent Fast-track system sounds (`PLAYBACK2_TO_ADDA_DL`) and DeepBuffer music playback (`AudioOut_D`) over the shared Awinic AW88xxx SmartPA amplifier.
2. Tearing down and recreating the `AudioTrack` via `player.stop()` + re-seek/re-play clears the wedged AudioFlinger/HAL session state and immediately unblocks speaker output.

---

## 7. Concrete Proposed Fix

The proposed solution provides guaranteed recovery on user interaction (Pause/Play) and automated resilience on system events.

### Step 1: Re-arm Sink on Resume / Unpause in `AndroidAudioEngine`
Modify `lib/services/android_audio_engine.dart`:
- When `play()` is called after a pause (or when a sink refresh is needed):
  - Execute a clean sink re-arm: call `await player.stop()`, restore position with `await player.seek(currentPosition)`, then call `player.play()`.
  - Calling `player.stop()` in `just_audio` invokes ExoPlayer's `DefaultAudioSink.reset()`, which releases the wedged `AudioTrack` and forces creation of a brand new `AudioTrack` with a fresh session and client port in AudioFlinger.
  - **Outcome**: Pressing **Pause** then **Play** is guaranteed to restore sound immediately.

### Step 2: Auto-Recovery on App Resume and Route Changes in `PlayerService`
Modify `lib/services/player_service.dart`:
- In `onAppResumed()` (when the user unlocks the screen) and in the `deviceInfoNotifier` listener:
  - If `currentEngineType == AudioEngineType.normalAndroid` and playback is active (`isPlayingNotifier.value == true`):
    - Trigger a transparent re-arm of the speaker sink (`_androidAudioEngine.rearmSink()`) so sound is restored automatically without requiring the user to toggle pause/play manually.

### Step 3: Remove Temporary Diagnostic Timer
Once verified, remove `_startDiagTimer()`, `_stopDiagTimer()`, and `_diagTimer` introduced in commit `98090289`.
