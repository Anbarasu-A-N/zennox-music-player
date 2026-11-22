// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ZennoxCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ZennoxCore", targets: ["ZennoxCore"]),
        .library(name: "ZennoxUI", targets: ["ZennoxUI"]),
    ],
    targets: [
        // Apple platforms use the SDK's SQLite3 module; Linux uses the system library.
        // Android/Windows: bundled SQLite amalgamation (debt: added in S2b).
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .target(
            name: "ZennoxCore",
            dependencies: [.target(name: "CSQLite", condition: .when(platforms: [.linux, .android, .windows]))]
        ),
        // SwiftUI app layer for iOS and macOS. Its sources are wrapped in #if canImport(SwiftUI),
        // so it builds empty on Linux/Android/Windows.
        .target(name: "ZennoxUI", dependencies: ["ZennoxCore"]),
        .testTarget(name: "ZennoxCoreTests", dependencies: ["ZennoxCore"]),
    ]
)
