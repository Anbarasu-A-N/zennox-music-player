# ADR-0005: SQLite with a thin Swift wrapper in ZennoxCore

Date: 2026-11-22 · Status: proposed

## Decision
SQLite (system lib on Apple, bundled amalgamation on Android/Windows — public domain) behind a
~300-line wrapper in ZennoxCore with prepared statements only. Schema versioned via
`PRAGMA user_version`; forward migrations in code, each tested from every prior version;
backup copy taken before migrating. Uniqueness enforced by constraints, not app logic:
`UNIQUE(source_id, external_id)` on Track, `PRIMARY KEY(track_id)` on Favorite,
`ON DELETE CASCADE` only from library rows — never touches files.

## Alternatives considered
- GRDB — excellent, but Android/Windows support unverified; adopt if S2 shows it builds on all four.
- SwiftData/Core Data — Apple-only.
