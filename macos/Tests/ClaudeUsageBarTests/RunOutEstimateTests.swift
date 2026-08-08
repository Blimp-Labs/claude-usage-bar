import XCTest
@testable import ClaudeUsageBar

final class RunOutEstimateTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    /// Build a `UsageForecast` fixture with only `velocity5h`/`confidence5h` varying;
    /// the other fields are irrelevant to `RunOutEstimate`.
    private func makeForecast(velocity5h: Double, confidence5h: Double = 0.8) -> UsageForecast {
        UsageForecast(
            projected5h: 0, projected7d: 0,
            lowerBound5h: 0, upperBound5h: 0,
            lowerBound7d: 0, upperBound7d: 0,
            velocity5h: velocity5h, velocity7d: 0,
            acceleration5h: 0, acceleration7d: 0,
            confidence5h: confidence5h, confidence7d: 0,
            effectiveWindow5h: 3600, effectiveWindow7d: 3600
        )
    }

    func testInsufficientDataWithoutForecast() {
        let e = RunOutEstimate.compute(
            forecast: nil, anchorPct: 50, anchorTime: base,
            reset: base.addingTimeInterval(3600), now: base
        )
        XCTAssertEqual(e.outcome, .insufficientData)
    }

    func testInsufficientDataWithLowConfidence() {
        let e = RunOutEstimate.compute(
            forecast: makeForecast(velocity5h: 40, confidence5h: 0.05),
            anchorPct: 50, anchorTime: base,
            reset: base.addingTimeInterval(3600), now: base
        )
        XCTAssertEqual(e.outcome, .insufficientData)
    }

    func testInsufficientDataWithoutReset() {
        let e = RunOutEstimate.compute(
            forecast: makeForecast(velocity5h: 40),
            anchorPct: 50, anchorTime: base, reset: nil, now: base
        )
        XCTAssertEqual(e.outcome, .insufficientData)
    }

    func testInsufficientDataWhenResetInPast() {
        let e = RunOutEstimate.compute(
            forecast: makeForecast(velocity5h: 40),
            anchorPct: 50, anchorTime: base,
            reset: base.addingTimeInterval(-60), now: base
        )
        XCTAssertEqual(e.outcome, .insufficientData)
    }

    func testFlatUsageLastsUntilReset() {
        let e = RunOutEstimate.compute(
            forecast: makeForecast(velocity5h: 0),
            anchorPct: 50, anchorTime: base,
            reset: base.addingTimeInterval(3600), now: base
        )
        XCTAssertEqual(e.outcome, .lastsUntilReset)
    }

    func testDecliningUsageLastsUntilReset() {
        let e = RunOutEstimate.compute(
            forecast: makeForecast(velocity5h: -10),
            anchorPct: 50, anchorTime: base,
            reset: base.addingTimeInterval(3600), now: base
        )
        XCTAssertEqual(e.outcome, .lastsUntilReset)
        XCTAssertLessThan(e.ratePerHour, 0)
    }

    func testRisingUsageRunsOutBeforeReset() {
        // 50% at velocity +40%/h needs 1.25h to reach 100%.
        let reset = base.addingTimeInterval(3 * 3600)
        let e = RunOutEstimate.compute(
            forecast: makeForecast(velocity5h: 40),
            anchorPct: 50, anchorTime: base, reset: reset, now: base
        )
        guard case .runsOut(let date) = e.outcome else {
            return XCTFail("expected runsOut, got \(e.outcome)")
        }
        XCTAssertEqual(date.timeIntervalSince(base), 1.25 * 3600, accuracy: 1)
    }

    func testRisingUsageButSlowLastsUntilReset() {
        // 50% at velocity +5%/h needs 10h to reach 100%, but reset is in 3h.
        let reset = base.addingTimeInterval(3 * 3600)
        let e = RunOutEstimate.compute(
            forecast: makeForecast(velocity5h: 5),
            anchorPct: 50, anchorTime: base, reset: reset, now: base
        )
        XCTAssertEqual(e.outcome, .lastsUntilReset)
    }

    func testCurrentPctExtrapolatesForwardWhenNowIsAfterAnchor() {
        // Anchored at 50% an hour ago, rising at +10%/h → live pct should read ~60% now.
        let anchorTime = base.addingTimeInterval(-3600)
        let e = RunOutEstimate.compute(
            forecast: makeForecast(velocity5h: 10),
            anchorPct: 50, anchorTime: anchorTime,
            reset: base.addingTimeInterval(3600), now: base
        )
        XCTAssertEqual(e.currentPct, 60, accuracy: 0.01)
    }

    func testCurrentPctClampedTo100() {
        // Anchored at 90% an hour ago, rising at +1000%/h → live pct would blow past 100%
        // without clamping.
        let e = RunOutEstimate.compute(
            forecast: makeForecast(velocity5h: 1000),
            anchorPct: 90, anchorTime: base.addingTimeInterval(-3600),
            reset: base.addingTimeInterval(3600), now: base
        )
        XCTAssertEqual(e.currentPct, 100, accuracy: 0.01)
    }
}
