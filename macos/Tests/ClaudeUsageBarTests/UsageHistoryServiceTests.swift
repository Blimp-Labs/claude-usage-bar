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

    func testFlushRoundTripsWithPrivatePermissions() throws {
        let service = makeService()
        service.recordDataPoint(pct5h: 0.42, pct7d: 0.88)
        service.flushToDisk()

        let attrs = try FileManager.default.attributesOfItem(atPath: service.historyFileURL.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)

        let service2 = makeService()
        service2.loadHistory()

        XCTAssertEqual(service2.history.dataPoints.count, 1)
        XCTAssertEqual(try XCTUnwrap(service2.history.dataPoints.first).pct5h, 0.42, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(service2.history.dataPoints.first).pct7d, 0.88, accuracy: 0.001)
    }

    func testSecondFlushKeepsDataAndPermissions() throws {
        let service = makeService()
        service.recordDataPoint(pct5h: 0.1, pct7d: 0.2)
        service.flushToDisk()

        service.recordDataPoint(pct5h: 0.3, pct7d: 0.4)
        service.flushToDisk()

        let attrs = try FileManager.default.attributesOfItem(atPath: service.historyFileURL.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)

        let service2 = makeService()
        service2.loadHistory()
        XCTAssertEqual(service2.history.dataPoints.count, 2)
    }

    func testFlushIsNoOpWhenNotDirty() {
        let service = makeService()
        service.flushToDisk()

        XCTAssertFalse(FileManager.default.fileExists(atPath: service.historyFileURL.path))
    }

    /// Upgrade path: an existing 0644 file must end up 0600.
    func testExistingLooseFileIsTightenedOnFlush() throws {
        let service = makeService()
        FileManager.default.createFile(
            atPath: service.historyFileURL.path,
            contents: Data("{\"dataPoints\":[]}".utf8),
            attributes: [.posixPermissions: 0o644]
        )

        service.recordDataPoint(pct5h: 0.5, pct7d: 0.5)
        service.flushToDisk()

        let attrs = try FileManager.default.attributesOfItem(atPath: service.historyFileURL.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
    }
}
