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

    // MARK: - Per-model weekly windows (`limits`)

    func testPerModelWeeklyReadsModelScopedLimits() throws {
        let response = try decode("""
        {
          "five_hour": {"utilization": 20.0, "resets_at": "2026-03-05T18:00:00Z"},
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": 48.5,
             "resets_at": "2026-03-10T00:00:00Z",
             "scope": {"model": {"display_name": "Fable 5"}}},
            {"kind": "weekly_scoped", "group": "subscription", "percent": 71.0,
             "resets_at": "2026-03-10T00:00:00Z",
             "scope": {"model": {"display_name": "Opus"}}}
          ]
        }
        """)

        XCTAssertEqual(response.perModelWeekly.map(\.displayName), ["Fable 5", "Opus"])
        XCTAssertEqual(response.perModelWeekly.first?.bucket.utilization, 48.5)
        XCTAssertEqual(
            response.perModelWeekly.first?.bucket.resetsAtDate,
            date("2026-03-10T00:00:00Z")
        )
    }

    func testPerModelWeeklyIgnoresNonWeeklyAndNonModelScopes() throws {
        let response = try decode("""
        {
          "limits": [
            {"kind": "five_hour_scoped", "group": "subscription", "percent": 10.0,
             "resets_at": null, "scope": {"model": {"display_name": "Fable 5"}}},
            {"kind": "weekly_scoped", "group": "subscription", "percent": 12.0,
             "resets_at": null, "scope": {"surface": {"display_name": "Cowork"}}},
            {"kind": "weekly_scoped", "group": "subscription", "percent": 48.5,
             "resets_at": null, "scope": {"model": {"display_name": "Fable 5"}}}
          ]
        }
        """)

        XCTAssertEqual(response.perModelWeekly.map(\.displayName), ["Fable 5"])
    }

    func testPerModelWeeklyFallsBackToFixedFieldsForUncoveredModels() throws {
        let response = try decode("""
        {
          "seven_day_opus": {"utilization": 71.0, "resets_at": "2026-03-10T00:00:00Z"},
          "seven_day_sonnet": {"utilization": 15.0, "resets_at": "2026-03-10T00:00:00Z"},
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": 48.5,
             "resets_at": "2026-03-10T00:00:00Z",
             "scope": {"model": {"display_name": "Fable 5"}}}
          ]
        }
        """)

        XCTAssertEqual(response.perModelWeekly.map(\.displayName), ["Fable 5", "Opus", "Sonnet"])
    }

    func testPerModelWeeklyDoesNotDuplicateAModelCoveredByLimits() throws {
        let response = try decode("""
        {
          "seven_day_opus": {"utilization": 71.0, "resets_at": null},
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": 71.0,
             "resets_at": null, "scope": {"model": {"display_name": "Claude Opus 5"}}}
          ]
        }
        """)

        XCTAssertEqual(response.perModelWeekly.map(\.displayName), ["Claude Opus 5"])
    }

    func testPerModelWeeklyIsEmptyWhenNothingIsReported() throws {
        XCTAssertTrue(try decode("{}").perModelWeekly.isEmpty)
    }

    func testLimitResetAcceptsEpochSeconds() throws {
        let response = try decode("""
        {
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": 48.5,
             "resets_at": 1772668800,
             "scope": {"model": {"display_name": "Fable 5"}}}
          ]
        }
        """)

        XCTAssertEqual(
            response.perModelWeekly.first?.bucket.resetsAtDate,
            Date(timeIntervalSince1970: 1_772_668_800)
        )
    }

    func testReconcileAdvancesModelScopedResetAfterRollover() throws {
        let previous = try decode("""
        {
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": 99.0,
             "resets_at": "2026-03-05T18:00:00Z",
             "scope": {"model": {"display_name": "Fable 5"}}}
          ]
        }
        """)
        let current = try decode("""
        {
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": 1.0,
             "resets_at": null,
             "scope": {"model": {"display_name": "Fable 5"}}}
          ]
        }
        """)

        let reconciled = current.reconciled(with: previous, now: date("2026-03-05T18:05:00Z"))

        XCTAssertEqual(
            reconciled.perModelWeekly.first?.bucket.resetsAtDate,
            date("2026-03-12T18:00:00Z")
        )
    }

    func testReconcileDoesNotBorrowResetFromADifferentModel() throws {
        let previous = try decode("""
        {
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": 99.0,
             "resets_at": "2026-03-05T18:00:00Z",
             "scope": {"model": {"display_name": "Opus"}}}
          ]
        }
        """)
        let current = try decode("""
        {
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": 1.0,
             "resets_at": null,
             "scope": {"model": {"display_name": "Fable 5"}}}
          ]
        }
        """)

        let reconciled = current.reconciled(with: previous, now: date("2026-03-05T18:05:00Z"))

        XCTAssertNil(reconciled.perModelWeekly.first?.bucket.resetsAtDate)
    }

    private func decode(_ json: String) throws -> UsageResponse {
        try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
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
