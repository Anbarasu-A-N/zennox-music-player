# ADR-0002: drive.file + Google Picker only

Date: 2026-11-22 · Status: proposed (pending spike S1)

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
