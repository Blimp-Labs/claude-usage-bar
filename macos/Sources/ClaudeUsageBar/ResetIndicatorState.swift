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
        case .warning:      .yellow
        case .critical:     .orange
        case .inUsageLimit: .green
        }
    }
}

/// Usage% threshold for "high usage" when judged by current, already-observed
/// utilization (no forecast available).
private let currentUsageHighThreshold = 80.0

/// Usage% threshold for "high usage" when judged by a *projected* end-of-window
/// utilization instead. Lower than the current-usage threshold: a projection
/// heading toward the cap should read as escalated earlier than raw current
/// usage would, since by the time current usage itself reaches 80% the window
/// may already be effectively exhausted. Matches the warn line used elsewhere
/// for projection-driven severity (e.g. claude-code-usage-bar's
/// PROJECTION_WARNING_THRESHOLD).
private let projectedUsageHighThreshold = 70.0

/// Maps usage% (0...100) and time-left fraction (0...1, where 1 == full window
/// remaining and 0 == reset is now) onto a `ResetIndicatorState`.
///
/// - Parameters:
///   - usagePct: Current, already-observed utilization (0...100).
///   - timeLeftFraction: Fraction of the window remaining (0...1).
///   - projectedPct: Optional projected end-of-window utilization (0...100).
///     When present, this drives the "high usage" check instead of `usagePct`
///     — the indicator reflects where usage is HEADED, not just where it is
///     right now — using a lower, earlier-warning threshold appropriate to a
///     forward-looking estimate. `nil` (no forecast yet, or forecast disabled)
///     falls back to the unchanged current-usage behavior.
///
/// Thresholds:
/// - `highUsage`     when the effective pct >= 80 (current) or >= 70 (projected)
/// - `lateInWindow`  when `timeLeftFraction <= 0.33`
func resetIndicatorState(
    usagePct: Double,
    timeLeftFraction: Double,
    projectedPct: Double? = nil
) -> ResetIndicatorState {
    let highUsage: Bool
    if let projectedPct {
        highUsage = projectedPct >= projectedUsageHighThreshold
    } else {
        highUsage = usagePct >= currentUsageHighThreshold
    }
    let lateInWindow = timeLeftFraction <= 0.33
    return switch (highUsage, lateInWindow) {
    case (false, false): .normal
    case (false, true):  .warning
    case (true,  false): .critical
    case (true,  true):  .inUsageLimit
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
        case .warning:      .systemYellow
        case .critical:     .systemOrange
        case .inUsageLimit: .systemGreen
        }
    }
}
#endif
