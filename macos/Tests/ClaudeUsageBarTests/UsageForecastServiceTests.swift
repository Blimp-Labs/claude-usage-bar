import XCTest
@testable import ClaudeUsageBar

final class UsageForecastServiceTests: XCTestCase {

    private let service = UsageForecastService()
    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Helpers

    /// Build a UsageHistory from (hoursAgo, pct5h%, pct7d%) tuples.
    /// pct values are in 0–100 and stored internally as fractions, matching UsageHistoryService.
    private func makeHistory(_ readings: [(hoursAgo: Double, pct5h: Double, pct7d: Double)]) -> UsageHistory {
        var history = UsageHistory()
        history.dataPoints = readings.map { r in
            UsageDataPoint(
                timestamp: now.addingTimeInterval(-r.hoursAgo * 3600),
                pct5h: r.pct5h / 100.0,
                pct7d: r.pct7d / 100.0
            )
        }
        return history
    }

    private func makeResponse(fiveHour: Double? = nil, sevenDay: Double? = nil) -> UsageResponse {
        UsageResponse(
            fiveHour:      fiveHour.map { UsageBucket(utilization: $0, resetsAt: nil) },
            sevenDay:      sevenDay.map { UsageBucket(utilization: $0, resetsAt: nil) },
            sevenDayOpus:  nil,
            sevenDaySonnet: nil,
            extraUsage:    nil
        )
    }

    // MARK: - Fallback path (< minSamples)

    func testForecastReturnsFallbackWhenHistoryIsEmpty() {
        let forecast = service.forecast(
            history: UsageHistory(),
            current: makeResponse(fiveHour: 40, sevenDay: 60),
            now: now
        )
        // With 1 total sample the service can't regress; it echoes the current value.
        XCTAssertEqual(forecast.projected5h, 40, accuracy: 0.01)
        XCTAssertEqual(forecast.projected7d, 60, accuracy: 0.01)
        XCTAssertLessThan(forecast.confidence5h, 0.2)
        XCTAssertLessThan(forecast.confidence7d, 0.2)
    }

    func testForecastReturnsFallbackWithOnlyOneHistorySample() {
        // 1 history + 1 current = 2 samples; minSamples = 3 → fallback
        let history = makeHistory([(hoursAgo: 2, pct5h: 30, pct7d: 50)])
        let forecast = service.forecast(
            history: history,
            current: makeResponse(fiveHour: 35, sevenDay: 55),
            now: now
        )
        XCTAssertEqual(forecast.projected5h, 35, accuracy: 1.0)
        XCTAssertLessThan(forecast.confidence5h, 0.2)
    }

    // MARK: - Trend projection

    func testForecastProjectsRisingTrend() {
        let history = makeHistory([
            (hoursAgo: 4, pct5h: 10, pct7d: 10),
            (hoursAgo: 3, pct5h: 20, pct7d: 20),
            (hoursAgo: 2, pct5h: 30, pct7d: 30),
            (hoursAgo: 1, pct5h: 40, pct7d: 40),
        ])
        let forecast = service.forecast(
            history: history,
            current: makeResponse(fiveHour: 50, sevenDay: 50),
            now: now
        )
        XCTAssertGreaterThan(forecast.projected5h, 50)
        XCTAssertGreaterThan(forecast.velocity5h, 0)
        XCTAssertGreaterThan(forecast.projected7d, 50)
        XCTAssertGreaterThan(forecast.velocity7d, 0)
    }

    func testForecastProjectsFallingTrend() {
        let history = makeHistory([
            (hoursAgo: 4, pct5h: 80, pct7d: 80),
            (hoursAgo: 3, pct5h: 70, pct7d: 70),
            (hoursAgo: 2, pct5h: 60, pct7d: 60),
            (hoursAgo: 1, pct5h: 50, pct7d: 50),
        ])
        let forecast = service.forecast(
            history: history,
            current: makeResponse(fiveHour: 40, sevenDay: 40),
            now: now
        )
        XCTAssertLessThan(forecast.projected5h, 40)
        XCTAssertLessThan(forecast.velocity5h, 0)
        XCTAssertLessThan(forecast.projected7d, 40)
        XCTAssertLessThan(forecast.velocity7d, 0)
    }

    func testForecastIsStableForFlatSignal() {
        let history = makeHistory([
            (hoursAgo: 5, pct5h: 50, pct7d: 30),
            (hoursAgo: 4, pct5h: 50, pct7d: 30),
            (hoursAgo: 3, pct5h: 50, pct7d: 30),
            (hoursAgo: 2, pct5h: 50, pct7d: 30),
            (hoursAgo: 1, pct5h: 50, pct7d: 30),
        ])
        let forecast = service.forecast(
            history: history,
            current: makeResponse(fiveHour: 50, sevenDay: 30),
            now: now
        )
        XCTAssertEqual(forecast.projected5h, 50, accuracy: 2.0)
        XCTAssertEqual(forecast.velocity5h,   0, accuracy: 1.0)
        XCTAssertEqual(forecast.projected7d, 30, accuracy: 2.0)
        XCTAssertEqual(forecast.velocity7d,   0, accuracy: 1.0)
    }

    // MARK: - Output clamping

    func testForecastClampsProjectionAboveZero() {
        // Steep downward trend ending at 0 — unclamped WLS would extrapolate negative.
        let history = makeHistory([
            (hoursAgo: 4, pct5h: 20, pct7d: 20),
            (hoursAgo: 3, pct5h: 10, pct7d: 10),
            (hoursAgo: 2, pct5h:  5, pct7d:  5),
            (hoursAgo: 1, pct5h:  2, pct7d:  2),
        ])
        let forecast = service.forecast(
            history: history,
            current: makeResponse(fiveHour: 0, sevenDay: 0),
            now: now
        )
        XCTAssertGreaterThanOrEqual(forecast.projected5h,  0)
        XCTAssertGreaterThanOrEqual(forecast.lowerBound5h, 0)
        XCTAssertGreaterThanOrEqual(forecast.projected7d,  0)
        XCTAssertGreaterThanOrEqual(forecast.lowerBound7d, 0)
    }

    func testForecastClampsProjectionBelowHundred() {
        // Steep upward trend ending at 100 — unclamped WLS would extrapolate above 100.
        let history = makeHistory([
            (hoursAgo: 4, pct5h: 60, pct7d: 60),
            (hoursAgo: 3, pct5h: 75, pct7d: 75),
            (hoursAgo: 2, pct5h: 85, pct7d: 85),
            (hoursAgo: 1, pct5h: 95, pct7d: 95),
        ])
        let forecast = service.forecast(
            history: history,
            current: makeResponse(fiveHour: 100, sevenDay: 100),
            now: now
        )
        XCTAssertLessThanOrEqual(forecast.projected5h,  100)
        XCTAssertLessThanOrEqual(forecast.upperBound5h, 100)
        XCTAssertLessThanOrEqual(forecast.projected7d,  100)
        XCTAssertLessThanOrEqual(forecast.upperBound7d, 100)
    }

    // MARK: - Reset drop detection

    func testForecastAttenuatesPreDropSamples() {
        // High usage, then a >20% drop.  Pre-drop samples should be down-weighted
        // so the forecast follows the post-drop regime, not the pre-drop high.
        let history = makeHistory([
            (hoursAgo: 5, pct5h: 90, pct7d: 90),
            (hoursAgo: 4, pct5h: 88, pct7d: 88),
            (hoursAgo: 3, pct5h: 85, pct7d: 85),
            (hoursAgo: 2, pct5h: 10, pct7d: 10),  // >20% drop — reset event
            (hoursAgo: 1, pct5h: 12, pct7d: 12),
        ])
        let forecast = service.forecast(
            history: history,
            current: makeResponse(fiveHour: 15, sevenDay: 15),
            now: now
        )
        XCTAssertLessThan(forecast.projected5h, 50,
            "Forecast should reflect post-drop regime (~15%), not the pre-drop high (~88%)")
    }

    // MARK: - Determinism

    func testForecastIsDeterministicWithInjectedNow() {
        let history = makeHistory([
            (hoursAgo: 3, pct5h: 20, pct7d: 30),
            (hoursAgo: 2, pct5h: 30, pct7d: 35),
            (hoursAgo: 1, pct5h: 40, pct7d: 40),
        ])
        let current = makeResponse(fiveHour: 50, sevenDay: 45)
        let a = service.forecast(history: history, current: current, now: now)
        let b = service.forecast(history: history, current: current, now: now)
        XCTAssertEqual(a.projected5h,   b.projected5h)
        XCTAssertEqual(a.projected7d,   b.projected7d)
        XCTAssertEqual(a.velocity5h,    b.velocity5h)
        XCTAssertEqual(a.confidence5h,  b.confidence5h)
        XCTAssertEqual(a.lowerBound5h,  b.lowerBound5h)
        XCTAssertEqual(a.upperBound5h,  b.upperBound5h)
    }

    // MARK: - Output invariants

    func testConfidenceIsAlwaysWithinZeroToOne() {
        let history = makeHistory([
            (hoursAgo: 3, pct5h: 20, pct7d: 30),
            (hoursAgo: 2, pct5h: 60, pct7d: 10),  // noisy
            (hoursAgo: 1, pct5h: 10, pct7d: 80),
        ])
        let forecast = service.forecast(
            history: history,
            current: makeResponse(fiveHour: 50, sevenDay: 45),
            now: now
        )
        XCTAssertGreaterThanOrEqual(forecast.confidence5h, 0)
        XCTAssertLessThanOrEqual(forecast.confidence5h, 1)
        XCTAssertGreaterThanOrEqual(forecast.confidence7d, 0)
        XCTAssertLessThanOrEqual(forecast.confidence7d, 1)
    }

    func testPredictionBoundsAreOrderedAndClamped() {
        let history = makeHistory([
            (hoursAgo: 3, pct5h: 20, pct7d: 30),
            (hoursAgo: 2, pct5h: 30, pct7d: 35),
            (hoursAgo: 1, pct5h: 40, pct7d: 40),
        ])
        let forecast = service.forecast(
            history: history,
            current: makeResponse(fiveHour: 50, sevenDay: 45),
            now: now
        )
        XCTAssertLessThanOrEqual(forecast.lowerBound5h, forecast.projected5h)
        XCTAssertGreaterThanOrEqual(forecast.upperBound5h, forecast.projected5h)
        XCTAssertGreaterThanOrEqual(forecast.lowerBound5h, 0)
        XCTAssertLessThanOrEqual(forecast.upperBound5h, 100)

        XCTAssertLessThanOrEqual(forecast.lowerBound7d, forecast.projected7d)
        XCTAssertGreaterThanOrEqual(forecast.upperBound7d, forecast.projected7d)
        XCTAssertGreaterThanOrEqual(forecast.lowerBound7d, 0)
        XCTAssertLessThanOrEqual(forecast.upperBound7d, 100)
    }

    func testEffectiveWindowIsPositive() {
        let history = makeHistory([
            (hoursAgo: 3, pct5h: 20, pct7d: 30),
            (hoursAgo: 2, pct5h: 30, pct7d: 35),
            (hoursAgo: 1, pct5h: 40, pct7d: 40),
        ])
        let forecast = service.forecast(
            history: history,
            current: makeResponse(fiveHour: 50, sevenDay: 45),
            now: now
        )
        XCTAssertGreaterThan(forecast.effectiveWindow5h, 0)
        XCTAssertGreaterThan(forecast.effectiveWindow7d, 0)
    }
}
