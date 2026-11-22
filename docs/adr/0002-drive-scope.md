# ADR-0002: drive.file + Google Picker only

Date: 2026-11-22 · Status: accepted (S1 run 1, 2026-11-22)

## Context
No budget for CASA. `drive.readonly`/`drive` are restricted scopes (verification + annual assessment).
Google's desktop/mobile Picker requires `drive.file` alone and returns `picked_file_ids`; folder
selection is allowed, but whether picking a folder grants its children is unverified (2019 staff
answer: no).

## Decision
Request only `openid email drive.file`. Library grows from Picker selections. If S1 shows folder
picks don't grant children, the UI says "Select the songs to add" with multi-select + audio MIME
filter, and "Add more" re-opens the Picker.

## Alternatives considered
- drive.readonly full scan — blocked by budget.
- Asking users to upload into an app-created folder (drive.file grants app-created files) — rejected: forces users to move their files.

## Consequences
No automatic discovery of new Drive files; refresh only re-validates known IDs. Documented as a
known limitation.

## Evidence (S1 run 1, 2026-11-22)
Owner picked one folder ("Songs", contains music) via the desktop Picker with
`allow_folder_selection=true`. Granted scope: drive.file only. `files.list` with
`'<folderId>' in parents` returned 0 children. Conclusion: picking a folder does not grant
access to its contents under drive.file. Library therefore grows from picked files only.

## UI consequence
- Button copy: "Choose songs from Google Drive" (not "Choose folder").
- Picker opened with allow_multiple=true, audio MIME filter, folder selection OFF (a picked
  folder is useless and would confuse users).
- Help text: "Open a folder in the picker and Shift-click or ⌘/Ctrl-click to select many songs."
- "Add more songs" re-opens the Picker; already-added files are kept (drive.file grants persist).

## Evidence (S1 run 2 / S4 partial, 2026-11-22)
Picked one audio/mpeg file (10.4 MB). `files.get?alt=media` with `Range: bytes=0-15` → 206,
`Content-Range: bytes 0-15/10434621`, ID3 magic. Mid-file range (64 KB at 50%) → 206.
Conclusion: picked files are readable; HTTP Range works for header reads and seeking.
Not yet measured: seek latency budget (< 2 s at 20 Mbps) — measured in the app in A2.

## Evidence (S1 run 3, 2026-11-22): account identity
`GET /drive/v3/about?fields=user(permissionId,displayName,emailAddress)` with drive.file only
→ 200, permissionId and emailAddress present. Decision: Drive source `account_id` = permissionId
(stable per Google account); email shown in Settings so users can tell accounts apart.
No openid/email scopes needed (the Picker flow forbids combining them anyway).
