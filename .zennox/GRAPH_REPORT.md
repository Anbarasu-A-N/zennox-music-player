# GRAPH_REPORT

45 files · 0 internal import edges · languages: swift=42, py=3

Read god nodes first; open neighbours with `project_graph.py <repo> --neighbors <file>`.

## God nodes (most imported)
- (none)

## Hubs (import the most)
- (none)

## Clusters
| cluster | files | intra edges | outgoing inter edges |
|---|---|---|---|
| Sources | 31 | 0 | 0 |
| Tests | 9 | 0 | 0 |
| tools | 3 | 0 | 0 |
| (root) | 1 | 0 | 0 |
| apps/apple | 1 | 0 | 0 |

## Layer violations (0)
- none

## Import cycles (0)
- none

## Orphans — not imported, not an obvious entry point (43)
- `Package.swift`
- `Sources/ZennoxCore/Auth/GoogleOAuth.swift`
- `Sources/ZennoxCore/Auth/KeychainStore.swift`
- `Sources/ZennoxCore/Auth/TokenManager.swift`
- `Sources/ZennoxCore/Database/SQLiteDatabase.swift`
- `Sources/ZennoxCore/Database/Schema.swift`
- `Sources/ZennoxCore/Drive/DriveLibraryImporter.swift`
- `Sources/ZennoxCore/Drive/GoogleDriveClient.swift`
- `Sources/ZennoxCore/Library/DuplicateDetector.swift`
- `Sources/ZennoxCore/Library/LibraryQueries.swift`
- `Sources/ZennoxCore/Library/LibraryStore.swift`
- `Sources/ZennoxCore/Library/Models.swift`
- `Sources/ZennoxCore/Library/QualityFormatter.swift`
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
- `Sources/ZennoxCore/Support/LogRedactor.swift`
- `Sources/ZennoxCore/Support/MD5.swift`
- `Sources/ZennoxCore/Support/SHA256.swift`
- `Sources/ZennoxUI/AppModel.swift`
- `Sources/ZennoxUI/Theme.swift`
- `Sources/ZennoxUI/Views/LibraryViews.swift`
- … 13 more in graph.json

## Top external dependencies (by import count)
`Foundation` 27, `ZennoxCore` 13, `XCTest` 9, `FoundationNetworking` 5, `SwiftUI` 5, `urllib` 4, `sys` 3, `pathlib` 2, `unittest` 2, `base64` 2, `hashlib` 2, `os` 2, `json` 2, `PackageDescription` 1, `SQLite3` 1, `CSQLite` 1, `Security` 1, `Darwin` 1, `Glibc` 1, `Android` 1, `Observation` 1, `UIKit` 1, `AppKit` 1, `UniformTypeIdentifiers` 1, `spike_drive_picker` 1
