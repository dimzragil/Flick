# Flick 0.22.0-beta.1

A big one: Apple Music metadata and motion art, native DSD fixes, an EQ preamp, bounded caches, and a sharper scanning experience.

## Apple Music Metadata

- **Apple Music metadata enrichment** for untagged files: releases are matched by track name and duration, candidates are reviewed in an identify-album sheet, and confident exact matches are applied automatically after a scan
- New **Fix Missing Metadata** screen with a shortcut in Library settings, plus an Apple Music tile under Integrations
- Album and artist detail screens gain **Identify album**, offline-cached Apple Music artwork fallback, biography, similar artists, top songs, and "About this album" notes

## DSD Native Playback

- **DSD-NATIVE output** via SAS offload shim (HiBy devices) with ALSA direct fallback; WavPack DSD detection and decoding fixed
- Fixed DSF files decoding 8 bytes late — the cause of continuous light ticks; bit order now follows the DSF header flag
- ReplayGain is ignored on native DSD/DoP sources (a gain multiply would corrupt the DSD bits)
- Reduced residual crackle: opt-in debug dumps, larger ring buffer, raised render/decoder thread priority, 256 KiB decoder reads
- DSD wire format and grouping settings in UAC2 preferences; decoder crash dumps captured offline

## Equalizer

- **Standalone preamp** broadband gain stage applied before the band curve, independent of configured bands
- RBJ biquad response modeling so the graph matches the real Rust audio path
- Gain range widened to ±20 dB and Q to 0.2–20; preset imports warn on clamped values
- Animated swipe navigation between tabs; knobs double-tap to reset

## ReplayGain & Crossfeed

- **ReplayGain** Track/Album modes with pre-amp and clipping prevention
- Scanner analyzes loudness (EBU R128 / BS.1770), writes `REPLAYGAIN_*` tags, and updates the library
- **BS2B crossfeed** with Default/strong/gentle presets; persists across engine recreation; bypassed on bit-perfect

## Karaoke Lyrics

- Word-level **karaoke sync** with gradient sweep and a toggle in lyrics settings
- Full-screen **Lyrics Sync Studio**: tap-along word stamping, enhanced LRC export, video-style word timeline, syllable splitting
- Lyrics from **MP4/M4A and OGG/Opus** containers; text alignment options and readability scrim

## Global Search

- Unified search across songs, albums, artists, and playlists, with persisted filter chips

## Library Scanning & Artwork

- Optional **Full Library Access** — Rust scanner walks every volume directly; falls back to MediaStore/SAF
- **DSD/DSF/WavPack always scanned**, even on devices whose media indexer skips them (Xiaomi/MIUI, Vivo, Honor)
- **WavPack/DSD tags & album art everywhere** via Rust parser fallback; fixed DFF/WavPack embedded covers
- **Fixed library wipe when switching scan engines** — each engine only deletes rows it can see; deleted songs no longer reappear
- Scans finish with artwork ready — a skippable **Loading artwork** phase (`n / N covers`), and library screens reload as covers land
- **Quick or Full rescan** chooser; **per-folder progress**; **honest scan progress** counts every checked file
- Draggable **scan bubble** for scan/preload/ReplayGain progress that snaps to an edge; **Stop** halts the scan and its preload immediately

## Storage & Caches

- **Bounded playback caches** — WAV conversions and SAF staging copies capped (default 1 GB, configurable in Library → Storage) with LRU eviction
- **Streamed conversion** — ALAC/M4A/AIFF tracks decoded on demand instead of converting the whole queue to WAV (fixes cache growth, issue #212)
- WAV streaming memory is now bounded so large high-bitrate queues can't OOM the app

## Motion Art & Bit-Perfect

- Motion art runs only in the immersive full-bleed player, with route-aware lifecycle and memory tracking
- Motion art is **suspended during bit-perfect output**; an opt-in **Motion Art in Bit-Perfect** toggle is available in Playback & Display
- Static cover shows while animated artwork resolves; a refresh action was added to the song actions sheet
- Loss of the native direct output is detected and the Rust engine respawns and resumes the track

## Reliability & Diagnostics

- Rust engine **crash recovery** — revives on dead channels; Oboe callback panics are contained; the pitch shifter no longer resizes buffers on the render thread
- Lying container headers detected and corrected; implausible sample rates filtered; gapless queueing disabled across incompatible engine configs
- Offline/reconnection notices; update checks reuse the shared connectivity state
- App logs persist to disk with periodic flush; process-exit diagnostics are reported on launch; logs share as timestamped files

## Navigation & UI Refresh

- Nested navigators per tab; full player and queue routed via root navigator; bottom nav restored via a route observer
- New **FlickDialog** system and **FlickArtworkPlaceholder** across the app
- Shared detail headers with glass blur back buttons; landscape mode support
- System **reduced-motion** preference respected globally; full-text glass sheet for fetched descriptions

## USB & Bluetooth

- USB DAC **bit-perfect auto-engage** with a master toggle and per-device decline memory (resettable)
- Suppressed direct USB routes retry after transient failures; a payload audit grace latch stops verification flapping
- UAC1 refuses direct USB when SET_CUR fails; better sampling-frequency negotiation; Hi-Res Direct for the Bluetooth Rust Oboe path

## Network & Metadata

- Fixed WebDAV href double-decoding on non-ASCII and special-character filenames; HTTP auth headers now reach ExoPlayer ranged requests
- Jellyfin **silent re-auth** via secure password store; Tidal sign-in fix with persisted session token
- WavPack playback uses the true PCM sample rate; an ID3 tag is created when writing metadata to untagged WAV files
- Editable descriptions on detail pages plus a song actions button

## Player & Library

- Rebuilt full player with song stage carousel; swipe-down previous-track gesture
- Metadata editor moved to a bottom sheet with instant sync
- Playlist sorting; bulk favorites; duplicate cleaner with per-group multi-keep; folder tree view toggle
- Case-insensitive sorting for album, artist, song, and folder lists

## Casting

- Cast from the **system media route picker**; DLNA routes surfaced in the app
- DLNA (RenderingControl) and Chromecast volume control from the app and **media notification**

## Getting Started

1. Apple Music metadata: Settings → Integrations → Apple Music, then Settings → Library → Fix Missing Metadata
2. ReplayGain: Settings → Library → Scan Settings → ReplayGain scan
3. Crossfeed: Settings → Audio → Headphone Crossfeed
4. Karaoke: Lyrics settings → Word Sync toggle, then edit in the Sync Studio
5. Full Library Access: Settings → Library → Scan Settings
