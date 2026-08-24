import XCTest
@testable import ClaudeUsageBar

final class ResetLabelFormatterTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 0)

    private func date(after seconds: TimeInterval) -> Date {
        now.addingTimeInterval(seconds)
    }

    func testHoursAndMinutes() {
        let target = date(after: 3 * 3600 + 50 * 60)
        XCTAssertEqual(
            formatResetCountdown(from: target, now: now, calendar: resetLabelCalendar),
            "Resets in 3h 50m"
        )
    }

    func testDaysAndHours() {
        let target = date(after: 6 * 86400 + 17 * 3600)
        XCTAssertEqual(
            formatResetCountdown(from: target, now: now, calendar: resetLabelCalendar),
            "Resets in 6d 17h"
        )
    }

    func testSubHourMinutesOnly() {
        let target = date(after: 50 * 60)
        XCTAssertEqual(
            formatResetCountdown(from: target, now: now, calendar: resetLabelCalendar),
            "Resets in 50m"
        )
    }

    func testExactHourDropsZeroMinutes() {
        let target = date(after: 3 * 3600)
        XCTAssertEqual(
            formatResetCountdown(from: target, now: now, calendar: resetLabelCalendar),
            "Resets in 3h"
        )
    }

    func testPastDateYieldsResetting() {
        let target = date(after: -60)
        XCTAssertEqual(
            formatResetCountdown(from: target, now: now, calendar: resetLabelCalendar),
            "Resetting…"
        )
    }

    func testZeroDateYieldsResetting() {
        XCTAssertEqual(
            formatResetCountdown(from: now, now: now, calendar: resetLabelCalendar),
            "Resetting…"
        )
    }

    func testCalendarLocaleIsPinnedRegardlessOfSystemLocale() {
        let target = date(after: 3 * 3600 + 50 * 60)
        let viaDefault = formatResetCountdown(from: target, now: now)
        let viaExplicitPin = formatResetCountdown(from: target, now: now, calendar: resetLabelCalendar)
        XCTAssertEqual(viaDefault, viaExplicitPin)
        XCTAssertEqual(viaDefault, "Resets in 3h 50m")
    }
}
