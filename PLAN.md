# PLAN — Zennox Music Player

Stack: ADR-0001. Order = riskiest assumption first. Each slice < ~200 changed lines where possible;
big slices are split during build. "Check" is the gate.

## Repository layout
```
zennox-music-player/
├── Package.swift                 # ZennoxCore (+ COgg/CVorbis/COpus/CSQLite C targets)
├── Sources/ZennoxCore/           # Library, Drive, Metadata, Playback logic, Cache, Duplicates
├── Sources/ZennoxCore/Adapters/  # protocols: SecureStore, FileAccess, AudioOutput, Clock, HTTP
├── Tests/ZennoxCoreTests/
├── apps/apple/                   # Xcode multiplatform SwiftUI app (iOS + macOS)
├── apps/android/                 # Gradle: Compose UI, Media3, swift-java bridge
├── apps/windows/                 # chosen by S9
├── docs/adr/  docs/threat-model.md  docs/google-cloud-setup.md
├── .github/workflows/ci.yml  release.yml
└── SPEC.md PLAN.md DESIGN.md
```

## Phase 1–2: spikes (prove or kill assumptions)
S1 — Drive Picker scope. Goal: pick a folder and files via Picker with drive.file; list folder children.
  Check: documented result on 2 real accounts (folder children accessible: yes/no). Decides ADR-0002 UI.
S2 — Core builds everywhere. Goal: ZennoxCore + CSQLite compile and `swift test` on macOS, Linux; cross-compile for Android and Windows in CI.
  Check: CI matrix green on 4 triples.
S3 — Codec matrix. Goal: decode 8 formats × (44.1/16, 96/24, 192/24) fixtures on each OS.
  Check: `CodecMatrixTests` table committed per OS; unsupported cells listed in Known Limitations.
S4 — Drive range streaming. Goal: seek in a 300 MB FLAC on Drive via Range into ring cache.
  Check: seek to 80% starts audio < 2 s on 20 Mbps (default budget).

## Phase 3: library (ZennoxCore, tested on Linux CI)
L1 — Schema v1 + migrations (Source, Track, Favorite, Playlist, PlaylistTrack, PlaybackHistory, OfflineDownload, DuplicateCandidate). Check: `MigrationTests`, uniqueness constraint tests (favorite twice → one row).
L2 — Metadata readers: ID3v2/v1, Vorbis comments (FLAC/Ogg/Opus), MP4 atoms (AAC/ALAC), WAV/AIFF headers; true codec/sample rate/bit depth/channels; `isLossless` from codec, never from extension. Check: fixture + fuzz tests.
L3 — Local source: security-scoped bookmarks (Apple), SAF persistable URIs (Android); incremental scan; stale-reference detection. Check: rename/move/delete fixtures.
L4 — Drive source: OAuth PKCE, token refresh/revoke, Picker results → Track rows, metadata via ranged header reads, change re-validation, backoff. Check: fake-Drive integration tests + S1 manual script.
L5 — Favorites, playlists, recents, search (SQLite FTS5), sort. Check: playlist delete keeps tracks; removing library entry never calls file APIs.
L6 — Duplicate candidates: (size + duration ±1 s + normalized tags), optional SHA-256 on demand; group, never delete. Check: unit tests incl. same filename / different audio.

## Phase 4: Apple app (SwiftUI, iOS + macOS)
A1 — DESIGN.md + tokens; Library/Albums/Artists/Folders/Search screens. Check: UI tests + accessibility audit (VoiceOver labels, Dynamic Type).
A2 — Playback: AVAudioEngine graph, queue, gapless, shuffle/repeat, speed. Check: gapless test album; seek tests.
A3 — Background + MPNowPlayingInfoCenter/MPRemoteCommandCenter, route changes (headphones out → pause), interruptions. Check: device test procedure.
A4 — Now Playing, mini-player, queue editing, themes, empty/error states. Check: UI tests light/dark.
A3b — Update keeps Google sign-in (stable self-signed identity, Keychain access survives). Check: install v0.1, update to v0.2, no re-login.
A5 — Offline downloads with size display + removal; resumable via Range. Check: kill-app-mid-download test.

## Phase 4b: Android shell — D1 swift-java bridge, D2 Compose screens, D3 Media3 + MediaSessionService, D4 SAF + Credential/Authorization + Picker. Checks: instrumented tests on real device.
## Phase 4c: Windows shell — S9 spike (swift-winrt vs C#/WinUI 3), then W1–W4 mirroring Android. SMTC media controls, Credential Manager.

## Phase 5: security & testing — threat-model tests, security_scan, token-log redaction, 50k-track library perf test (index < 5 min, memory < 150 MB — defaults), OAuth verification prep.
## Phase 6: release — GitHub Actions matrix; macOS universal ad-hoc build zipped with ditto + SHA256SUMS + scripts/install-macos.sh; APK signing; Sparkle EdDSA appcast; privacy policy page (required for Google OAuth consent screen), docs/google-cloud-setup.md, build docs ×4, Known Limitations.
