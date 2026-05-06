import SwiftUI

/// Discrete state of the reset-time divider.
/// The four cases come from the PL0 colour matrix; rendering policy
/// (colored vs neutral) lives in `color(colored:)` so the enum stays pure.
enum ResetIndicatorState {
    case normal
    case warning
    case critical
    case inUsageLimit

    func color(colored: Bool) -> Color {
        guard colored else { return .secondary }
        return switch self {
        case .normal:       .secondary
        case .warning:      .orange
        case .critical:     .red
        case .inUsageLimit: .green
        }
    }
}

/// Maps usage% (0...100) and time-left fraction (0...1, where 1 == full window
/// remaining and 0 == reset is now) onto a `ResetIndicatorState`.
///
/// Thresholds:
/// - `highUsage`     when `usagePct >= 80`
/// - `lateInWindow`  when `timeLeftFraction <= 0.33`
func resetIndicatorState(usagePct: Double, timeLeftFraction: Double) -> ResetIndicatorState {
    let highUsage = usagePct >= 80.0
    let lateInWindow = timeLeftFraction <= 0.60
    return switch (highUsage, lateInWindow) {
    case (true,  true):  .critical
    case (true,  false):  .warning
    case (false, true):  .normal
    case (false, false): .inUsageLimit
    }
}

#if canImport(AppKit)
import AppKit

extension ResetIndicatorState {
    /// AppKit equivalent of `color(colored:)` for use by the menubar icon
    /// renderer. Mirrors the SwiftUI palette so popover and menubar visuals
    /// match.
    func nsColor(colored: Bool) -> NSColor {
        guard colored else { return .secondaryLabelColor }
        return switch self {
        case .normal:       .secondaryLabelColor
        case .warning:      .systemOrange
        case .critical:     .systemRed
        case .inUsageLimit: .green
        }
    }
}
#endif
