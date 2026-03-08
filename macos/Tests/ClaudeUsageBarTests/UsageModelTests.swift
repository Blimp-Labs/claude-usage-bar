import XCTest
@testable import ClaudeUsageBar

final class UsageModelTests: XCTestCase {
    func testResetDateParsesTimestampWithoutTimezoneAsUTC() throws {
        let bucket = UsageBucket(
            utilization: 25.0,
            resetsAt: "2026-03-05T18:00:00"
        )

        XCTAssertEqual(bucket.resetsAtDate, date("2026-03-05T18:00:00Z"))
    }

    func testReconcileKeepsPreviousResetWhenServerTemporarilyDropsIt() throws {
        let previousReset = date("2026-03-05T18:00:00Z")
        let previous = usageResponse(
            fiveHour: UsageBucket(utilization: 88.0, resetsAt: iso(previousReset))
        )
        let current = usageResponse(
            fiveHour: UsageBucket(utilization: 89.0, resetsAt: nil)
        )

        let reconciled = current.reconciled(
            with: previous,
            now: date("2026-03-05T17:30:00Z")
        )

        XCTAssertEqual(reconciled.fiveHour?.resetsAtDate, previousReset)
    }

    func testReconcileAdvancesResetAfterRolloverWhenServerDropsIt() throws {
        let previousReset = date("2026-03-05T18:00:00Z")
        let previous = usageResponse(
            fiveHour: UsageBucket(utilization: 100.0, resetsAt: iso(previousReset))
        )
        let current = usageResponse(
            fiveHour: UsageBucket(utilization: 2.0, resetsAt: "not-a-date")
        )

        let reconciled = current.reconciled(
            with: previous,
            now: date("2026-03-05T18:05:00Z")
        )

        XCTAssertEqual(reconciled.fiveHour?.resetsAtDate, date("2026-03-05T23:00:00Z"))
    }

    func testReconcilePreservesValidServerReset() throws {
        let previous = usageResponse(
            fiveHour: UsageBucket(utilization: 100.0, resetsAt: "2026-03-05T18:00:00Z")
        )
        let current = usageResponse(
            fiveHour: UsageBucket(utilization: 2.0, resetsAt: "2026-03-05T22:00:00Z")
        )

        let reconciled = current.reconciled(
            with: previous,
            now: date("2026-03-05T18:05:00Z")
        )

        XCTAssertEqual(reconciled.fiveHour?.resetsAtDate, date("2026-03-05T22:00:00Z"))
    }

    private func usageResponse(fiveHour: UsageBucket? = nil) -> UsageResponse {
        UsageResponse(
            fiveHour: fiveHour,
            sevenDay: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            extraUsage: nil
        )
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
