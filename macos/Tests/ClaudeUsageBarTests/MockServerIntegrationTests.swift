import XCTest
@testable import ClaudeUsageBar

/// End-to-end tests against the real `scripts/mock-server.py`: a live HTTP
/// server, a real `URLSession`, and the real decode → reconcile → project path.
///
/// These catch drift between the mock server's payloads and the app's model,
/// which the pure-Swift unit tests cannot see.
@MainActor
final class MockServerIntegrationTests: XCTestCase {
    private var server: MockServer?

    override func setUp() async throws {
        try await super.setUp()
        server = try MockServer.start()
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        try await super.tearDown()
    }

    // MARK: - Per-model bars

    func testModelScopedScenarioReportsEveryModelFromLimits() async throws {
        let usage = try await fetchUsage(scenario: "model_scoped")

        XCTAssertEqual(
            usage.perModelWeekly.map(\.displayName),
            ["Fable 5", "Opus", "Sonnet"]
        )
        XCTAssertEqual(usage.perModelWeekly.first?.bucket.utilization, 48.5)
    }

    func testFableMixedScenarioMergesLimitsWithFixedFieldsWithoutDuplicating() async throws {
        let usage = try await fetchUsage(scenario: "fable_mixed")

        // Fable arrives via `limits`, Opus/Sonnet via the fixed `seven_day_*`
        // fields — the popover should show all three exactly once.
        XCTAssertEqual(
            usage.perModelWeekly.map(\.displayName),
            ["Fable 5", "Opus", "Sonnet"]
        )
        XCTAssertEqual(usage.perModelWeekly.first?.bucket.utilization, 48.5)
        XCTAssertNotNil(usage.perModelWeekly.first?.bucket.resetsAtDate)
    }

    func testLegacyPerModelScenarioStillWorksWithoutLimits() async throws {
        let usage = try await fetchUsage(scenario: "per_model")

        XCTAssertNil(usage.limits)
        XCTAssertEqual(usage.perModelWeekly.map(\.displayName), ["Opus", "Sonnet"])
    }

    func testNormalScenarioReportsNoPerModelBars() async throws {
        let usage = try await fetchUsage(scenario: "normal")

        XCTAssertTrue(usage.perModelWeekly.isEmpty)
        XCTAssertEqual(usage.fiveHour?.utilization, 25.0)
        XCTAssertEqual(usage.sevenDay?.utilization, 45.0)
    }

    /// The bars the menu bar icon draws must survive a payload that also
    /// carries `limits`, since that is the shape newer accounts return.
    func testTopLevelWindowsAreUnaffectedByLimits() async throws {
        let service = try makeService()
        try await setScenario("model_scoped")
        await service.fetchUsage()

        XCTAssertNil(service.lastError)
        XCTAssertEqual(service.pct5h, 0.35, accuracy: 0.0001)
        XCTAssertEqual(service.pct7d, 0.55, accuracy: 0.0001)
    }

    // MARK: - Polling across scenario changes

    func testSwitchingScenariosBetweenPollsUpdatesPerModelBars() async throws {
        let service = try makeService()

        try await setScenario("per_model")
        await service.fetchUsage()
        XCTAssertEqual(
            service.usage?.perModelWeekly.map(\.displayName),
            ["Opus", "Sonnet"]
        )

        try await setScenario("model_scoped")
        await service.fetchUsage()
        XCTAssertEqual(
            service.usage?.perModelWeekly.map(\.displayName),
            ["Fable 5", "Opus", "Sonnet"]
        )
    }

    /// A model-scoped window that arrives without a reset should inherit the
    /// previous poll's reset rather than losing it.
    func testResetIsCarriedAcrossPollsWhenServerOmitsIt() async throws {
        let service = try makeService()

        try await setScenario("model_scoped")
        await service.fetchUsage()
        let firstReset = try XCTUnwrap(service.usage?.perModelWeekly.first?.bucket.resetsAtDate)

        try await setScenario("model_scoped_no_reset")
        await service.fetchUsage()

        XCTAssertEqual(service.usage?.perModelWeekly.first?.displayName, "Fable 5")
        // Carrying a reset forward re-serialises it without fractional seconds,
        // so compare at whole-second resolution.
        let carried = try XCTUnwrap(service.usage?.perModelWeekly.first?.bucket.resetsAtDate)
        XCTAssertEqual(
            carried.timeIntervalSince1970,
            firstReset.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    // MARK: - Endpoint override

    func testLoopbackOverrideIsHonoured() throws {
        let url = try XCTUnwrap(server?.usageURL)
        XCTAssertEqual(
            UsageService.resolvedUsageEndpoint(
                environment: [UsageService.usageEndpointOverrideKey: url.absoluteString]
            ),
            url
        )
    }

    func testNonLoopbackOverrideIsIgnored() {
        let resolved = UsageService.resolvedUsageEndpoint(
            environment: [UsageService.usageEndpointOverrideKey: "https://evil.example.com/api/oauth/usage"]
        )

        XCTAssertEqual(resolved.host, "api.anthropic.com")
    }

    // MARK: - Helpers

    private func fetchUsage(scenario: String) async throws -> UsageResponse {
        let service = try makeService()
        try await setScenario(scenario)
        await service.fetchUsage()

        XCTAssertNil(service.lastError)
        return try XCTUnwrap(service.usage)
    }

    private func setScenario(_ name: String) async throws {
        try await XCTUnwrap(server).setScenario(name)
    }

    private func makeService() throws -> UsageService {
        let server = try XCTUnwrap(self.server)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let store = StoredCredentialsStore(directoryURL: directory)
        try store.save(
            StoredCredentials(
                accessToken: "integration-token",
                refreshToken: "integration-refresh",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: UsageService.defaultOAuthScopes
            )
        )

        return UsageService(
            session: URLSession(configuration: .ephemeral),
            usageEndpoint: server.usageURL,
            credentialsStore: store,
            localProfileLoader: { nil }
        )
    }
}

// MARK: - Mock server process

/// Runs `scripts/mock-server.py` on an ephemeral port for the life of a test.
private final class MockServer {
    let port: Int
    private let process: Process

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var usageURL: URL { baseURL.appendingPathComponent("api/oauth/usage") }

    private init(port: Int, process: Process) {
        self.port = port
        self.process = process
    }

    static func start() throws -> MockServer {
        let script = repositoryRoot
            .appendingPathComponent("scripts")
            .appendingPathComponent("mock-server.py")

        guard FileManager.default.fileExists(atPath: script.path) else {
            throw XCTSkip("mock-server.py not found at \(script.path)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // --port 0 lets the OS pick a free port; the server prints the one it bound.
        process.arguments = ["python3", script.path, "--port", "0"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw XCTSkip("Could not launch python3: \(error.localizedDescription)")
        }

        guard let port = readBoundPort(from: output, process: process) else {
            process.terminate()
            throw XCTSkip("Mock server did not report a port")
        }

        return MockServer(port: port, process: process)
    }

    func setScenario(_ name: String) async throws {
        let url = baseURL.appendingPathComponent("scenario").appendingPathComponent(name)
        let (_, response) = try await URLSession(configuration: .ephemeral).data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode
        XCTAssertEqual(status, 200, "Unknown mock scenario '\(name)'")
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    /// Blocks until the server prints its "running on http://127.0.0.1:<port>"
    /// banner, so tests never race the socket becoming ready.
    private static func readBoundPort(from pipe: Pipe, process: Process) -> Int? {
        let handle = pipe.fileHandleForReading
        let deadline = Date().addingTimeInterval(30)
        var buffered = ""

        while Date() < deadline {
            guard process.isRunning || !buffered.isEmpty else { return nil }

            let chunk = handle.availableData
            guard !chunk.isEmpty else { continue }
            buffered += String(decoding: chunk, as: UTF8.self)

            for line in buffered.split(separator: "\n") {
                guard line.contains("running on") else { continue }
                guard let portText = line.split(separator: ":").last,
                      let port = Int(portText.trimmingCharacters(in: .whitespaces)) else {
                    continue
                }
                return port
            }
        }

        return nil
    }

    /// `#filePath` is `<repo>/macos/Tests/ClaudeUsageBarTests/<file>.swift`.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ClaudeUsageBarTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // macos
            .deletingLastPathComponent()   // repo root
    }
}
