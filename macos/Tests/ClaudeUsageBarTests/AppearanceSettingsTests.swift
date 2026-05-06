import XCTest
@testable import ClaudeUsageBar

/// Tests for appearance setting persistence and key stability.
///
/// Validates that the `AppearanceDefaultsKey` enum maintains stable keys for UserDefaults,
/// and that settings round-trip correctly (write → read returns same value).
/// Uses isolated UserDefaults suites to avoid polluting system defaults.
final class AppearanceSettingsTests: XCTestCase {

    func testKeyStringsAreStable() {
        XCTAssertEqual(AppearanceDefaultsKey.showResetDivider, "showResetDivider")
        XCTAssertEqual(AppearanceDefaultsKey.coloredResetDivider, "coloredResetDivider")
    }

    func testFreshSuiteShowResetDividerDefaultsToFalse() throws {
        let defaults = try makeIsolatedDefaults()
        XCTAssertNil(defaults.object(forKey: AppearanceDefaultsKey.showResetDivider))
        XCTAssertFalse(defaults.bool(forKey: AppearanceDefaultsKey.showResetDivider))
    }

    func testFreshSuiteColoredResetDividerHasNoStoredEntry() throws {
        let defaults = try makeIsolatedDefaults()
        XCTAssertNil(defaults.object(forKey: AppearanceDefaultsKey.coloredResetDivider))
    }

    func testRoundTripShowResetDivider() throws {
        let defaults = try makeIsolatedDefaults()

        defaults.set(true, forKey: AppearanceDefaultsKey.showResetDivider)
        XCTAssertTrue(defaults.bool(forKey: AppearanceDefaultsKey.showResetDivider))

        defaults.set(false, forKey: AppearanceDefaultsKey.showResetDivider)
        XCTAssertFalse(defaults.bool(forKey: AppearanceDefaultsKey.showResetDivider))
    }

    func testRoundTripColoredResetDivider() throws {
        let defaults = try makeIsolatedDefaults()

        defaults.set(true, forKey: AppearanceDefaultsKey.coloredResetDivider)
        XCTAssertTrue(defaults.bool(forKey: AppearanceDefaultsKey.coloredResetDivider))

        defaults.set(false, forKey: AppearanceDefaultsKey.coloredResetDivider)
        XCTAssertFalse(defaults.bool(forKey: AppearanceDefaultsKey.coloredResetDivider))
    }

    func testCustomSuiteDoesNotPolluteStandardDefaults() throws {
        let standardBefore = UserDefaults.standard
            .object(forKey: AppearanceDefaultsKey.showResetDivider)

        let defaults = try makeIsolatedDefaults()
        defaults.set(true, forKey: AppearanceDefaultsKey.showResetDivider)

        let standardAfter = UserDefaults.standard
            .object(forKey: AppearanceDefaultsKey.showResetDivider)

        XCTAssertTrue(equalObjects(standardBefore, standardAfter))
    }

    // MARK: - Service Status keys (DV-1.6)

    func testServiceStatusKeyStringsAreStable() {
        XCTAssertEqual(AppearanceDefaultsKey.showServiceStatus, "showServiceStatus")
        XCTAssertEqual(AppearanceDefaultsKey.showOverlayWhenOperational, "showOverlayWhenOperational")
        XCTAssertEqual(AppearanceDefaultsKey.statusPollMinutes, "statusPollMinutes")
        XCTAssertEqual(AppearanceDefaultsKey.statusComponentFilter, "statusComponentFilter")
    }

    func testFreshSuiteShowServiceStatusDefaultsToFalse() throws {
        let defaults = try makeIsolatedDefaults()
        XCTAssertNil(defaults.object(forKey: AppearanceDefaultsKey.showServiceStatus))
        XCTAssertFalse(defaults.bool(forKey: AppearanceDefaultsKey.showServiceStatus))
    }

    func testRoundTripShowServiceStatus() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(true, forKey: AppearanceDefaultsKey.showServiceStatus)
        XCTAssertTrue(defaults.bool(forKey: AppearanceDefaultsKey.showServiceStatus))
        defaults.set(false, forKey: AppearanceDefaultsKey.showServiceStatus)
        XCTAssertFalse(defaults.bool(forKey: AppearanceDefaultsKey.showServiceStatus))
    }

    func testStatusPollMinutesValidOptions() {
        XCTAssertEqual(StatusPollOptions.minutes, [1, 5, 15, 30])
        XCTAssertEqual(StatusPollOptions.default, 5)
    }

    func testStatusComponentFilterRoundTripJSON() throws {
        let defaults = try makeIsolatedDefaults()
        let original = StatusComponentFilter(substrings: ["foo", "Bar Baz"])
        StatusComponentFilterStore.save(original, to: defaults)

        let restored = StatusComponentFilterStore.load(from: defaults)
        XCTAssertEqual(restored, original)
    }

    func testStatusComponentFilterMissingDataReturnsDefault() throws {
        let defaults = try makeIsolatedDefaults()
        let loaded = StatusComponentFilterStore.load(from: defaults)
        XCTAssertEqual(loaded, .default)
    }

    func testStatusComponentFilterCorruptDataReturnsDefault() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(Data("not json".utf8), forKey: AppearanceDefaultsKey.statusComponentFilter)
        let loaded = StatusComponentFilterStore.load(from: defaults)
        XCTAssertEqual(loaded, .default)
    }

    // MARK: - Helpers

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "AppearanceSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func equalObjects(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (l?, r?):
            return (l as? NSObject) == (r as? NSObject)
        default:
            return false
        }
    }
}
