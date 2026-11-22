import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ZennoxCore

final class SHA256Tests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(SHA256.hex([]), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex(Array("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(SHA256.hex([UInt8](repeating: 0x61, count: 1_000)),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    func testIncrementalUpdatesMatchOneShot() {
        let data: [UInt8] = (0..<1_000).map { UInt8(truncatingIfNeeded: $0 * 7) }
        var hasher = SHA256()
        for chunk in stride(from: 0, to: data.count, by: 37) { hasher.update(Array(data[chunk..<min(chunk + 37, data.count)])) }
        XCTAssertEqual(hasher.finalize(), SHA256.hash(data))
    }

    func testPKCEMatchesRFC7636Example() {
        XCTAssertEqual(PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk").challenge,
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let generated = PKCE.generate()
        XCTAssertTrue((43...128).contains(generated.verifier.count))
        XCTAssertNotEqual(generated, PKCE.generate())
    }
}

final class GoogleOAuthTests: XCTestCase {
    let config = GoogleOAuthConfig(clientID: "cid.apps.googleusercontent.com", clientSecret: "s3cret", redirectURI: "http://127.0.0.1:5000/callback")

    private func query(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { out[item.name] = item.value }
        return out
    }

    func testPickerURLHasRequiredParamsOnlyDriveFileAndNoFolderSelection() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let q = query(GoogleOAuth.pickerAuthorizationURL(config, state: "st", pkce: pkce))
        XCTAssertEqual(q["scope"], GoogleOAuth.driveFileScope)
        XCTAssertEqual(q["prompt"], "consent")
        XCTAssertEqual(q["trigger_onepick"], "true")
        XCTAssertEqual(q["allow_multiple"], "true")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["code_challenge"], pkce.challenge)
        XCTAssertEqual(q["state"], "st")
        XCTAssertNil(q["allow_folder_selection"])
        XCTAssertNil(q["client_secret"])  // never in the browser URL
        XCTAssertTrue(q["mimetypes"]?.contains("audio/flac") ?? false)
    }

    func testRedirectParsing() throws {
        let ok = URL(string: "http://127.0.0.1:5000/callback?state=st&code=4%2F0Ab&picked_file_ids=a,b&scope=x")!
        XCTAssertEqual(try GoogleOAuth.parseRedirect(ok, expectedState: "st"), PickerResult(code: "4/0Ab", pickedFileIDs: ["a", "b"]))
        let ios = URL(string: "com.googleusercontent.apps.123:/oauth2redirect?state=st&code=c")!
        XCTAssertEqual(try GoogleOAuth.parseRedirect(ios, expectedState: "st").pickedFileIDs, [])

        XCTAssertThrowsError(try GoogleOAuth.parseRedirect(URL(string: "http://h/?state=evil&code=c")!, expectedState: "st")) {
            XCTAssertEqual($0 as? OAuthError, .stateMismatch)
        }
        XCTAssertThrowsError(try GoogleOAuth.parseRedirect(URL(string: "http://h/?error=access_denied&state=st")!, expectedState: "st")) {
            XCTAssertEqual($0 as? OAuthError, .accessDenied("access_denied"))
        }
    }

    func testTokenExchangeBodyIsFormEncoded() throws {
        let request = GoogleOAuth.tokenExchangeRequest(config, code: "4/0A b+c", verifier: "v")
        let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8) ?? ""
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(body.contains("code=4%2F0A%20b%2Bc"))
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code_verifier=v"))
        XCTAssertTrue(body.contains("client_secret=s3cret"))
    }

    func testTokenResponseParsing() throws {
        let ok = Data(#"{"access_token":"ya29.x","expires_in":3599,"refresh_token":"1//r","scope":"s","token_type":"Bearer"}"#.utf8)
        XCTAssertEqual(try GoogleOAuth.parseTokenResponse(ok, status: 200),
                       TokenResponse(accessToken: "ya29.x", expiresIn: 3599, refreshToken: "1//r", scope: "s"))
        let dead = Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8)
        XCTAssertThrowsError(try GoogleOAuth.parseTokenResponse(dead, status: 400)) { XCTAssertEqual($0 as? OAuthError, .invalidGrant) }
        XCTAssertThrowsError(try GoogleOAuth.parseTokenResponse(Data("<html>".utf8), status: 200)) {
            XCTAssertEqual($0 as? OAuthError, .malformedResponse)
        }
    }

    func testRedactorRemovesSecrets() {
        let line = #"POST code=4/0Ab&x=1 Authorization: Bearer ya29.a0AfB_x {"refresh_token": "1//0gAbc"} access ya29.zz"#
        let clean = LogRedactor.redact(line)
        for secret in ["4/0Ab", "ya29.", "1//0gAbc"] { XCTAssertFalse(clean.contains(secret), clean) }
        XCTAssertTrue(clean.contains("x=1"))
    }
}

/// Scripted HTTP for token-manager tests.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (URLRequest) -> (Int, String)
    private(set) var requests: [URLRequest] = []
    var delayNanoseconds: UInt64 = 0

    init(_ handler: @escaping (URLRequest) -> (Int, String)) { self.handler = handler }

    func setHandler(_ h: @escaping (URLRequest) -> (Int, String)) { lock.lock(); handler = h; lock.unlock() }

    func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return requests.filter { $0.url?.path == path }.count }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        lock.lock()
        requests.append(request)
        let (status, body) = handler(request)
        lock.unlock()
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
}

final class TokenManagerTests: XCTestCase {
    let config = GoogleOAuthConfig(clientID: "cid", redirectURI: "http://127.0.0.1/cb")

    private func tokenJSON(_ access: String, refresh: String? = nil) -> String {
        let r = refresh.map { #","refresh_token":"\#($0)""# } ?? ""
        return #"{"access_token":"\#(access)","expires_in":3600\#(r)}"#
    }

    private func makeManager(_ transport: FakeTransport, _ store: InMemorySecureStore, _ clock: TestClock) -> GoogleTokenManager {
        GoogleTokenManager(config: config, store: store, transport: transport, now: { clock.now })
    }

    func testSignInStoresRefreshTokenAndCachesAccessToken() async throws {
        let store = InMemorySecureStore(), clock = TestClock()
        let transport = FakeTransport { _ in (200, self.tokenJSON("ya29.first", refresh: "1//grant")) }
        let manager = makeManager(transport, store, clock)
        try await manager.completeSignIn(code: "c", verifier: "v")
        XCTAssertEqual(try store.read("google.refresh.default"), "1//grant")
        let token = try await manager.validAccessToken()
        XCTAssertEqual(token, "ya29.first")
        XCTAssertEqual(transport.requests.count, 1)  // cached, no refresh
    }

    func testRefreshesNearExpiryAndKeepsRotatedRefreshToken() async throws {
        let store = InMemorySecureStore(), clock = TestClock()
        let transport = FakeTransport { _ in (200, self.tokenJSON("ya29.first", refresh: "1//grant")) }
        let manager = makeManager(transport, store, clock)
        try await manager.completeSignIn(code: "c", verifier: "v")
        clock.advance(3_560)  // 40 s left → inside the 60 s safety window
        transport.setHandler { _ in (200, self.tokenJSON("ya29.second", refresh: "1//rotated")) }
        let token = try await manager.validAccessToken()
        XCTAssertEqual(token, "ya29.second")
        XCTAssertEqual(try store.read("google.refresh.default"), "1//rotated")
    }

    func testConcurrentCallersShareOneRefresh() async throws {
        let store = InMemorySecureStore(), clock = TestClock()
        try store.write("google.refresh.default", "1//grant")
        let transport = FakeTransport { _ in (200, self.tokenJSON("ya29.shared")) }
        transport.delayNanoseconds = 50_000_000
        let manager = makeManager(transport, store, clock)
        async let a = manager.validAccessToken()
        async let b = manager.validAccessToken()
        async let c = manager.validAccessToken()
        let tokens = try await [a, b, c]
        XCTAssertEqual(Set(tokens), ["ya29.shared"])
        XCTAssertEqual(transport.count("/token"), 1)
    }

    func testInvalidGrantClearsStoredTokenAndRequiresSignIn() async throws {
        let store = InMemorySecureStore(), clock = TestClock()
        try store.write("google.refresh.default", "1//dead")
        let transport = FakeTransport { _ in (400, #"{"error":"invalid_grant"}"#) }
        let manager = makeManager(transport, store, clock)
        do {
            _ = try await manager.validAccessToken()
            XCTFail("expected invalidGrant")
        } catch {
            XCTAssertEqual(error as? OAuthError, .invalidGrant)
        }
        XCTAssertNil(try store.read("google.refresh.default"))
        let signedIn = await manager.hasStoredGrant
        XCTAssertFalse(signedIn)
    }

    func testNotSignedIn() async {
        let manager = makeManager(FakeTransport { _ in (500, "") }, InMemorySecureStore(), TestClock())
        do { _ = try await manager.validAccessToken(); XCTFail() } catch { XCTAssertEqual(error as? OAuthError, .notSignedIn) }
    }

    func testSignOutRevokesAndDeletes() async throws {
        let store = InMemorySecureStore(), clock = TestClock()
        try store.write("google.refresh.default", "1//grant")
        let transport = FakeTransport { _ in (200, "{}") }
        let manager = makeManager(transport, store, clock)
        await manager.signOut()
        XCTAssertEqual(transport.count("/revoke"), 1)
        let body = String(data: transport.requests.first?.httpBody ?? Data(), encoding: .utf8)
        XCTAssertEqual(body, "token=1%2F%2Fgrant")
        XCTAssertNil(try store.read("google.refresh.default"))
    }

    func testInvalidateForcesRefreshAfter401() async throws {
        let store = InMemorySecureStore(), clock = TestClock()
        let transport = FakeTransport { _ in (200, self.tokenJSON("ya29.first", refresh: "1//grant")) }
        let manager = makeManager(transport, store, clock)
        try await manager.completeSignIn(code: "c", verifier: "v")
        await manager.invalidateAccessToken()
        transport.setHandler { _ in (200, self.tokenJSON("ya29.after401")) }
        let token = try await manager.validAccessToken()
        XCTAssertEqual(token, "ya29.after401")
        XCTAssertEqual(try store.read("google.refresh.default"), "1//grant")  // kept when not rotated
    }
}
