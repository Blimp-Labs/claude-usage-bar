import Foundation

/// Forward-looking projection of when the 5-hour usage window will reach 100%, based on
/// the recent burn rate. Pure and testable — no UI or service dependencies.
///
/// The rate is measured over the samples in a trailing window that tracks the user's poll
/// cadence: since one history point is recorded per poll, "recent samples" are naturally
/// spaced at the polling interval (5-min polling → ~5-min rate, 30-min polling → ~30-min rate).
struct UsageProjection: Equatable {
    enum Outcome: Equatable {
        /// Not enough samples, or no forward reset horizon, to compute a projection.
        case insufficientData
        /// Usage is flat/declining, or would only cross 100% after the window resets.
        case lastsUntilReset
        /// Usage is rising and is projected to reach 100% at this time, before the reset.
        case runsOut(at: Date)
    }

    let outcome: Outcome
    /// Change in the 0…1 fraction per second over the measured window (may be ≤ 0).
    let ratePerSecond: Double
    /// Current 5-hour usage as a 0…1 fraction, anchored to `now`.
    let currentPct: Double
    let now: Date
    let reset: Date?

    /// Computes a projection for the 5-hour window.
    ///
    /// - Parameters:
    ///   - points: recorded history samples (any order); only `pct5h`/`timestamp` are used.
    ///   - currentPct: the freshest 5h fraction (0…1), e.g. `UsageService.pct5h`.
    ///   - reset: when the 5h window next resets (`UsageService.reset5h`).
    ///   - pollingMinutes: the user's poll cadence; the rate window adapts to it.
    ///   - now: the reference "now".
    static func compute(
        points: [UsageDataPoint],
        currentPct: Double,
        reset: Date?,
        pollingMinutes: Int,
        now: Date = Date()
    ) -> UsageProjection {
        let base = min(max(currentPct, 0), 1)

        // Need at least two samples and a reset that lies in the future to draw a timeline.
        guard let reset, reset > now, points.count >= 2 else {
            return UsageProjection(outcome: .insufficientData, ratePerSecond: 0,
                                   currentPct: base, now: now, reset: reset)
        }

        let sorted = points.sorted { $0.timestamp < $1.timestamp }

        // Rate window tracks the poll cadence (min 5 min). Use the samples inside the trailing
        // window; if fewer than two land there, fall back to the last two samples overall.
        let window = TimeInterval(max(pollingMinutes, 5) * 60)
        let cutoff = now.addingTimeInterval(-window)
        var recent = sorted.filter { $0.timestamp >= cutoff }
        if recent.count < 2 {
            recent = Array(sorted.suffix(2))
        }

        guard let first = recent.first, let last = recent.last else {
            return UsageProjection(outcome: .insufficientData, ratePerSecond: 0,
                                   currentPct: base, now: now, reset: reset)
        }

        let span = last.timestamp.timeIntervalSince(first.timestamp)
        guard span > 0 else {
            return UsageProjection(outcome: .lastsUntilReset, ratePerSecond: 0,
                                   currentPct: base, now: now, reset: reset)
        }

        let rate = (last.pct5h - first.pct5h) / span

        // Anchor the current usage at `now` by extrapolating from the last sample, so the
        // graph's left edge reflects "now" rather than the last poll time. The projected
        // crossing time (below) is anchored to the last sample, so it stays fixed as `now`
        // advances between polls — the red line doesn't drift.
        let anchored = min(max(base + rate * now.timeIntervalSince(last.timestamp), 0), 1)

        // Flat or declining → the window simply resets before it fills.
        guard rate > 0 else {
            return UsageProjection(outcome: .lastsUntilReset, ratePerSecond: rate,
                                   currentPct: anchored, now: now, reset: reset)
        }

        let rawCrossing = last.timestamp.addingTimeInterval((1 - base) / rate)
        let crossing = max(rawCrossing, now)
        let outcome: Outcome = crossing >= reset ? .lastsUntilReset : .runsOut(at: crossing)

        return UsageProjection(outcome: outcome, ratePerSecond: rate,
                               currentPct: anchored, now: now, reset: reset)
    }
}
