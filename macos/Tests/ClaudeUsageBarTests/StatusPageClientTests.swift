import XCTest
@testable import ClaudeUsageBar

/// Tests for `StatusPageClient` decoding + error mapping. All network is faked via `FixtureHTTPClient`
/// so no live calls hit `status.claude.com` during CI.
final class StatusPageClientTests: XCTestCase {

    // MARK: - Fixture loading

    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            XCTFail("Missing fixture \(name).json")
            return Data()
        }
        return try Data(contentsOf: url)
    }

    // MARK: - Happy paths (one per severity fixture)

    func testDecodeAllOperational() async throws {
        let data = try loadFixture("statuspage_summary_all_operational")
        let client = StatusPageClient(http: FixtureHTTPClient(status: 200, body: data))
        let summary = try await client.fetchSummary()
        XCTAssertEqual(summary.components.count, 3)
        XCTAssertTrue(summary.components.allSatisfy { $0.status == .operational })
        XCTAssertEqual(summary.incidents.count, 0)
    }

    func testDecodePartialOutage() async throws {
        let data = try loadFixture("statuspage_summary_partial_outage")
        let client = StatusPageClient(http: FixtureHTTPClient(status: 200, body: data))
        let summary = try await client.fetchSummary()
        let api = summary.components.first { $0.name.contains("Claude API") }
        XCTAssertEqual(api?.status, .partialOutage)
    }

    func testDecodeMajorOutageWithIncident() async throws {
        let data = try loadFixture("statuspage_summary_major_outage_with_incident")
        let client = StatusPageClient(http: FixtureHTTPClient(status: 200, body: data))
        let summary = try await client.fetchSummary()
        XCTAssertEqual(summary.incidents.count, 1)
        XCTAssertEqual(summary.incidents.first?.impact, "critical")
        XCTAssertTrue(summary.components.contains { $0.status == .majorOutage })
    }

    func testDecodeUnderMaintenance() async throws {
        let data = try loadFixture("statuspage_summary_under_maintenance")
        let client = StatusPageClient(http: FixtureHTTPClient(status: 200, body: data))
        let summary = try await client.fetchSummary()
        XCTAssertTrue(summary.components.contains { $0.status == .underMaintenance })
    }

    func testDecodeUnknownStatusStringUsesForgivingFallback() async throws {
        let data = try loadFixture("statuspage_summary_unknown_status_string")
        let client = StatusPageClient(http: FixtureHTTPClient(status: 200, body: data))
        let summary = try await client.fetchSummary()
        // claude.ai had status="fluctuating_quantum_state" → forgiving → .operational
        let claudeAI = summary.components.first { $0.name == "claude.ai" }
        XCTAssertEqual(claudeAI?.status, .operational)
    }

    // MARK: - Error mapping

    func testHTTPNon2xxMapsToHttpError() async throws {
        let client = StatusPageClient(http: FixtureHTTPClient(status: 500, body: Data()))
        do {
            _ = try await client.fetchSummary()
            XCTFail("Expected throw")
        } catch let error as StatusError {
            XCTAssertEqual(error, .http(500))
        }
    }

    func testTransportErrorMapsToTransport() async throws {
        let client = StatusPageClient(
            http: FixtureHTTPClient(error: URLError(.timedOut))
        )
        do {
            _ = try await client.fetchSummary()
            XCTFail("Expected throw")
        } catch let error as StatusError {
            XCTAssertEqual(error, .transport(.timedOut))
        }
    }

    func testInvalidResponseMapsToInvalidResponse() async throws {
        let client = StatusPageClient(
            http: FixtureHTTPClient(error: StatusError.invalidResponse)
        )
        do {
            _ = try await client.fetchSummary()
            XCTFail("Expected throw")
        } catch let error as StatusError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testMalformedJSONMapsToDecodeError() async throws {
        let bogus = Data("{not even close to json".utf8)
        let client = StatusPageClient(http: FixtureHTTPClient(status: 200, body: bogus))
        do {
            _ = try await client.fetchSummary()
            XCTFail("Expected throw")
        } catch let error as StatusError {
            switch error {
            case .decode: break // any decode error string is OK
            default: XCTFail("Expected .decode, got \(error)")
            }
        }
    }
}

// MARK: - FixtureHTTPClient

/// In-memory `HTTPClient` test double. Either replays a canned response or throws an injected error.
struct FixtureHTTPClient: HTTPClient {
    let status: Int
    let body: Data
    let error: Error?

    init(status: Int = 200, body: Data = Data(), error: Error? = nil) {
        self.status = status
        self.body = body
        self.error = error
    }

    init(error: Error) {
        self.status = 0
        self.body = Data()
        self.error = error
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let error { throw error }
        guard let url = request.url else { throw StatusError.invalidResponse }
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (body, response)
    }
}
