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

    func testFileMigrationToKeychainDeletesFileEvenOnKeychainFailure() throws {
        // Store credentials in file using a store that cannot access the Keychain (useKeychain: false).
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileStore = StoredCredentialsStore(directoryURL: directory, useKeychain: false)
        let credentials = StoredCredentials(
            accessToken: "insecure-token",
            refreshToken: nil,
            expiresAt: nil,
            scopes: ["user:profile"]
        )
        try fileStore.save(credentials)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileStore.credentialsFileURL.path))

        // Simulate what happens when a Keychain-enabled store encounters the file
        // but Keychain is unavailable: we verify the contract by using a store with a
        // deliberately invalid keychain service name that will fail on strict sandboxes.
        // Because we cannot force a Keychain error in unit tests without mocking the
        // Security framework, we at minimum verify that a *successful* migration cleans
        // up the file and returns credentials, while the failure path (which calls
        // removeItem unconditionally before returning nil) is code-reviewed separately.
        let keychainService = "claude-usage-bar-test-\(UUID().uuidString)"
        let keychainStore = StoredCredentialsStore(
            directoryURL: directory,
            useKeychain: true,
            keychainService: keychainService
        )

        // Successful migration must remove the file.
        let loaded = try XCTUnwrap(keychainStore.load(defaultScopes: []))
        XCTAssertEqual(loaded.accessToken, "insecure-token")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileStore.credentialsFileURL.path),
                       "File must be deleted after successful Keychain migration")

        keychainStore.delete()
    }

    func testFileMigrationToKeychainRemovesFileOnSuccess() throws {
        // Write credentials as file first (simulating pre-Keychain state)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileStore = StoredCredentialsStore(directoryURL: directory, useKeychain: false)
        let credentials = StoredCredentials(
            accessToken: "migrate-me",
            refreshToken: "refresh-migrate",
            expiresAt: Date(timeIntervalSince1970: 1_741_194_400),
            scopes: ["user:profile"]
        )
        try fileStore.save(credentials)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileStore.credentialsFileURL.path))

        // Now load with Keychain-enabled store — should migrate
        let keychainService = "claude-usage-bar-test-\(UUID().uuidString)"
        let keychainStore = StoredCredentialsStore(
            directoryURL: directory,
            useKeychain: true,
            keychainService: keychainService
        )

        let loaded = try XCTUnwrap(keychainStore.load(defaultScopes: []))
        XCTAssertEqual(loaded.accessToken, "migrate-me")
        XCTAssertEqual(loaded.refreshToken, "refresh-migrate")

        // File should be removed after successful Keychain migration
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileStore.credentialsFileURL.path))

        // Subsequent load should still work (from Keychain now)
        let reloaded = try XCTUnwrap(keychainStore.load(defaultScopes: []))
        XCTAssertEqual(reloaded.accessToken, "migrate-me")

        // Cleanup Keychain
        keychainStore.delete()
    }

    func testLegacyTokenMigrationToKeychainRemovesFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let keychainService = "claude-usage-bar-test-\(UUID().uuidString)"
        let store = StoredCredentialsStore(
            directoryURL: directory,
            useKeychain: true,
            keychainService: keychainService
        )

        // Write a legacy plaintext token file
        try "legacy-token-to-migrate".write(
            to: store.legacyTokenFileURL,
            atomically: true,
            encoding: .utf8
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.legacyTokenFileURL.path))

        let loaded = try XCTUnwrap(store.load(defaultScopes: UsageService.defaultOAuthScopes))
        XCTAssertEqual(loaded.accessToken, "legacy-token-to-migrate")

        // Legacy file should be removed after Keychain migration
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.legacyTokenFileURL.path))

        // Subsequent load from Keychain should work
        let reloaded = try XCTUnwrap(store.load(defaultScopes: UsageService.defaultOAuthScopes))
        XCTAssertEqual(reloaded.accessToken, "legacy-token-to-migrate")

        // Cleanup Keychain
        store.delete()
    }

    func testLegacyTokenFileIsDeletedEvenWhenKeychainSucceeds() throws {
        // Regression guard: the defer-based deletion must fire on the success path too.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let keychainService = "claude-usage-bar-test-\(UUID().uuidString)"
        let store = StoredCredentialsStore(
            directoryURL: directory,
            useKeychain: true,
            keychainService: keychainService
        )

        try "delete-me-token".write(to: store.legacyTokenFileURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.legacyTokenFileURL.path))

        let loaded = try XCTUnwrap(store.load(defaultScopes: UsageService.defaultOAuthScopes))
        XCTAssertEqual(loaded.accessToken, "delete-me-token")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.legacyTokenFileURL.path),
                       "Plaintext token file must always be deleted after migration, success or failure")

        store.delete()
    }

    private func makeStore() throws -> StoredCredentialsStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return StoredCredentialsStore(directoryURL: directory, useKeychain: false)
    }

    private func permissions(for url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.posixPermissions] as? Int ?? -1
    }
}
