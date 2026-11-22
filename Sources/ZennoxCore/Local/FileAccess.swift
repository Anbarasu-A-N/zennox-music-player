import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

public struct FileEntry: Equatable, Sendable {
    public let path: String
    /// Stable file identity that survives rename/move on the same volume ("device:inode"), when available.
    public let identity: String?
    public let size: Int64
    /// Modification time, milliseconds since 1970.
    public let modified: Int64

    public init(path: String, identity: String?, size: Int64, modified: Int64) {
        self.path = path; self.identity = identity; self.size = size; self.modified = modified
    }
}

/// Read-only file access. The library has no API that writes or deletes user files.
public protocol FileAccess {
    /// Regular files under `root` (or `root` itself if it is a file), recursively, skipping hidden files.
    func listFiles(under root: String) throws -> [FileEntry]
    /// Up to `maxBytes` starting at `offset`.
    func read(_ path: String, offset: Int64, maxBytes: Int) throws -> [UInt8]
}

public enum FileAccessError: Error, Equatable {
    case notFound(String)
}

/// FileManager-based access for macOS, iOS (inside a granted scope), Linux and Windows.
public struct LocalFileSystem: FileAccess {
    public init() {}

    /// One canonical spelling per file (symlinks resolved, e.g. macOS /var → /private/var), so paths
    /// stored in the library always compare equal to what the next scan reports. Uses realpath(3):
    /// Foundation's resolvingSymlinksInPath strips "/private" on macOS and would reintroduce the mismatch.
    public static func canonical(_ path: String) -> String {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Android)
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
        #else
        return path
        #endif
    }

    public func listFiles(under requestedRoot: String) throws -> [FileEntry] {
        let fm = FileManager.default
        let root = Self.canonical(requestedRoot)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDirectory) else { throw FileAccessError.notFound(root) }
        if !isDirectory.boolValue { return [try entry(root)] }

        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walker = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw FileAccessError.notFound(root)
        }
        var entries: [FileEntry] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: Set(keys)))?.isRegularFile == true,
                  let e = try? entry(url.path) else { continue }
            entries.append(e)
        }
        return entries
    }

    private func entry(_ path: String) throws -> FileEntry {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = Self.int64(attrs[.size]) ?? 0
        let modified = (attrs[.modificationDate] as? Date).map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? 0
        var identity: String?
        if let inode = Self.int64(attrs[.systemFileNumber]), inode != 0 {
            identity = "\(Self.int64(attrs[.systemNumber]) ?? 0):\(inode)"
        }
        return FileEntry(path: path, identity: identity, size: size, modified: modified)
    }

    /// FileManager attribute numbers arrive as NSNumber on Apple and as native integers on Linux.
    static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let n as NSNumber: return n.int64Value
        case let v as Int: return Int64(v)
        case let v as Int64: return v
        case let v as UInt64: return Int64(truncatingIfNeeded: v)
        case let v as UInt32: return Int64(v)
        case let v as Int32: return Int64(v)
        default: return nil
        }
    }

    public func read(_ path: String, offset: Int64, maxBytes: Int) throws -> [UInt8] {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw FileAccessError.notFound(path) }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, offset)))
        return [UInt8](try handle.read(upToCount: maxBytes) ?? Data())
    }
}
