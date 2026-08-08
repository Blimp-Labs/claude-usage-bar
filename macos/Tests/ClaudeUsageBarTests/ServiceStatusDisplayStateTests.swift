import XCTest
@testable import ClaudeUsageBar

/// Pure-value tests for the popover Service Status display state machine (DV-1.8).
final class ServiceStatusDisplayStateTests: XCTestCase {

    func testNoSnapshotNoErrorIsLoading() {
        let state = ServiceStatusDisplayState.make(snapshot: nil, lastError: nil)
        XCTAssertEqual(state, .loading)
    }

    func testNoSnapshotWithErrorIsUnavailable() {
        let state = ServiceStatusDisplayState.make(snapshot: nil, lastError: .http(503))
        XCTAssertEqual(state, .unavailable)
    }

    func testSnapshotPresentIsReady() {
        let snap = StatusSnapshot(
            rollup: .partialOutage,
            impactedComponents: [],
            activeIncidents: [],
            allMonitoredComponents: [],
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
        let state = ServiceStatusDisplayState.make(snapshot: snap, lastError: nil)
        if case .ready(let s) = state {
            XCTAssertEqual(s.rollup, .partialOutage)
        } else {
            XCTFail("Expected .ready")
        }
    }

    func testSnapshotWinsOverError() {
        // If we have a stale-but-recent snapshot, the most recent error must not blank it out.
        let snap = StatusSnapshot(
            rollup: .operational,
            impactedComponents: [],
            activeIncidents: [],
            allMonitoredComponents: [],
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
        let state = ServiceStatusDisplayState.make(snapshot: snap, lastError: .transport(.timedOut))
        if case .ready = state {
            // expected
        } else {
            XCTFail("Snapshot should win over error")
        }
    }
}
