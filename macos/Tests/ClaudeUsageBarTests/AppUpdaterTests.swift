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
