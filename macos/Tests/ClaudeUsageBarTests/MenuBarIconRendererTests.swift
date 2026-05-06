import XCTest
import AppKit
@testable import ClaudeUsageBar

final class MenuBarIconRendererTests: XCTestCase {

    private let expectedSize = NSSize(width: 56, height: 18)

    func testLegacyOverloadIsTemplate() {
        let image = renderIcon(pct5h: 0.5, pct7d: 0.5)
        XCTAssertTrue(image.isTemplate)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func testNewOverloadDividerOffIsTemplate() {
        let image = renderIcon(makeParams(showResetDivider: false, coloredResetDivider: false))
        XCTAssertTrue(image.isTemplate)
    }

    func testNewOverloadDividerOnMonochromeIsTemplate() {
        let image = renderIcon(makeParams(showResetDivider: true, coloredResetDivider: false))
        XCTAssertTrue(image.isTemplate)
    }

    func testNewOverloadDividerOnColoredDropsTemplate() {
        let image = renderIcon(makeParams(showResetDivider: true, coloredResetDivider: true))
        XCTAssertFalse(image.isTemplate)
    }

    func testColoredToggleAloneStaysTemplate() {
        // Colored on but divider off → still template (no divider drawn).
        let image = renderIcon(makeParams(showResetDivider: false, coloredResetDivider: true))
        XCTAssertTrue(image.isTemplate)
    }

    func testUnauthenticatedIconIsTemplate() {
        let image = renderUnauthenticatedIcon()
        XCTAssertTrue(image.isTemplate)
    }

    func testNilResetPositionsDoNotCrashWhenDividerOn() {
        let params = MenuBarIconParams(
            pct5h: 0.7, pct7d: 0.3,
            resetPos5h: nil, state5h: .normal,
            resetPos7d: nil, state7d: .warning,
            showResetDivider: true,
            coloredResetDivider: true
        )
        let image = renderIcon(params)
        // No divider drawn for either bar; image is still produced.
        XCTAssertFalse(image.isTemplate) // wantsColored is true
        XCTAssertEqual(image.size, expectedSize)
    }

func testAllVariantsHaveSameSize() {
        let variants: [(Bool, Bool)] = [(false, false), (false, true), (true, false), (true, true)]
        for (show, colored) in variants {
            let image = renderIcon(makeParams(showResetDivider: show, coloredResetDivider: colored))
            XCTAssertEqual(image.size, expectedSize, "size mismatch for show=\(show) colored=\(colored)")
        }
        XCTAssertEqual(renderIcon(pct5h: 0.5, pct7d: 0.5).size, expectedSize)
        XCTAssertEqual(renderUnauthenticatedIcon().size, expectedSize)
    }

    // MARK: - Helpers

    private func makeParams(showResetDivider: Bool, coloredResetDivider: Bool) -> MenuBarIconParams {
        MenuBarIconParams(
            pct5h: 0.6,
            pct7d: 0.2,
            resetPos5h: 0.5,
            state5h: .critical,
            resetPos7d: 0.25,
            state7d: .normal,
            showResetDivider: showResetDivider,
            coloredResetDivider: coloredResetDivider
        )
    }
}
