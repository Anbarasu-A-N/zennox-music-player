import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DriveFile: Equatable, Sendable {
    public let id: String
    public let name: String
    public let mimeType: String
    public let size: Int64?
    public let md5: String?
    public let modifiedTime: String?
    public let trashed: Bool
}

public struct DriveUser: Equatable, Sendable {
    public let permissionID: String
    public let email: String?
    public let displayName: String?
}

public enum DriveError: Error, Equatable {
    case invalidFileID
    case notFound
    case forbidden(reason: String?)
    case unauthorized
    case rateLimited
    case server(status: Int)
    case malformedResponse
}

/// Minimal Drive v3 client: only the documented calls Zennox needs (about.get, files.get,
/// files.get?alt=media with Range). Retries 401 once after a token refresh and backs off with
/// jitter on quota (403 rate-limit reasons, 429) and 5xx errors.
public struct GoogleDriveClient: Sendable {
    public static let base = "https://www.googleapis.com/drive/v3"
    static let fileFields = "id,name,mimeType,size,md5Checksum,modifiedTime,trashed"

    private let tokens: GoogleTokenManager
    private let transport: HTTPTransport
    private let maxAttempts: Int
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let jitter: @Sendable () -> Double

    public init(tokens: GoogleTokenManager, transport: HTTPTransport = URLSessionTransport(), maxAttempts: Int = 5,
                sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.tokens = tokens
        self.transport = transport
        self.maxAttempts = max(1, maxAttempts)
        self.sleep = sleep
        self.jitter = jitter
    }

    /// Drive IDs are URL-safe base64-like strings. Anything else (e.g. from a tampered redirect) is rejected.
    public static func isValidFileID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 200 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
        }
    }

    public func about() async throws -> DriveUser {
        let (data, _) = try await perform(url: "\(Self.base)/about?fields=user(permissionId,displayName,emailAddress)")
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let user = json["user"] as? [String: Any], let id = user["permissionId"] as? String, !id.isEmpty
        else { throw DriveError.malformedResponse }
        return DriveUser(permissionID: id, email: user["emailAddress"] as? String, displayName: user["displayName"] as? String)
    }

    public func file(_ id: String) async throws -> DriveFile {
        guard Self.isValidFileID(id) else { throw DriveError.invalidFileID }
        let (data, _) = try await perform(url: "\(Self.base)/files/\(id)?fields=\(Self.fileFields)&supportsAllDrives=true")
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let fid = json["id"] as? String, let name = json["name"] as? String,
              let mime = json["mimeType"] as? String else { throw DriveError.malformedResponse }
        let size = (json["size"] as? String).flatMap { Int64($0) }  // Drive returns size as a string
        return DriveFile(id: fid, name: name, mimeType: mime, size: size, md5: json["md5Checksum"] as? String,
                         modifiedTime: json["modifiedTime"] as? String, trashed: json["trashed"] as? Bool ?? false)
    }

    /// Reads `length` bytes from `offset`. Never assumes Range support: if Drive answers 200 with
    /// the whole body, the requested slice is cut out of it.
    public func read(_ id: String, offset: Int64, length: Int) async throws -> [UInt8] {
        guard Self.isValidFileID(id) else { throw DriveError.invalidFileID }
        guard length > 0, offset >= 0 else { return [] }
        let range = "bytes=\(offset)-\(offset + Int64(length) - 1)"
        let (data, response) = try await perform(url: "\(Self.base)/files/\(id)?alt=media&supportsAllDrives=true",
                                                 headers: ["Range": range], allowRangeNotSatisfiable: true)
        if response.statusCode == 416 { return [] }
        let bytes = [UInt8](data)
        if response.statusCode == 206 { return Array(bytes.prefix(length)) }
        let start = Int(min(offset, Int64(bytes.count)))
        return Array(bytes[start..<min(start + length, bytes.count)])
    }

    // MARK: Request loop

    private func perform(url: String, headers: [String: String] = [:],
                         allowRangeNotSatisfiable: Bool = false) async throws -> (Data, HTTPURLResponse) {
        guard let requestURL = URL(string: url), requestURL.scheme == "https" else { throw DriveError.malformedResponse }
        var refreshedAfter401 = false
        var attempt = 0
        while true {
            attempt += 1
            let token = try await tokens.validAccessToken()
            var request = URLRequest(url: requestURL)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

            let result: (Data, HTTPURLResponse)
            do {
                result = try await transport.send(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < maxAttempts else { throw error }  // transient network failure
                try await backoff(attempt)
                continue
            }

            let (data, response) = result
            let status = response.statusCode
            switch status {
            case 200..<300:
                return (data, response)
            case 416 where allowRangeNotSatisfiable:
                return (data, response)
            case 401:
                guard !refreshedAfter401 else { throw DriveError.unauthorized }
                refreshedAfter401 = true
                await tokens.invalidateAccessToken()
                attempt -= 1  // a token refresh is not a quota retry
            case 404:
                throw DriveError.notFound
            case 403 where Self.isRateLimit(Self.errorReason(data)), 429, 500, 502, 503, 504:
                guard attempt < maxAttempts else {
                    throw status == 429 || status == 403 ? DriveError.rateLimited : DriveError.server(status: status)
                }
                try await backoff(attempt)
            case 403:
                throw DriveError.forbidden(reason: Self.errorReason(data))
            default:
                throw DriveError.server(status: status)
            }
        }
    }

    /// Exponential backoff with jitter: 1 s, 2 s, 4 s … capped at 32 s, plus up to 1 s random.
    private func backoff(_ attempt: Int) async throws {
        let base = min(32.0, pow(2.0, Double(attempt - 1)))
        try await sleep(UInt64((base + jitter()) * 1_000_000_000))
    }

    static func isRateLimit(_ reason: String?) -> Bool {
        ["rateLimitExceeded", "userRateLimitExceeded", "RATE_LIMIT_EXCEEDED"].contains(reason ?? "")
    }

    static func errorReason(_ data: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        if let errors = error["errors"] as? [[String: Any]], let reason = errors.first?["reason"] as? String { return reason }
        if let details = error["details"] as? [[String: Any]],
           let reason = details.compactMap({ $0["reason"] as? String }).first { return reason }
        return error["status"] as? String
    }
}
