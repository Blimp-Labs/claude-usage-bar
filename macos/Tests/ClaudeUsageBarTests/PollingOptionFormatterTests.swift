import XCTest
@testable import ClaudeUsageBar

final class PollingOptionFormatterTests: XCTestCase {
    func testLocalizedPollingIntervalUsesExpectedCompactLabels() {
        let locale = Locale(identifier: "en_US_POSIX")

        XCTAssertEqual(localizedPollingInterval(for: 5, locale: locale), "5m")
        XCTAssertEqual(localizedPollingInterval(for: 15, locale: locale), "15m")
        XCTAssertEqual(localizedPollingInterval(for: 30, locale: locale), "30m")
        XCTAssertEqual(localizedPollingInterval(for: 60, locale: locale), "1h")
    }

    func testRecommendedPollingOptionsDoNotGetWarningSuffix() {
        let locale = Locale(identifier: "en_US_POSIX")

        XCTAssertEqual(pollingOptionLabel(for: 30, locale: locale), "30m")
        XCTAssertEqual(pollingOptionLabel(for: 60, locale: locale), "1h")
    }

    func testDiscouragedPollingOptionsUseLocalizedWarningSuffix() {
        let locale = Locale(identifier: "en_US_POSIX")

        XCTAssertEqual(pollingOptionLabel(for: 5, locale: locale), "5m (not recommended)")
        XCTAssertEqual(pollingOptionLabel(for: 15, locale: locale), "15m (not recommended)")
    }

    func testSupportedPollingOptionsAllProduceNonEmptyLabels() {
        let locale = Locale(identifier: "en_US_POSIX")
        let pollingOptions = [5, 15, 30, 60]

        for minutes in pollingOptions {
            XCTAssertFalse(pollingOptionLabel(for: minutes, locale: locale).isEmpty)
        }
    }

    func testDiscouragedPollingOptionsAreFlaggedSeparately() {
        XCTAssertTrue(isDiscouragedPollingOption(5))
        XCTAssertTrue(isDiscouragedPollingOption(15))
        XCTAssertFalse(isDiscouragedPollingOption(30))
        XCTAssertFalse(isDiscouragedPollingOption(60))
    }
}
