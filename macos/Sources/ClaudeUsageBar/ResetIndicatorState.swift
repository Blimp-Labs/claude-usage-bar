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
        guard colored else { return Color.secondary }
        switch self {
        case .normal:       return Color.secondary
        case .warning:      return Color.orange
        case .critical:     return Color(red: 0.95, green: 0.45, blue: 0.10)
        case .inUsageLimit: return Color.red
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
    let lateInWindow = timeLeftFraction <= 0.33
    switch (highUsage, lateInWindow) {
    case (true,  true):  return .inUsageLimit
    case (true,  false): return .critical
    case (false, true):  return .warning
    case (false, false): return .normal
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
        switch self {
        case .normal:       return .secondaryLabelColor
        case .warning:      return .systemOrange
        case .critical:     return NSColor(red: 0.95, green: 0.45, blue: 0.10, alpha: 1.0)
        case .inUsageLimit: return .systemRed
        }
    }
}
#endif
