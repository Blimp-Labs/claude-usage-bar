import XCTest
@testable import ClaudeUsageBar

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
