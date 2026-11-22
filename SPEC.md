# SPEC — Zennox Music Player (local + Google Drive)

ASSUMPTION lines are guesses awaiting confirmation. Source brief: project prompt v1 (sections 1–9).

## Problem
People who own their music (FLAC rips, purchased downloads, files in Google Drive) have no
single, privacy-respecting player that plays both local files and their own Drive files, in
lossless quality, with the same library on phone and desktop. Today's workaround: download
from Drive by hand, copy into a per-device player, rebuild playlists on every device.

## Users & platforms
| User | Devices / OS | Context |
|---|---|---|
| Owner of a personal music collection | Android phone, iPhone | Commute, offline or flaky network, background/lock-screen playback, headphones/Bluetooth |
| Same user at a desk | Windows, macOS | Large local library, keyboard + mouse, wired DAC |

ASSUMPTION: Linux, web and tablets-specific layouts are non-goals for v1 (Linux builds may come free with the chosen stack).
ASSUMPTION: Single user per install; one Google account connected at a time in v1 (schema allows several).

## Core flows (day one)
1. Sign in with Google (no app account) and grant `drive.file` access via Google Picker.
2. Pick Drive audio files/folders; index metadata; play with buffering and seeking.
3. Add local files/folders by reference (no copying); play offline.
4. Favorite a track; add tracks to playlists — references only, never duplicate audio.
5. Browse All Songs / Albums / Artists / Folders / Recently Played / Recently Added; search.
6. Background playback with lock-screen / OS media controls.
7. Mark Drive tracks for offline; see and reclaim storage.
8. Disconnect Drive / sign out / revoke; local library keeps working.

## Data
Entities: Source, Track, Favorite, Playlist, PlaylistTrack, PlaybackHistory, OfflineDownload,
DuplicateGroup. All stored locally (SQLite). Sensitive: OAuth refresh token (OS secure
storage only: Keychain / Android Keystore / Windows Credential Manager (DPAPI)); Drive file
IDs and listening history (PII-adjacent, never leaves device). No app server, no account DB.
Retention: until user removes source or uninstalls; sign-out wipes tokens and Drive cache.

## Non-goals
- Any shared/central music catalogue, scraping, or redistribution.
- Uploading user audio anywhere; app-controlled server storage.
- Cross-device sync of favorites/playlists in v1 (possible later via a file in the user's own Drive appDataFolder).
- DRM-protected files (e.g. Apple Music/Spotify downloads), transcoding/format conversion, audio editing.
- Streaming-service integrations, social features, lyrics, recommendations.

## Success metric
A tester on each of the 4 platforms completes the 8 core flows without help, and a
10,000-track local library indexes in < 60 s with UI scroll at 60 fps on a mid-range
phone. (Defaults — tune in PLAN.md perf budgets.)

## Constraints
Budget: solo developer; no Apple Developer Program; no paid CASA assessment → `drive.file` only.
ASSUMPTION: no paid Apple Developer Program; macOS ships self-signed via GitHub Releases (ADR-0003); iOS is build-from-source until decided.
Deadline: none fixed; one milestone per brief phase.
Team skills: Swift (decided). Backend: none.
Distribution: zero cost, no store accounts. GitHub Releases for macOS (install script), Android (APK), Windows (installer); iOS from source.

## Risks
| Risk | Likelihood | Impact | Mitigation / test |
|---|---|---|---|
| `drive.file` grants access only to the picked item; picking a folder may not grant its children (reported by Google staff in 2019; current behaviour unverified) | High | High — breaks "pick my music folder" | Slice 0 spike on real accounts; fallback = multi-select files in Picker, or `drive.readonly` (restricted scope → Google verification + annual CASA assessment) |
| Picker on iOS: Google documents desktop (browser redirect) and Android flows; iOS path unverified | Medium | High | Spike: desktop-style redirect via ASWebAuthenticationSession |
| Swift has no SwiftUI on Android/Windows; Swift SDK for Android first official in Swift 6.3 (Mar 2026), Windows UI bindings less mature | High | High | Shared Swift core + native UI shell per OS (ADR-0001); Android/Windows shells after Apple ship |
| Codec gaps (Ogg Vorbis/Opus/ALAC on some OSes) with native engines | High | Medium | Bundle an FFmpeg-based decoder or engine; codec matrix test per OS |
| Decoder licensing | Low | Medium | Use native OS decoders + BSD-licensed libogg/libvorbis/libopus only; no FFmpeg/libmpv (ADR-0004) |
| Drive byte-range streaming / quota throttling | Medium | Medium | Range-request seek test; backoff on 403/429; progressive download fallback |
| Background audio killed by OS (iOS/Android battery policy) | Medium | High | Native media session / foreground service; real-device tests |
| Google OAuth app verification delays release | Medium | Medium | Start verification at Phase 5; `drive.file` is non-sensitive-path friendly |
