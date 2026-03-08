import XCTest
@testable import ClaudeUsageBar

final class StoredCredentialsTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - 1. Round-trip save/load

    func testRoundTripSaveLoad() throws {
        let creds = StoredCredentials(
            accessToken: "access-123",
            refreshToken: "refresh-456",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        try creds.save(baseDirectory: tempDir)

        let loaded = StoredCredentials.load(baseDirectory: tempDir)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.accessToken, "access-123")
        XCTAssertEqual(loaded?.refreshToken, "refresh-456")
        XCTAssertEqual(loaded?.expiresAt, Date(timeIntervalSince1970: 2_000_000_000))
    }

    // MARK: - 2. Plaintext migration

    func testPlaintextMigration() throws {
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        let fileURL = tempDir.appendingPathComponent(StoredCredentials.tokenFileName)
        try "sk-ant-plaintoken".write(to: fileURL, atomically: true, encoding: .utf8)

        let loaded = StoredCredentials.load(baseDirectory: tempDir)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.accessToken, "sk-ant-plaintoken")
        XCTAssertEqual(loaded?.refreshToken, "")
        XCTAssertEqual(loaded?.expiresAt, .distantFuture)
    }

    // MARK: - 3. Plaintext migration trims whitespace/newlines

    func testPlaintextMigrationTrimsWhitespace() throws {
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        let fileURL = tempDir.appendingPathComponent(StoredCredentials.tokenFileName)
        try "  sk-ant-spaced\n\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let loaded = StoredCredentials.load(baseDirectory: tempDir)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.accessToken, "sk-ant-spaced")
    }

    // MARK: - 4. Non-UTF-8 bytes return nil

    func testCorruptNonUTF8ReturnsNil() throws {
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        let fileURL = tempDir.appendingPathComponent(StoredCredentials.tokenFileName)
        let badBytes: [UInt8] = [0xFF, 0xFE]
        try Data(badBytes).write(to: fileURL)

        let loaded = StoredCredentials.load(baseDirectory: tempDir)
        XCTAssertNil(loaded)
    }

    // MARK: - 5. Empty file returns nil

    func testEmptyFileReturnsNil() throws {
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        let fileURL = tempDir.appendingPathComponent(StoredCredentials.tokenFileName)
        try Data().write(to: fileURL)

        let loaded = StoredCredentials.load(baseDirectory: tempDir)
        XCTAssertNil(loaded)
    }

    // MARK: - 6. Migrated credentials have needsRefresh == false

    func testMigratedCredentialsDoNotNeedRefresh() throws {
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        let fileURL = tempDir.appendingPathComponent(StoredCredentials.tokenFileName)
        try "sk-ant-legacy".write(to: fileURL, atomically: true, encoding: .utf8)

        let loaded = StoredCredentials.load(baseDirectory: tempDir)
        XCTAssertNotNil(loaded)
        XCTAssertFalse(loaded!.needsRefresh)
    }

    // MARK: - 7. needsRefresh true at 4m59s before expiry

    func testNeedsRefreshTrueAt4Min59sBeforeExpiry() {
        let creds = StoredCredentials(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: Date().addingTimeInterval(299)
        )
        XCTAssertTrue(creds.needsRefresh)
    }

    // MARK: - 8. needsRefresh false at 5m01s before expiry

    func testNeedsRefreshFalseAt5Min01sBeforeExpiry() {
        let creds = StoredCredentials(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: Date().addingTimeInterval(301)
        )
        XCTAssertFalse(creds.needsRefresh)
    }

    // MARK: - 9. needsRefresh true at exactly 300 seconds (boundary, >=)

    func testNeedsRefreshTrueAtExactly300Seconds() {
        let creds = StoredCredentials(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: Date().addingTimeInterval(300)
        )
        XCTAssertTrue(creds.needsRefresh)
    }

    // MARK: - 10. needsRefresh true when expired

    func testNeedsRefreshTrueWhenExpired() {
        let creds = StoredCredentials(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: Date().addingTimeInterval(-60)
        )
        XCTAssertTrue(creds.needsRefresh)
    }

    // MARK: - 11. isExpired true for past date

    func testIsExpiredTrueForPastDate() {
        let creds = StoredCredentials(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: Date().addingTimeInterval(-1)
        )
        XCTAssertTrue(creds.isExpired)
    }

    // MARK: - 12. isExpired false for future date

    func testIsExpiredFalseForFutureDate() {
        let creds = StoredCredentials(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: Date().addingTimeInterval(3600)
        )
        XCTAssertFalse(creds.isExpired)
    }

    // MARK: - 13. hasRefreshToken false for empty string

    func testHasRefreshTokenFalseForEmptyString() {
        let creds = StoredCredentials(
            accessToken: "a",
            refreshToken: "",
            expiresAt: .distantFuture
        )
        XCTAssertFalse(creds.hasRefreshToken)
    }

    // MARK: - 14. hasRefreshToken true for non-empty string

    func testHasRefreshTokenTrueForNonEmptyString() {
        let creds = StoredCredentials(
            accessToken: "a",
            refreshToken: "refresh-abc",
            expiresAt: .distantFuture
        )
        XCTAssertTrue(creds.hasRefreshToken)
    }

    // MARK: - 15. Directory permissions 0700 after save

    func testDirectoryPermissions0700AfterSave() throws {
        let creds = StoredCredentials(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: .distantFuture
        )
        try creds.save(baseDirectory: tempDir)

        let attrs = try FileManager.default.attributesOfItem(atPath: tempDir.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o700)
    }

    // MARK: - 16. File permissions 0600 after save

    func testFilePermissions0600AfterSave() throws {
        let creds = StoredCredentials(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: .distantFuture
        )
        try creds.save(baseDirectory: tempDir)

        let fileURL = tempDir.appendingPathComponent(StoredCredentials.tokenFileName)
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600)
    }

    // MARK: - 17. Delete removes file and load returns nil

    func testDeleteRemovesFileAndLoadReturnsNil() throws {
        let creds = StoredCredentials(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: .distantFuture
        )
        try creds.save(baseDirectory: tempDir)
        XCTAssertNotNil(StoredCredentials.load(baseDirectory: tempDir))

        StoredCredentials.delete(baseDirectory: tempDir)
        XCTAssertNil(StoredCredentials.load(baseDirectory: tempDir))
    }

    // MARK: - 18. Overwrite: save A then save B, load returns B

    func testOverwriteSaveAThenSaveBLoadReturnsB() throws {
        let credsA = StoredCredentials(
            accessToken: "token-A",
            refreshToken: "refresh-A",
            expiresAt: Date(timeIntervalSince1970: 1_000_000_000)
        )
        try credsA.save(baseDirectory: tempDir)

        let credsB = StoredCredentials(
            accessToken: "token-B",
            refreshToken: "refresh-B",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        try credsB.save(baseDirectory: tempDir)

        let loaded = StoredCredentials.load(baseDirectory: tempDir)
        XCTAssertEqual(loaded?.accessToken, "token-B")
        XCTAssertEqual(loaded?.refreshToken, "refresh-B")
    }

    // MARK: - 19. Empty refreshToken still exposes accessToken

    func testEmptyRefreshTokenStillExposesAccessToken() {
        let creds = StoredCredentials(
            accessToken: "my-access-token",
            refreshToken: "",
            expiresAt: .distantFuture
        )
        XCTAssertEqual(creds.accessToken, "my-access-token")
        XCTAssertFalse(creds.hasRefreshToken)
    }
}
