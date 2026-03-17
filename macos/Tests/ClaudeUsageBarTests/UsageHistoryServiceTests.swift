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
        XCTAssertEqual(service2.history.dataPoints.first?.pct5h, 0.42, accuracy: 0.001)
        XCTAssertEqual(service2.history.dataPoints.first?.pct7d, 0.88, accuracy: 0.001)
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

    func testFlushIsNoOpWhenNotDirty() {
        let service = makeService()

        // Not dirty — flush should be a no-op
        service.flushToDisk()

        // File should not exist since there was nothing to write
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.historyFileURL.path))
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
