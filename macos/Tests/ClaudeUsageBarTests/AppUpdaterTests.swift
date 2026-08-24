import XCTest
import Sparkle
@testable import ClaudeUsageBar

final class AppUpdaterTests: XCTestCase {
    func testNoUpdateFoundIsNotAnError() {
        let error = NSError(
            domain: SUSparkleErrorDomain,
            code: Int(SUError.noUpdateError.rawValue),
            userInfo: [NSLocalizedDescriptionKey: "You're up to date!"]
        )

        XCTAssertNil(AppUpdater.describe(error))
    }

    func testSuccessfulCycleClearsTheError() {
        XCTAssertNil(AppUpdater.describe(nil))
    }

    func testFeedFailureIsReported() {
        let error = NSError(
            domain: SUSparkleErrorDomain,
            code: Int(SUError.appcastError.rawValue),
            userInfo: [NSLocalizedDescriptionKey: "Update feed is unreachable"]
        )

        XCTAssertEqual(AppUpdater.describe(error), "Update feed is unreachable")
    }

    /// Code 1001 outside Sparkle's domain is somebody else's error.
    func testSameCodeInAnotherDomainIsStillReported() {
        let error = NSError(
            domain: NSURLErrorDomain,
            code: Int(SUError.noUpdateError.rawValue),
            userInfo: [NSLocalizedDescriptionKey: "Network is down"]
        )

        XCTAssertEqual(AppUpdater.describe(error), "Network is down")
    }

    func testBlankDescriptionFallsBackToSomethingUsable() {
        let error = NSError(
            domain: SUSparkleErrorDomain,
            code: Int(SUError.appcastError.rawValue),
            userInfo: [NSLocalizedDescriptionKey: "   "]
        )

        XCTAssertEqual(AppUpdater.describe(error), "Update check failed")
    }
}
