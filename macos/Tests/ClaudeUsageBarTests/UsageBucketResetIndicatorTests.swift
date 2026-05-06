import XCTest
@testable import ClaudeUsageBar

final class UsageBucketResetIndicatorTests: XCTestCase {

    // MARK: - secondsUntilReset

    func testSecondsUntilResetReturnsNilWhenNoResetDate() {
        let bucket = UsageBucket(utilization: 50.0, resetsAt: nil)
        XCTAssertNil(bucket.secondsUntilReset())
    }

    func testSecondsUntilResetReturnsPositiveValueWhenFuture() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let resetDate = now.addingTimeInterval(3600)
        let bucket = UsageBucket(utilization: 10.0, resetsAt: iso(resetDate))

        let secs = try? XCTUnwrap(bucket.secondsUntilReset(now: now))
        XCTAssertNotNil(secs)
        if let secs {
            XCTAssertEqual(secs, 3600, accuracy: 1.0)
        }
    }

    func testSecondsUntilResetReturnsNegativeWhenPastWithoutClamping() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let resetDate = now.addingTimeInterval(-600)
        let bucket = UsageBucket(utilization: 10.0, resetsAt: iso(resetDate))

        let secs = bucket.secondsUntilReset(now: now)
        XCTAssertNotNil(secs)
        if let secs {
            XCTAssertLessThan(secs, 0)
            XCTAssertEqual(secs, -600, accuracy: 1.0)
        }
    }

    // MARK: - resetPosition

    func testResetPositionReturnsNilWhenNoResetDate() {
        let bucket = UsageBucket(utilization: 50.0, resetsAt: nil)
        XCTAssertNil(bucket.resetPosition(windowSeconds: 5 * 3600))
    }

    func testResetPositionIsZeroAtFullWindow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let windowSeconds: TimeInterval = 5 * 3600
        let resetDate = now.addingTimeInterval(windowSeconds)
        let bucket = UsageBucket(utilization: 10.0, resetsAt: iso(resetDate))

        let pos = bucket.resetPosition(windowSeconds: windowSeconds, now: now)
        XCTAssertNotNil(pos)
        if let pos {
            XCTAssertEqual(pos, 0.0, accuracy: 0.0005)
        }
    }

    func testResetPositionIsHalfAtMidpoint() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let windowSeconds: TimeInterval = 5 * 3600
        let resetDate = now.addingTimeInterval(windowSeconds / 2)
        let bucket = UsageBucket(utilization: 10.0, resetsAt: iso(resetDate))

        let pos = bucket.resetPosition(windowSeconds: windowSeconds, now: now)
        XCTAssertNotNil(pos)
        if let pos {
            XCTAssertEqual(pos, 0.5, accuracy: 0.0005)
        }
    }

    func testResetPositionIsOneWhenResetIsNow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let bucket = UsageBucket(utilization: 10.0, resetsAt: iso(now))

        let pos = bucket.resetPosition(windowSeconds: 5 * 3600, now: now)
        XCTAssertNotNil(pos)
        if let pos {
            XCTAssertEqual(pos, 1.0, accuracy: 0.0005)
        }
    }

    func testResetPositionClampsToOneWhenPast() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let resetDate = now.addingTimeInterval(-3600)
        let bucket = UsageBucket(utilization: 10.0, resetsAt: iso(resetDate))

        let pos = bucket.resetPosition(windowSeconds: 5 * 3600, now: now)
        XCTAssertEqual(pos, 1.0)
    }

    func testResetPositionClampsToZeroBeyondWindow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let windowSeconds: TimeInterval = 5 * 3600
        let resetDate = now.addingTimeInterval(windowSeconds * 2)
        let bucket = UsageBucket(utilization: 10.0, resetsAt: iso(resetDate))

        let pos = bucket.resetPosition(windowSeconds: windowSeconds, now: now)
        XCTAssertEqual(pos, 0.0)
    }

    // MARK: - resetIndicatorState matrix

    func testStateMatrixLowUsagePlentyOfTimeIsNormal() {
        XCTAssertEqual(
            resetIndicatorState(usagePct: 40.0, timeLeftFraction: 0.80),
            .normal
        )
    }

    func testStateMatrixLowUsageLateInWindowIsWarning() {
        XCTAssertEqual(
            resetIndicatorState(usagePct: 40.0, timeLeftFraction: 0.20),
            .warning
        )
    }

    func testStateMatrixHighUsagePlentyOfTimeIsCritical() {
        XCTAssertEqual(
            resetIndicatorState(usagePct: 90.0, timeLeftFraction: 0.80),
            .critical
        )
    }

    func testStateMatrixHighUsageLateInWindowIsInUsageLimit() {
        XCTAssertEqual(
            resetIndicatorState(usagePct: 90.0, timeLeftFraction: 0.20),
            .inUsageLimit
        )
    }

    func testStateMatrixUsageBoundaryEightyCountsAsHigh() {
        XCTAssertEqual(
            resetIndicatorState(usagePct: 80.0, timeLeftFraction: 0.80),
            .critical
        )
    }

    func testStateMatrixTimeBoundaryThirtyThreePercentCountsAsLate() {
        XCTAssertEqual(
            resetIndicatorState(usagePct: 40.0, timeLeftFraction: 0.33),
            .warning
        )
    }

    // MARK: - Helpers

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
