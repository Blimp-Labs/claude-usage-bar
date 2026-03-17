import XCTest
@testable import ClaudeUsageBar

@MainActor
final class UsageServiceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testBackoffIntervalCapsAtSixtyMinutes() {
        XCTAssertEqual(
            UsageService.backoffInterval(retryAfter: 120, currentInterval: 30 * 60),
            60 * 60
        )
    }

    func testBackoffIntervalNeverReducesSixtyMinutePolling() {
        XCTAssertEqual(
            UsageService.backoffInterval(retryAfter: 120, currentInterval: 60 * 60),
            60 * 60
        )
    }

    func testFetchUsageRefreshesOn401AndRetriesOnce() async throws {
        let store = try makeStore()
        try store.save(
            StoredCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-old",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: UsageService.defaultOAuthScopes
            )
        )

        let usageURL = URL(string: "https://example.com/api/oauth/usage")!
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!
        let session = makeSession()
        var requests: [String] = []

        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            requests.append("\(request.httpMethod ?? "GET") \(request.url?.path ?? "") \(authorization)")

            switch (request.httpMethod, request.url?.path, authorization) {
            case ("GET", "/api/oauth/usage", "Bearer old-access"):
                return try Self.httpResponse(url: usageURL, statusCode: 401)
            case ("POST", "/v1/oauth/token", _):
                let body = try XCTUnwrap(Self.jsonBody(for: request))
                XCTAssertEqual(body["grant_type"], "refresh_token")
                XCTAssertEqual(body["refresh_token"], "refresh-old")
                XCTAssertEqual(body["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
                XCTAssertEqual(body["scope"], "user:profile user:inference")

                return try Self.httpResponse(
                    url: tokenURL,
                    statusCode: 200,
                    body: """
                    {
                      "access_token": "new-access",
                      "refresh_token": "refresh-new",
                      "expires_in": 3600,
                      "scope": "user:profile user:inference"
                    }
                    """
                )
            case ("GET", "/api/oauth/usage", "Bearer new-access"):
                return try Self.httpResponse(
                    url: usageURL,
                    statusCode: 200,
                    body: """
                    {
                      "five_hour": { "utilization": 12, "resets_at": "2026-03-08T18:00:00Z" },
                      "seven_day": { "utilization": 20, "resets_at": "2026-03-15T18:00:00Z" }
                    }
                    """
                )
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }

        let service = UsageService(
            session: session,
            usageEndpoint: usageURL,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: tokenURL,
            credentialsStore: store
        )

        await service.fetchUsage()

        XCTAssertTrue(service.isAuthenticated)
        XCTAssertNil(service.lastError)
        XCTAssertEqual(service.usage?.fiveHour?.utilization, 12)
        XCTAssertEqual(requests.count, 3)

        let saved = try XCTUnwrap(store.load(defaultScopes: UsageService.defaultOAuthScopes))
        XCTAssertEqual(saved.accessToken, "new-access")
        XCTAssertEqual(saved.refreshToken, "refresh-new")
        XCTAssertNotNil(saved.expiresAt)
    }

    func testFetchUsageDoesNotSignOutWhenRetriedRequestIsRateLimited() async throws {
        let store = try makeStore()
        try store.save(
            StoredCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-old",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: UsageService.defaultOAuthScopes
            )
        )

        let usageURL = URL(string: "https://example.com/api/oauth/usage")!
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!

        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""

            switch (request.httpMethod, request.url?.path, authorization) {
            case ("GET", "/api/oauth/usage", "Bearer old-access"):
                return try Self.httpResponse(url: usageURL, statusCode: 401)
            case ("POST", "/v1/oauth/token", _):
                return try Self.httpResponse(
                    url: tokenURL,
                    statusCode: 200,
                    body: """
                    {
                      "access_token": "new-access",
                      "expires_in": 3600,
                      "scope": "user:profile user:inference"
                    }
                    """
                )
            case ("GET", "/api/oauth/usage", "Bearer new-access"):
                return try Self.httpResponse(
                    url: usageURL,
                    statusCode: 429,
                    headers: ["Retry-After": "120"]
                )
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: usageURL,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: tokenURL,
            credentialsStore: store
        )

        await service.fetchUsage()

        XCTAssertTrue(service.isAuthenticated)
        XCTAssertEqual(service.lastError, "Rate limited — backing off to 3600s")

        let saved = try XCTUnwrap(store.load(defaultScopes: UsageService.defaultOAuthScopes))
        XCTAssertEqual(saved.accessToken, "new-access")
        XCTAssertEqual(saved.refreshToken, "refresh-old")
    }

    func testFetchUsageSignsOutWhenRefreshFails() async throws {
        let store = try makeStore()
        try store.save(
            StoredCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-old",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: UsageService.defaultOAuthScopes
            )
        )

        let usageURL = URL(string: "https://example.com/api/oauth/usage")!
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!

        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""

            switch (request.httpMethod, request.url?.path, authorization) {
            case ("GET", "/api/oauth/usage", "Bearer old-access"):
                return try Self.httpResponse(url: usageURL, statusCode: 401)
            case ("POST", "/v1/oauth/token", _):
                return try Self.httpResponse(
                    url: tokenURL,
                    statusCode: 400,
                    body: #"{"error":"invalid_grant"}"#
                )
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: usageURL,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: tokenURL,
            credentialsStore: store
        )

        await service.fetchUsage()

        XCTAssertFalse(service.isAuthenticated)
        XCTAssertEqual(service.lastError, "Session expired — please sign in again")
        XCTAssertNil(store.load(defaultScopes: UsageService.defaultOAuthScopes))
    }

    func testFetchProfileDoesNotSignOutWhenUserinfoStillReturns401AfterRefresh() async throws {
        let store = try makeStore()
        try store.save(
            StoredCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-old",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: UsageService.defaultOAuthScopes
            )
        )

        let userinfoURL = URL(string: "https://example.com/api/oauth/userinfo")!
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!

        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""

            switch (request.httpMethod, request.url?.path, authorization) {
            case ("GET", "/api/oauth/userinfo", "Bearer old-access"):
                return try Self.httpResponse(url: userinfoURL, statusCode: 401)
            case ("POST", "/v1/oauth/token", _):
                return try Self.httpResponse(
                    url: tokenURL,
                    statusCode: 200,
                    body: """
                    {
                      "access_token": "new-access",
                      "refresh_token": "refresh-new",
                      "expires_in": 3600,
                      "scope": "user:profile user:inference"
                    }
                    """
                )
            case ("GET", "/api/oauth/userinfo", "Bearer new-access"):
                return try Self.httpResponse(url: userinfoURL, statusCode: 401)
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: URL(string: "https://example.com/api/oauth/usage")!,
            userinfoEndpoint: userinfoURL,
            tokenEndpoint: tokenURL,
            credentialsStore: store,
            localProfileLoader: { nil }
        )

        await service.fetchProfile()

        XCTAssertTrue(service.isAuthenticated)
        XCTAssertNil(service.accountEmail)
        XCTAssertNil(service.lastError)

        let saved = try XCTUnwrap(store.load(defaultScopes: UsageService.defaultOAuthScopes))
        XCTAssertEqual(saved.accessToken, "new-access")
        XCTAssertEqual(saved.refreshToken, "refresh-new")
    }

    func testSubmitOAuthCodeRejectsMissingState() async throws {
        let store = try makeStore()
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!
        var openedURL: URL?

        MockURLProtocol.handler = { request in
            XCTFail("No network request should be made when state is missing")
            return try Self.httpResponse(url: request.url!, statusCode: 500)
        }

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: URL(string: "https://example.com/api/oauth/usage")!,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: tokenURL,
            credentialsStore: store,
            urlOpener: { url in
                openedURL = url
                return true
            }
        )

        // Start an OAuth flow so oauthState is set
        service.startOAuthFlow()
        XCTAssertTrue(service.isAwaitingCode)
        XCTAssertTrue(openedURL?.absoluteString.hasPrefix("https://claude.ai/oauth/authorize") == true)

        // Submit code WITHOUT #state — should be rejected
        await service.submitOAuthCode("some-auth-code")

        XCTAssertFalse(service.isAwaitingCode)
        XCTAssertFalse(service.isAuthenticated)
        XCTAssertEqual(service.lastError, "Missing OAuth state — expected code#state format")
    }

    func testStartOAuthFlowFailsCleanlyWhenBrowserCannotOpen() throws {
        let store = try makeStore()
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!
        var openedURL: URL?

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: URL(string: "https://example.com/api/oauth/usage")!,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: tokenURL,
            credentialsStore: store,
            urlOpener: { url in
                openedURL = url
                return false
            }
        )

        service.startOAuthFlow()

        XCTAssertTrue(openedURL?.absoluteString.hasPrefix("https://claude.ai/oauth/authorize") == true)
        XCTAssertFalse(service.isAwaitingCode)
        XCTAssertEqual(service.lastError, "Could not open Claude sign-in page")
    }

    private func makeStore() throws -> StoredCredentialsStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return StoredCredentialsStore(directoryURL: directory, useKeychain: false)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func jsonBody(for request: URLRequest) -> [String: String]? {
        guard let body = bodyData(for: request),
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: String] else {
            return nil
        }
        return object
    }

    private static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(buffer, maxLength: bufferSize)
            guard bytesRead > 0 else { break }
            data.append(buffer, count: bytesRead)
        }

        return data.isEmpty ? nil : data
    }

    private static func httpResponse(
        url: URL,
        statusCode: Int,
        headers: [String: String] = [:],
        body: String = ""
    ) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            )
        )
        return (response, Data(body.utf8))
    }
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
