import XCTest
@testable import ClaudeUsageBar

final class UsageChartInterpolationTests: XCTestCase {
    func testInterpolateValuesClampsNegativeOvershootAfterReset() {
        let base = Date(timeIntervalSince1970: 0)
        let points = [
            UsageDataPoint(timestamp: base, pct5h: 0.3, pct7d: 0.3),
            UsageDataPoint(timestamp: base.addingTimeInterval(1), pct5h: 0.7, pct7d: 0.7),
            UsageDataPoint(timestamp: base.addingTimeInterval(2), pct5h: 0.0, pct7d: 0.0),
            UsageDataPoint(timestamp: base.addingTimeInterval(3), pct5h: 1.0, pct7d: 1.0),
        ]

        XCTAssertLessThan(
            UsageChartInterpolation.catmullRom(0.3, 0.7, 0.0, 1.0, t: 0.966),
            0
        )

        let interpolated = UsageChartInterpolation.interpolateValues(
            at: base.addingTimeInterval(1.966),
            in: points
        )

        XCTAssertEqual(interpolated?.pct5h, 0)
        XCTAssertEqual(interpolated?.pct7d, 0)
    }

    func testInterpolateValuesClampsPositiveOvershootToHundredPercent() {
        let base = Date(timeIntervalSince1970: 0)
        let points = [
            UsageDataPoint(timestamp: base, pct5h: 0.0, pct7d: 0.0),
            UsageDataPoint(timestamp: base.addingTimeInterval(1), pct5h: 0.5, pct7d: 0.5),
            UsageDataPoint(timestamp: base.addingTimeInterval(2), pct5h: 1.0, pct7d: 1.0),
            UsageDataPoint(timestamp: base.addingTimeInterval(3), pct5h: 0.0, pct7d: 0.0),
        ]

        XCTAssertGreaterThan(
            UsageChartInterpolation.catmullRom(0.0, 0.5, 1.0, 0.0, t: 0.911),
            1
        )

        let interpolated = UsageChartInterpolation.interpolateValues(
            at: base.addingTimeInterval(1.911),
            in: points
        )

        XCTAssertEqual(interpolated?.pct5h, 1)
        XCTAssertEqual(interpolated?.pct7d, 1)
    }

    func testFiveHourIsNilBetweenPointsWithoutIt() throws {
        let base = Date(timeIntervalSince1970: 0)
        let points = [
            UsageDataPoint(timestamp: base, pct5h: 0.4, pct7d: 0.2),
            UsageDataPoint(timestamp: base.addingTimeInterval(1), pct5h: nil, pct7d: 0.3),
            UsageDataPoint(timestamp: base.addingTimeInterval(2), pct5h: nil, pct7d: 0.4),
        ]

        let interpolated = try XCTUnwrap(
            UsageChartInterpolation.interpolateValues(at: base.addingTimeInterval(1.5), in: points)
        )

        XCTAssertNil(interpolated.pct5h)
    }

    func testFiveHourInterpolatesNextToAGap() throws {
        let base = Date(timeIntervalSince1970: 0)
        let points = [
            UsageDataPoint(timestamp: base, pct5h: nil, pct7d: 0.2),
            UsageDataPoint(timestamp: base.addingTimeInterval(1), pct5h: 0.2, pct7d: 0.2),
            UsageDataPoint(timestamp: base.addingTimeInterval(2), pct5h: 0.4, pct7d: 0.2),
        ]

        let interpolated = try XCTUnwrap(
            UsageChartInterpolation.interpolateValues(at: base.addingTimeInterval(1.5), in: points)
        )

        XCTAssertEqual(try XCTUnwrap(interpolated.pct5h), 0.3, accuracy: 0.0001)
    }

    func testOutOfRangeHoverOmitsFiveHourWhenNoPointHasIt() throws {
        let base = Date(timeIntervalSince1970: 0)
        let points = [
            UsageDataPoint(timestamp: base, pct5h: nil, pct7d: 0.2),
            UsageDataPoint(timestamp: base.addingTimeInterval(1), pct5h: nil, pct7d: 0.3),
        ]

        let interpolated = try XCTUnwrap(
            UsageChartInterpolation.interpolateValues(at: base.addingTimeInterval(-5), in: points)
        )

        XCTAssertNil(interpolated.pct5h)
    }

    func testFiveHourRunsSplitAtGapsSoTheLineIsNotBridged() {
        let base = Date(timeIntervalSince1970: 0)
        let values: [Double?] = [0.1, 0.2, nil, nil, 0.3, nil, 0.4]
        let points = values.enumerated().map { i, value in
            UsageDataPoint(timestamp: base.addingTimeInterval(Double(i)), pct5h: value, pct7d: 0)
        }

        let runs = UsageChartInterpolation.fiveHourRuns(in: points)

        XCTAssertEqual(runs.map(\.pct), [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(runs.map(\.run), [0, 0, 1, 2])
    }

    func testFiveHourRunsIsEmptyWithoutAnyFiveHourData() {
        let points = [
            UsageDataPoint(timestamp: Date(timeIntervalSince1970: 0), pct5h: nil, pct7d: 0.5),
            UsageDataPoint(timestamp: Date(timeIntervalSince1970: 1), pct5h: nil, pct7d: 0.6),
        ]

        XCTAssertTrue(UsageChartInterpolation.fiveHourRuns(in: points).isEmpty)
    }
}
