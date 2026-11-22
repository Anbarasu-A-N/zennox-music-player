# Threat model — Zennox Music Player

Flow: App (UI shell → ZennoxCore) ⇄ Google OAuth (system browser) ⇄ Drive API (HTTPS).
Local: SQLite DB, secure token store, artwork/offline cache, user-picked local files.
Trust boundaries: (1) OAuth redirect into app, (2) Drive API responses, (3) audio/metadata bytes
from any file, (4) local file references, (5) update feed from GitHub Releases.

| # | Risk (STRIDE) | L×I | Mitigation | Test |
|---|---|---|---|---|
| 1 | Malicious audio/tag data crashes or exploits parsers (Tampering/EoP) | M×H | Bounds-checked tag parsers in Swift, size caps on artwork (≤10 MB) and tag frames; decoders run with hard limits; fuzz corpus | fuzz tests on ID3/FLAC/MP4 parsers |
| 2 | Auth code interception on redirect (Spoofing) | L×H | PKCE S256, `state` check, ASWebAuthenticationSession / Custom Tabs / loopback 127.0.0.1 with random port | unit: reject bad state/verifier |
| 3 | Token leak via logs, backups, crash reports (Info disclosure) | M×H | Keychain `AfterFirstUnlockThisDeviceOnly`, Android Keystore, Windows Credential Manager; log redaction filter; no telemetry | test: logger redacts `ya29.`/`1//` patterns |
| 4 | Tampered update binary (Tampering) | L×H | Sparkle EdDSA signatures (macOS), APK signature pin, Authenticode; HTTPS only | release checklist |
| 5 | Quota exhaustion / throttling (DoS) | M×M | Exponential backoff with jitter on 403 rateLimit/429/5xx; batched metadata; cache | integration test with fake Drive |
| 6 | Accidental deletion of user files (Integrity) | L×H | Core has no file-delete API except for our own offline cache dir; path containment check | test: delete only under cache root |
