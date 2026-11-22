# GRAPH_REPORT

23 files · 0 internal import edges · languages: swift=20, py=3

Read god nodes first; open neighbours with `project_graph.py <repo> --neighbors <file>`.

## God nodes (most imported)
- (none)

## Hubs (import the most)
- (none)

## Clusters
| cluster | files | intra edges | outgoing inter edges |
|---|---|---|---|
| Sources | 15 | 0 | 0 |
| Tests | 4 | 0 | 0 |
| tools | 3 | 0 | 0 |
| (root) | 1 | 0 | 0 |

## Layer violations (0)
- none

## Import cycles (0)
- none

## Orphans — not imported, not an obvious entry point (21)
- `Package.swift`
- `Sources/ZennoxCore/Database/SQLiteDatabase.swift`
- `Sources/ZennoxCore/Database/Schema.swift`
- `Sources/ZennoxCore/Library/LibraryStore.swift`
- `Sources/ZennoxCore/Library/Models.swift`
- `Sources/ZennoxCore/Local/FileAccess.swift`
- `Sources/ZennoxCore/Local/LocalLibraryScanner.swift`
- `Sources/ZennoxCore/Local/SecurityScopedBookmark.swift`
- `Sources/ZennoxCore/Metadata/AudioMetadata.swift`
- `Sources/ZennoxCore/Metadata/ByteReader.swift`
- `Sources/ZennoxCore/Metadata/FLACParser.swift`
- `Sources/ZennoxCore/Metadata/ID3Parser.swift`
- `Sources/ZennoxCore/Metadata/MP4Parser.swift`
- `Sources/ZennoxCore/Metadata/MetadataReader.swift`
- `Sources/ZennoxCore/Metadata/OggParser.swift`
- `Sources/ZennoxCore/Metadata/RIFFParsers.swift`
- `Tests/ZennoxCoreTests/LibraryStoreTests.swift`
- `Tests/ZennoxCoreTests/LocalLibraryScannerTests.swift`
- `Tests/ZennoxCoreTests/MP4OggMetadataTests.swift`
- `Tests/ZennoxCoreTests/MetadataReaderTests.swift`
- `tools/spike_drive_picker.py`

## Top external dependencies (by import count)
`Foundation` 15, `XCTest` 4, `ZennoxCore` 4, `urllib` 4, `sys` 3, `pathlib` 2, `unittest` 2, `base64` 2, `hashlib` 2, `os` 2, `json` 2, `PackageDescription` 1, `SQLite3` 1, `CSQLite` 1, `spike_drive_picker` 1, `tempfile` 1, `argparse` 1, `glob` 1, `http` 1, `secrets` 1, `time` 1, `webbrowser` 1, `re` 1, `sqlite3` 1
