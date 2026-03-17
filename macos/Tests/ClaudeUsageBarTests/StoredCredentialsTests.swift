import XCTest
@testable import ClaudeUsageBar

final class StoredCredentialsTests: XCTestCase {
    func testStoreSavesAndLoadsCredentialBundle() throws {
        let store = try makeStore()
        let credentials = StoredCredentials(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            expiresAt: Date(timeIntervalSince1970: 1_741_194_400),
            scopes: ["user:profile", "user:inference"]
        )

        try store.save(credentials)

        let loaded = try XCTUnwrap(store.load(defaultScopes: []))
        XCTAssertEqual(loaded, credentials)

        let filePermissions = try permissions(for: store.credentialsFileURL)
        let directoryPermissions = try permissions(for: store.directoryURL)
        XCTAssertEqual(filePermissions, 0o600)
        XCTAssertEqual(directoryPermissions, 0o700)
    }

    func testStoreLoadsLegacyRawTokenFile() throws {
        let store = try makeStore()
        try "legacy-access-token".write(
            to: store.legacyTokenFileURL,
            atomically: true,
            encoding: .utf8
        )

        let loaded = try XCTUnwrap(
            store.load(defaultScopes: UsageService.defaultOAuthScopes)
        )

        XCTAssertEqual(loaded.accessToken, "legacy-access-token")
        XCTAssertNil(loaded.refreshToken)
        XCTAssertNil(loaded.expiresAt)
        XCTAssertEqual(loaded.scopes, UsageService.defaultOAuthScopes)
    }

    // MARK: - isExpired

    func testIsExpiredReturnsFalseWhenExpiresAtIsNil() {
        let credentials = StoredCredentials(
            accessToken: "token",
            refreshToken: "refresh",
            expiresAt: nil,
            scopes: ["user:profile"]
        )
        XCTAssertFalse(credentials.isExpired())
    }

    func testIsExpiredReturnsTrueWhenPastExpiry() {
        let credentials = StoredCredentials(
            accessToken: "token",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(-60),
            scopes: ["user:profile"]
        )
        XCTAssertTrue(credentials.isExpired())
    }

    func testIsExpiredReturnsFalseWhenBeforeExpiry() {
        let credentials = StoredCredentials(
            accessToken: "token",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3600),
            scopes: ["user:profile"]
        )
        XCTAssertFalse(credentials.isExpired())
    }

    // MARK: - needsRefresh leeway

    func testNeedsRefreshUses300SecondLeewayByDefault() {
        let now = Date()
        let credentials = StoredCredentials(
            accessToken: "token",
            refreshToken: "refresh",
            expiresAt: now.addingTimeInterval(200),
            scopes: ["user:profile"]
        )
        // 200s until expiry < 300s leeway → needs refresh
        XCTAssertTrue(credentials.needsRefresh(at: now))

        let safeCredentials = StoredCredentials(
            accessToken: "token",
            refreshToken: "refresh",
            expiresAt: now.addingTimeInterval(400),
            scopes: ["user:profile"]
        )
        // 400s until expiry > 300s leeway → does not need refresh
        XCTAssertFalse(safeCredentials.needsRefresh(at: now))
    }

    private func makeStore() throws -> StoredCredentialsStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return StoredCredentialsStore(directoryURL: directory)
    }

    private func permissions(for url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.posixPermissions] as? Int ?? -1
    }
}
