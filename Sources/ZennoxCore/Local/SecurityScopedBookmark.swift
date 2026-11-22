#if os(macOS) || os(iOS)
import Foundation

/// Persistent, user-granted access to a folder or file picked with the system file picker.
/// The app keeps only the bookmark (as base64 in library_root.access_token), never broad
/// filesystem permission.
public enum SecurityScopedBookmark {
    public static func make(for url: URL) throws -> String {
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil).base64EncodedString()
    }

    /// Resolves a bookmark, runs `body` with access granted, and returns a refreshed token if the
    /// bookmark went stale (e.g. the folder was moved), which the caller should store.
    public static func withAccess<T>(_ token: String, _ body: (URL) throws -> T) throws -> (result: T, refreshedToken: String?) {
        guard let data = Data(base64Encoded: token) else { throw FileAccessError.notFound("invalid bookmark") }
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        let result = try body(url)
        var refreshed: String?
        if stale { refreshed = try? make(for: url) }
        return (result, refreshed)
    }
}
#endif
