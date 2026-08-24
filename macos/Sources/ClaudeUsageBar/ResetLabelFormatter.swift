import Foundation

/// Calendar pinned to Gregorian/`en_US` so `DateComponentsFormatter`'s `.abbreviated` unit
/// strings ("d", "h", "m") are deterministic regardless of the user's system locale or the
/// CI runner's locale.
let resetLabelCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US")
    return calendar
}()

/// Two-unit "Resets in Xh Ym" / "Resets in Xd Yh" formatting, built on
/// `DateComponentsFormatter` instead of `Text(date, style: .relative)` so it can be driven by
/// an explicit `now` snapshot rather than SwiftUI's continuously re-rendering display-link.
///
/// - Non-future/past/zero `date` yields exactly `"Resetting…"`, never a negative duration.
/// - Zero-value units are dropped, so an exact hour reads "Resets in 3h", not "Resets in 3h 0m".
func formatResetCountdown(from date: Date, now: Date, calendar: Calendar = resetLabelCalendar) -> String {
    guard date > now else { return "Resetting…" }

    let formatter = DateComponentsFormatter()
    formatter.calendar = calendar
    formatter.allowedUnits = [.day, .hour, .minute]
    formatter.maximumUnitCount = 2
    formatter.unitsStyle = .abbreviated
    formatter.zeroFormattingBehavior = .dropAll

    let interval = date.timeIntervalSince(now)
    guard let formatted = formatter.string(from: interval) else {
        return "Resetting…"
    }
    return "Resets in " + formatted
}
