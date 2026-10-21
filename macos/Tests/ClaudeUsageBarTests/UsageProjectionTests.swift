import XCTest
@testable import ClaudeUsageBar

final class UsageProjectionTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    func testInsufficientDataWithFewerThanTwoPoints() {
        let points = [UsageDataPoint(timestamp: base, pct5h: 0.5, pct7d: 0.1)]
        let p = UsageProjection.compute(
            points: points, currentPct: 0.5,
            reset: base.addingTimeInterval(3600), pollingMinutes: 5, now: base
        )
        XCTAssertEqual(p.outcome, .insufficientData)
    }

    func testInsufficientDataWithoutReset() {
        let now = base.addingTimeInterval(300)
        let points = [
            UsageDataPoint(timestamp: base, pct5h: 0.2, pct7d: 0.1),
            UsageDataPoint(timestamp: now, pct5h: 0.4, pct7d: 0.1),
        ]
        let p = UsageProjection.compute(
            points: points, currentPct: 0.4, reset: nil, pollingMinutes: 5, now: now
        )
        XCTAssertEqual(p.outcome, .insufficientData)
    }

    func testInsufficientDataWhenResetInPast() {
        let now = base.addingTimeInterval(300)
        let points = [
            UsageDataPoint(timestamp: base, pct5h: 0.2, pct7d: 0.1),
            UsageDataPoint(timestamp: now, pct5h: 0.4, pct7d: 0.1),
        ]
        let p = UsageProjection.compute(
            points: points, currentPct: 0.4,
            reset: now.addingTimeInterval(-60), pollingMinutes: 5, now: now
        )
        XCTAssertEqual(p.outcome, .insufficientData)
    }

    func testFlatUsageLastsUntilReset() {
        let now = base.addingTimeInterval(300)
        let points = [
            UsageDataPoint(timestamp: base, pct5h: 0.5, pct7d: 0.1),
            UsageDataPoint(timestamp: now, pct5h: 0.5, pct7d: 0.1),
        ]
        let p = UsageProjection.compute(
            points: points, currentPct: 0.5,
            reset: now.addingTimeInterval(3600), pollingMinutes: 5, now: now
        )
        XCTAssertEqual(p.outcome, .lastsUntilReset)
    }

    func testDecliningUsageLastsUntilReset() {
        let now = base.addingTimeInterval(300)
        let points = [
            UsageDataPoint(timestamp: base, pct5h: 0.8, pct7d: 0.1),
            UsageDataPoint(timestamp: now, pct5h: 0.5, pct7d: 0.1),
        ]
        let p = UsageProjection.compute(
            points: points, currentPct: 0.5,
            reset: now.addingTimeInterval(3600), pollingMinutes: 5, now: now
        )
        XCTAssertEqual(p.outcome, .lastsUntilReset)
        XCTAssertLessThan(p.ratePerSecond, 0)
    }

    func testRisingUsageRunsOutBeforeReset() {
        // 0.5 → 0.6 over 5 min = +0.1 / 300s. Need +0.4 more to reach 1.0 ⇒ 1200s from `now`.
        let now = base.addingTimeInterval(300)
        let points = [
            UsageDataPoint(timestamp: base, pct5h: 0.5, pct7d: 0.1),
            UsageDataPoint(timestamp: now, pct5h: 0.6, pct7d: 0.1),
        ]
        let reset = now.addingTimeInterval(3 * 3600)
        let p = UsageProjection.compute(
            points: points, currentPct: 0.6, reset: reset, pollingMinutes: 5, now: now
        )
        guard case .runsOut(let date) = p.outcome else {
            return XCTFail("expected runsOut, got \(p.outcome)")
        }
        XCTAssertEqual(date.timeIntervalSince(now), 1200, accuracy: 1)
    }

    func testRisingButSlowLastsUntilReset() {
        // +0.01 over 5 min ⇒ reaching 1.0 from 0.5 takes ~15000s (~4.2h) > 1h reset.
        let now = base.addingTimeInterval(300)
        let points = [
            UsageDataPoint(timestamp: base, pct5h: 0.49, pct7d: 0.1),
            UsageDataPoint(timestamp: now, pct5h: 0.50, pct7d: 0.1),
        ]
        let p = UsageProjection.compute(
            points: points, currentPct: 0.50,
            reset: now.addingTimeInterval(3600), pollingMinutes: 5, now: now
        )
        XCTAssertEqual(p.outcome, .lastsUntilReset)
    }

    func testAlreadyMaxedRunsOutNow() {
        let now = base.addingTimeInterval(300)
        let points = [
            UsageDataPoint(timestamp: base, pct5h: 0.9, pct7d: 0.1),
            UsageDataPoint(timestamp: now, pct5h: 1.0, pct7d: 0.1),
        ]
        let reset = now.addingTimeInterval(3600)
        let p = UsageProjection.compute(
            points: points, currentPct: 1.0, reset: reset, pollingMinutes: 5, now: now
        )
        guard case .runsOut(let date) = p.outcome else {
            return XCTFail("expected runsOut, got \(p.outcome)")
        }
        XCTAssertEqual(date.timeIntervalSince(now), 0, accuracy: 1)
    }

    func testRateWindowAdaptsToPollingInterval() {
        // An old steep jump followed by recent flat usage. A 5-min window sees only the flat
        // recent pair (lasts); a 30-min window includes the steep jump (runs out).
        let now = base.addingTimeInterval(1800) // 30 min after base
        let points = [
            UsageDataPoint(timestamp: base, pct5h: 0.10, pct7d: 0.1),                        // t=0
            UsageDataPoint(timestamp: base.addingTimeInterval(600), pct5h: 0.70, pct7d: 0.1), // t=10m (steep)
            UsageDataPoint(timestamp: base.addingTimeInterval(1500), pct5h: 0.70, pct7d: 0.1),// t=25m (flat)
            UsageDataPoint(timestamp: now, pct5h: 0.70, pct7d: 0.1),                          // t=30m (flat)
        ]
        let reset = now.addingTimeInterval(3600)

        let p5 = UsageProjection.compute(
            points: points, currentPct: 0.70, reset: reset, pollingMinutes: 5, now: now
        )
        XCTAssertEqual(p5.outcome, .lastsUntilReset,
                       "5-min window should see only the flat recent samples")

        let p30 = UsageProjection.compute(
            points: points, currentPct: 0.70, reset: reset, pollingMinutes: 30, now: now
        )
        guard case .runsOut = p30.outcome else {
            return XCTFail("30-min window includes the steep jump; expected runsOut, got \(p30.outcome)")
        }
    }
}
