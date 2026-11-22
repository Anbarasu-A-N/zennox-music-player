import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GoogleOAuthConfig: Sendable, Equatable {
    public let clientID: String
    /// Desktop clients have a (non-confidential) secret; iOS/Android clients have none.
    public let clientSecret: String?
    public let redirectURI: String

    public init(clientID: String, clientSecret: String? = nil, redirectURI: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
    }
}

public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Base64URL.encode(SHA256.hash(Array(verifier.utf8)))
    }

    /// 64 random bytes → 86-character verifier (RFC 7636 allows 43–128).
    public static func generate() -> PKCE {
        var rng = SystemRandomNumberGenerator()  // cryptographically secure on Apple, Linux, Windows, Android
        let bytes = (0..<64).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        return PKCE(verifier: Base64URL.encode(bytes))
    }
}

public struct PickerResult: Sendable, Equatable {
    public let code: String
    public let pickedFileIDs: [String]
}

public struct TokenResponse: Sendable, Equatable {
    public let accessToken: String
    public let expiresIn: Int
    public let refreshToken: String?
    public let scope: String?
}

public enum OAuthError: Error, Equatable {
    case stateMismatch
    case accessDenied(String)
    case missingCode
    /// Refresh token expired or revoked (or 7-day Testing-mode expiry): the user must sign in again.
    case invalidGrant
    case server(status: Int, error: String?)
    case malformedResponse
    case notSignedIn
}

/// Google OAuth 2.0 for installed apps with PKCE, using the Drive Picker's `trigger_onepick` flow.
/// Google allows only the drive.file scope in this flow, and it cannot be combined with other scopes.
public enum GoogleOAuth {
    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    public static let driveFileScope = "https://www.googleapis.com/auth/drive.file"

    /// Audio MIME types offered in the Picker. Folder selection stays off: a picked folder grants
    /// no access to its contents under drive.file (spike S1, ADR-0002).
    public static let pickerAudioMimeTypes = [
        "audio/flac", "audio/x-flac", "audio/mpeg", "audio/mp3", "audio/mp4", "audio/x-m4a", "audio/aac",
        "audio/ogg", "audio/opus", "audio/wav", "audio/x-wav", "audio/aiff", "audio/x-aiff",
    ]

    public static func pickerAuthorizationURL(_ config: GoogleOAuthConfig, state: String, pkce: PKCE,
                                              mimeTypes: [String] = pickerAudioMimeTypes) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: driveFileScope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "trigger_onepick", value: "true"),
            URLQueryItem(name: "allow_multiple", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if !mimeTypes.isEmpty { items.append(URLQueryItem(name: "mimetypes", value: mimeTypes.joined(separator: ","))) }
        components.queryItems = items
        return components.url!
    }

    public static func randomState() -> String {
        var rng = SystemRandomNumberGenerator()
        return Base64URL.encode((0..<24).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
    }

    public static func parseRedirect(_ url: URL, expectedState: String) throws -> PickerResult {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw OAuthError.accessDenied(error) }
        guard value("state") == expectedState else { throw OAuthError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw OAuthError.missingCode }
        let picked = (value("picked_file_ids") ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        return PickerResult(code: code, pickedFileIDs: picked)
    }

    public static func tokenExchangeRequest(_ config: GoogleOAuthConfig, code: String, verifier: String) -> URLRequest {
        var fields: [(String, String)] = [
            ("code", code), ("client_id", config.clientID), ("redirect_uri", config.redirectURI),
            ("grant_type", "authorization_code"), ("code_verifier", verifier),
        ]
        if let secret = config.clientSecret { fields.append(("client_secret", secret)) }
        return formRequest(tokenEndpoint, fields)
    }

    public static func refreshRequest(_ config: GoogleOAuthConfig, refreshToken: String) -> URLRequest {
        var fields: [(String, String)] = [
            ("client_id", config.clientID), ("refresh_token", refreshToken), ("grant_type", "refresh_token"),
        ]
        if let secret = config.clientSecret { fields.append(("client_secret", secret)) }
        return formRequest(tokenEndpoint, fields)
    }

    public static func revokeRequest(token: String) -> URLRequest {
        formRequest(revokeEndpoint, [("token", token)])
    }

    public static func parseTokenResponse(_ data: Data, status: Int) throws -> TokenResponse {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let error = json?["error"] as? String
            if error == "invalid_grant" { throw OAuthError.invalidGrant }
            throw OAuthError.server(status: status, error: error)
        }
        guard let json, let access = json["access_token"] as? String, !access.isEmpty else {
            throw OAuthError.malformedResponse
        }
        let expires = (json["expires_in"] as? NSNumber)?.intValue ?? (json["expires_in"] as? Int) ?? 3600
        return TokenResponse(accessToken: access, expiresIn: expires,
                             refreshToken: json["refresh_token"] as? String, scope: json["scope"] as? String)
    }

    static func formRequest(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&").utf8)
        return request
    }

    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
