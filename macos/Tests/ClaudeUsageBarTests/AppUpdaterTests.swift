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

    /// Sparkle constructs these with `userInfo: nil`, so `localizedDescription`
    /// is Foundation's synthesised debug string. Rendering it would put
    /// "The operation couldn't be completed. (SUSparkleErrorDomain error 4010.)"
    /// in the popover, in red.
    func testErrorsWithoutADescriptionDoNotLeakDebugText() {
        let error = NSError(
            domain: SUSparkleErrorDomain,
            code: Int(SUError.appcastError.rawValue),
            userInfo: nil
        )

        let described = AppUpdater.describe(error)
        XCTAssertEqual(described, "Update check failed")
        XCTAssertFalse(described?.contains("couldn") ?? false)
        XCTAssertFalse(described?.contains("SUSparkleErrorDomain") ?? false)
    }

    func testBlankDescriptionFallsBackToSomethingUsable() {
        let error = NSError(
            domain: SUSparkleErrorDomain,
            code: Int(SUError.appcastError.rawValue),
            userInfo: [NSLocalizedDescriptionKey: "   "]
        )

        XCTAssertEqual(AppUpdater.describe(error), "Update check failed")
    }

    /// Sparkle declines to log or surface these three. The last one fires with
    /// no user action at all: an app in /Applications whose automatic check
    /// needs admin rights it cannot ask for, so it defers.
    func testEveryBenignSparkleOutcomeIsSuppressed() {
        let benign: [(String, SUError)] = [
            ("no update", .noUpdateError),
            ("user dismissed the admin prompt", .installationCanceledError),
            ("deferred, needs authorization later", .installationAuthorizeLaterError)
        ]

        for (label, code) in benign {
            let error = NSError(
                domain: SUSparkleErrorDomain,
                code: Int(code.rawValue),
                userInfo: nil
            )
            XCTAssertNil(AppUpdater.describe(error), "should be silent: \(label)")
        }
    }

    func testBenignCodesFromAnotherDomainAreStillReported() {
        let error = NSError(
            domain: NSURLErrorDomain,
            code: Int(SUError.installationAuthorizeLaterError.rawValue),
            userInfo: [NSLocalizedDescriptionKey: "Not Sparkle's error"]
        )

        XCTAssertEqual(AppUpdater.describe(error), "Not Sparkle's error")
    }
}
