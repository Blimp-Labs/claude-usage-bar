import XCTest
import Sparkle
@testable import ClaudeUsageBar

final class AppUpdaterTests: XCTestCase {
    func testNoErrorMeansNoMessage() {
        XCTAssertNil(AppUpdater.describe(nil))
    }

    func testBenignSparkleOutcomesAreSilent() {
        for code in [SUError.noUpdateError, .installationCanceledError, .installationAuthorizeLaterError] {
            XCTAssertNil(AppUpdater.describe(makeError(code, description: "ignored")), "code \(code.rawValue)")
        }
    }

    func testBenignCodesFromAnotherDomainAreReported() {
        for code in [SUError.noUpdateError, .installationAuthorizeLaterError] {
            let error = makeError(code, description: "Network is down", domain: NSURLErrorDomain)
            XCTAssertEqual(AppUpdater.describe(error), "Network is down", "code \(code.rawValue)")
        }
    }

    func testCarriedDescriptionIsShown() {
        let error = makeError(.appcastError, description: "Update feed is unreachable")
        XCTAssertEqual(AppUpdater.describe(error), "Update feed is unreachable")
    }

    func testMissingOrBlankDescriptionFallsBack() {
        XCTAssertEqual(AppUpdater.describe(makeError(.appcastError)), "Update check failed")
        XCTAssertEqual(AppUpdater.describe(makeError(.appcastError, description: "   ")), "Update check failed")
    }

    func testRecoverySuggestionIsAppended() {
        let error = makeError(
            .runningFromDiskImageError,
            description: "ClaudeUsageBar can't be updated from a read-only location.",
            recovery: "Move it to the Applications folder and try again."
        )
        XCTAssertEqual(
            AppUpdater.describe(error),
            "ClaudeUsageBar can't be updated from a read-only location. Move it to the Applications folder and try again."
        )
    }

    func testOfflineBackgroundChecksAreIgnored() {
        for code in [NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost, NSURLErrorTimedOut] {
            let error = sparkleDownloadError(wrapping: code)
            XCTAssertTrue(AppUpdater.isOfflineBackgroundCheck(.updatesInBackground, error: error), "code \(code)")
        }
    }

    func testOfflineManualChecksAreStillReported() {
        let error = sparkleDownloadError(wrapping: NSURLErrorNotConnectedToInternet)
        XCTAssertFalse(AppUpdater.isOfflineBackgroundCheck(.updates, error: error))
    }

    func testOtherBackgroundFailuresAreStillReported() {
        XCTAssertFalse(AppUpdater.isOfflineBackgroundCheck(.updatesInBackground, error: nil))
        XCTAssertFalse(AppUpdater.isOfflineBackgroundCheck(
            .updatesInBackground,
            error: makeError(.appcastParseError, description: "Bad feed")
        ))
        XCTAssertFalse(AppUpdater.isOfflineBackgroundCheck(
            .updatesInBackground,
            error: sparkleDownloadError(wrapping: NSURLErrorBadServerResponse)
        ))
    }

    /// The shape Sparkle 2.8 produces: two download errors around the URL error.
    private func sparkleDownloadError(wrapping urlCode: Int) -> NSError {
        let urlError = NSError(domain: NSURLErrorDomain, code: urlCode)
        let download = NSError(
            domain: SUSparkleErrorDomain,
            code: Int(SUError.downloadError.rawValue),
            userInfo: [NSUnderlyingErrorKey: urlError]
        )
        return NSError(
            domain: SUSparkleErrorDomain,
            code: Int(SUError.downloadError.rawValue),
            userInfo: [NSUnderlyingErrorKey: download]
        )
    }

    private func makeError(
        _ code: SUError,
        description: String? = nil,
        recovery: String? = nil,
        domain: String = SUSparkleErrorDomain
    ) -> NSError {
        var userInfo: [String: Any] = [:]
        userInfo[NSLocalizedDescriptionKey] = description
        userInfo[NSLocalizedRecoverySuggestionErrorKey] = recovery
        return NSError(domain: domain, code: Int(code.rawValue), userInfo: userInfo.isEmpty ? nil : userInfo)
    }
}
