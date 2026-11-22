import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Platform secure storage: Keychain (Apple), Keystore-backed (Android), Credential Manager (Windows).
public protocol SecureStore: Sendable {
    func read(_ key: String) throws -> String?
    func write(_ key: String, _ value: String) throws
    func delete(_ key: String) throws
}

/// For tests and previews only. Never used for real tokens.
public final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()
    public init() {}
    public func read(_ key: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func write(_ key: String, _ value: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = value }
    public func delete(_ key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.scheme == "https" else { throw OAuthError.malformedResponse }  // HTTPS only
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
            session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let http = response as? HTTPURLResponse {
                    continuation.resume(returning: (data ?? Data(), http))
                } else {
                    continuation.resume(throwing: OAuthError.malformedResponse)
                }
            }.resume()
        }
    }
}

/// Owns one Google account's tokens. The refresh token lives only in `SecureStore`; the access
/// token only in memory. Nothing here logs token values.
public actor GoogleTokenManager {
    private let config: GoogleOAuthConfig
    private let store: SecureStore
    private let transport: HTTPTransport
    private let storeKey: String
    private let now: @Sendable () -> Date
    private var accessToken: String?
    private var expiresAt = Date.distantPast
    private var refreshTask: Task<String, Error>?

    public init(config: GoogleOAuthConfig, store: SecureStore, transport: HTTPTransport,
                accountKey: String = "default", now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        self.store = store
        self.transport = transport
        self.storeKey = "google.refresh." + accountKey
        self.now = now
    }

    private func storedRefreshToken() -> String? {
        guard let value = try? store.read(storeKey) else { return nil }
        return value
    }

    public var hasStoredGrant: Bool { storedRefreshToken() != nil }

    /// Exchanges the Picker's authorization code. Each Picker run returns a fresh grant; the newest is kept.
    public func completeSignIn(code: String, verifier: String) async throws {
        let (data, response) = try await transport.send(GoogleOAuth.tokenExchangeRequest(config, code: code, verifier: verifier))
        let token = try GoogleOAuth.parseTokenResponse(data, status: response.statusCode)
        if let refresh = token.refreshToken { try store.write(storeKey, refresh) }
        accept(token)
    }

    /// A valid access token, refreshing if it expires within 60 s. Concurrent callers share one refresh.
    public func validAccessToken() async throws -> String {
        if let accessToken, expiresAt.timeIntervalSince(now()) > 60 { return accessToken }
        if let refreshTask { return try await refreshTask.value }
        guard let refresh = try store.read(storeKey) else { throw OAuthError.notSignedIn }
        let task = Task { () throws -> String in
            let (data, response) = try await self.transport.send(GoogleOAuth.refreshRequest(self.config, refreshToken: refresh))
            let token = try GoogleOAuth.parseTokenResponse(data, status: response.statusCode)
            return try self.acceptRefreshed(token)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            return try await task.value
        } catch OAuthError.invalidGrant {
            try? store.delete(storeKey)  // dead grant: force a clean sign-in
            accessToken = nil
            throw OAuthError.invalidGrant
        }
    }

    /// Call after a 401 so the next request refreshes.
    public func invalidateAccessToken() {
        accessToken = nil
        expiresAt = .distantPast
    }

    /// Revokes the grant at Google (best effort) and deletes local tokens. Library data is untouched.
    public func signOut(revoke: Bool = true) async {
        let token = storedRefreshToken() ?? accessToken
        if revoke, let token { _ = try? await transport.send(GoogleOAuth.revokeRequest(token: token)) }
        try? store.delete(storeKey)
        invalidateAccessToken()
    }

    private func acceptRefreshed(_ token: TokenResponse) throws -> String {
        if let rotated = token.refreshToken { try store.write(storeKey, rotated) }
        accept(token)
        return token.accessToken
    }

    private func accept(_ token: TokenResponse) {
        accessToken = token.accessToken
        expiresAt = now().addingTimeInterval(TimeInterval(token.expiresIn))
    }
}
