# FiiO BR13 bit-perfect report — investigation

Date: 2026-10-01
Device: FiiO BR13 (UAC1.0, VID `0x0a12` / PID `0x4007`) on Samsung Galaxy S24 Ultra (SM-S928B, One UI)
App: 0.22.0-beta.3 era build

## Report

The user set Playback Engine to **Isochronous USB** and **Bit-perfect (USB DAC)** ON, but the USB Audio screen showed:

- Device connected, FIIO BR13 (UAC1.0)
- Playback Path: **Android (resampled)**
- Capability State: **Android (resampled)**
- Backend: **Rust engine via Oboe/AAudio with adaptive resampler fallback**
- Track Sample Rate: 44 kHz

The reporter's own diagnosis (from a dev build) claimed the exclusive engine opened, went `Error → Idle`, closed the `UsbDeviceConnection` without ever negotiating an alt setting (`alt=-1 endpoint=-1`), left `usbClaimed=true`, and fell back to `android-shared:resampled-fallback`.

## What the logs showed

The captured log (13:34 → 13:49, truncated with 134 KB left) contains the decisive lines at the moment the BR13 went live:

```
13:49:11.454 Uac2Service.listDevices (Android): 1 candidate(s): FIIO BR13 (UAC1.0)@/dev/bus/usb/001/004
13:49:11.454 _discoverDefaultAndroidUsbDevice falling back to first UsbManager DAC candidate: FIIO BR13 (UAC1.0)
13:49:11.924 [Session] Resolve inputs: route=USB-Audio - FIIO BR13 (UAC1.0) ... enginePref=AudioEnginePreference.isochronousUsb bitPerfect=false caps=[usbDac]
13:49:11.924 [Session] Selected RUST_OBOE because parametric EQ is enabled and needs the variable-band DSP chain
13:49:11.928 [Diagnostics] bit-perfect preference changed: mode=RUST_OBOE ... bitPerfect=false
```

At the resolve that mattered, `enginePref=isochronousUsb` was already set, but `bitPerfect=false` and an **active parametric EQ** was present. The bit-perfect toggle fired right after (`.928`). No `[Engine] Initializing`, `[USB]`, or direct-USB activation lines appear in the visible portion, so the direct path was never attempted before the log was cut.

## Root cause

`lib/services/audio_session_manager.dart` `_resolvePreferredMode` checked parametric EQ **first** inside the USB branch and returned `rustOboe` before looking at the bit-perfect preference or the `isochronousUsb` engine preference:

```dart
if (EqEngineHint.parametricPeqActive) {
  return AudioEngineType.rustOboe;   // ran even with bit-perfect ON
}
```

Consequences:

- The direct USB engine (`usbDacExperimental`) was never selected while parametric EQ was active, so bit-perfect could never engage. The toggle stayed ON in the UI but was silently ineffective — `isBitPerfectModeEnabled` is false unless `currentEngineType == usbDacExperimental`.
- The shared Rust Oboe path at S24's 48 kHz mixer produces the exact screenshot labels (`resampled_fallback` + USB route → "Android (resampled)").
- The reporter's `usbClaimed=true` / `Error → Idle` is consistent with the activation side effect of enabling bit-perfect (`setBitPerfectEnabled` → `selectDevice` → Kotlin `activateDirectUsb` claims and registers the device with an idle lock) while the session still ran `rustOboe`. It does not require a direct-stream failure.
- The Retry flow (`retryExperimentalUsbForCurrentDevice`) re-resolves through the same `_resolvePreferredMode`, so PEQ blocked it the same way — matching the "still resampled while retrying" screenshot.
- This contradicts the documented policy (external USB DAC + `isochronousUsb` + bit-perfect ON → `usbDacExperimental`).

## Fix (implemented)

1. `lib/services/audio_session_manager.dart` — parametric EQ only forces `rustOboe` when bit-perfect (USB DAC) is OFF. With bit-perfect ON the direct USB path is selected and the DSP chain (including PEQ) is bypassed there, which is what bit-perfect already promises.
2. `lib/services/player_service.dart` `_handleBitPerfectPreferenceChanged` — re-resolves the route (`syncAudioRouteSelection`) after a bit-perfect preference change, so toggling bit-perfect actually switches the engine instead of waiting for the next route event.
3. `lib/features/settings/screens/uac2_preferences_screen.dart` — when bit-perfect is enabled while parametric EQ is active, the restart notice also says the PEQ is bypassed on the direct USB path.

Verified: `flutter analyze` clean on the touched files; targeted player-service and EQ tests pass.

## Support guidance for the reporter

1. Turn off parametric EQ (or disable the non-all-pass bands / switch EQ mode) in Equalizer settings.
2. Keep Playback Engine = Isochronous USB and Bit-perfect (USB DAC) = ON, then restart the app.
3. On the USB Audio screen the DAC Claim should now read "Claimed by Flick" and Capability State "Verified USB direct" rather than "Android (resampled)".
4. If it still falls back, capture logs: enable Developer Mode, reproduce, then Settings → Logs → filter Rust + Dart, search `USB`, `clock`, `Engine`, `Diagnostics`, and Share the file. Also collect app version, One UI version, BR13 firmware, and whether the failure differs between 44.1 kHz and 48 kHz tracks.

## Follow-ups / open items

- The log tail after `13:49:19.867` was not captured; it should confirm whether the direct path was attempted and what exactly refused it (the reporter's theory names the UAC1 SET_CUR path).
- If PEQ was not the only blocker, the next suspect is the deliberate UAC1 clock refusal for unverified NoSync endpoints (`rust/src/uac2/android_direct.rs` hard-abort; `uac1_set_cur_failure_tolerable` excludes NoSync). The BR13 has no quirk entry today. A BR13 `SkipClockValidation` quirk would be the targeted remedy, but only with the missing log evidence.
- Mirror case: enabling PEQ while bit-perfect is ON now forces the direct path and silently bypasses the EQ. Consider an Equalizer-screen notice, or a prompt offering to drop PEQ when bit-perfect is enabled.
