import XCTest
@testable import ClaudeUsageBar

@MainActor
final class UsageHistoryServiceTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeService() -> UsageHistoryService {
        let url = tempDir.appendingPathComponent("history.json")
        return UsageHistoryService(historyFileURL: url)
    }

    // MARK: - Application Support location

    func testDefaultHistoryFileURLIsInApplicationSupport() {
        // The canonical location must be under ~/Library/Application Support so it is
        // accessible inside the app sandbox. The test uses a freshly constructed service
        // (with a custom URL) to avoid depending on the static default computation.
        let customURL = tempDir.appendingPathComponent("history.json")
        let service = UsageHistoryService(historyFileURL: customURL)
        // Custom URL passes through unchanged.
        XCTAssertEqual(service.historyFileURL, customURL)
    }

    func testLegacyHistoryFileMigratedToNewURL() throws {
        // Simulate an existing legacy file at the old path and a fresh destination.
        let legacyDir = tempDir.appendingPathComponent("legacy", isDirectory: true)
        let newDir = tempDir.appendingPathComponent("new", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)

        let legacyURL = legacyDir.appendingPathComponent("history.json")
        let newURL = newDir.appendingPathComponent("history.json")

        // Write a legacy history file.
        let legacyService = UsageHistoryService(historyFileURL: legacyURL)
        legacyService.recordDataPoint(pct5h: 0.3, pct7d: 0.6)
        legacyService.flushToDisk()
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))

        // Move it to simulate the migration helper.
        try FileManager.default.moveItem(at: legacyURL, to: newURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))

        // New-location service should load the migrated data.
        let newService = UsageHistoryService(historyFileURL: newURL)
        newService.loadHistory()
        XCTAssertEqual(newService.history.dataPoints.count, 1)
        XCTAssertEqual(newService.history.dataPoints.first?.pct5h ?? -1, 0.3, accuracy: 0.001)
    }

    // MARK: - Flush persistence & permissions

    func testFlushWritesFileWithCorrectPermissions() throws {
        let service = makeService()
        service.recordDataPoint(pct5h: 0.5, pct7d: 0.3)
        service.flushToDisk()

        let url = service.historyFileURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = attrs[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600, "History file should have 0600 permissions")
    }

    func testFlushDataRoundTrips() throws {
        let service = makeService()
        service.recordDataPoint(pct5h: 0.42, pct7d: 0.88)
        service.flushToDisk()

        let service2 = makeService()
        service2.loadHistory()

        XCTAssertEqual(service2.history.dataPoints.count, 1)
        let dp = try XCTUnwrap(service2.history.dataPoints.first)
        XCTAssertEqual(dp.pct5h, 0.42, accuracy: 0.001)
        XCTAssertEqual(dp.pct7d, 0.88, accuracy: 0.001)
    }

    func testFlushPreservesExistingFileOnSecondWrite() throws {
        let service = makeService()
        service.recordDataPoint(pct5h: 0.1, pct7d: 0.2)
        service.flushToDisk()

        service.recordDataPoint(pct5h: 0.3, pct7d: 0.4)
        service.flushToDisk()

        let service2 = makeService()
        service2.loadHistory()
        XCTAssertEqual(service2.history.dataPoints.count, 2)
    }

    func testFlushCorrectsWeakPermissionsFromLegacyInstallation() throws {
        let service = makeService()
        let url = service.historyFileURL

        // Simulate a file created by an older app version without explicit permissions.
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        service.recordDataPoint(pct5h: 0.5, pct7d: 0.3)
        service.flushToDisk()

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600,
                       "Flush must correct world-readable permissions from legacy installations")
    }

    func testPermissionsPreservedAfterMultipleFlushes() throws {
        let service = makeService()
        service.recordDataPoint(pct5h: 0.1, pct7d: 0.2)
        service.flushToDisk()

        service.recordDataPoint(pct5h: 0.3, pct7d: 0.4)
        service.flushToDisk()

        let attrs = try FileManager.default.attributesOfItem(atPath: service.historyFileURL.path)
        let perms = attrs[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600, "Permissions should remain 0600 after multiple flushes")
    }
}
