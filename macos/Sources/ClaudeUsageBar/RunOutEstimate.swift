import Foundation

/// Forward-looking estimate of whether the 5-hour usage window will reach 100 % before it
/// resets, and if so, when. Pure and testable — no UI or service dependencies.
///
/// Unlike a from-scratch burn-rate calculation, this reuses `UsageForecast.velocity5h`
/// (from `UsageForecastService`'s adaptive weighted-regression ensemble) as the rate input,
/// so it inherits that model's reset-drop attenuation and noise smoothing rather than
/// re-deriving a rate from raw samples.
struct RunOutEstimate: Equatable {
    enum Outcome: Equatable {
        /// No forecast, low-confidence forecast, or no forward reset horizon to project onto.
        case insufficientData
        /// Usage is flat/declining, or would only cross 100 % after the window resets.
        case lastsUntilReset
        /// Usage is rising and is projected to reach 100 % at this time, before the reset.
        case runsOut(at: Date)
    }

    /// Minimum forecast confidence required to trust `velocity5h` enough to project from it.
    static let minConfidence: Double = 0.1

    let outcome: Outcome
    /// `forecast.velocity5h` (%/hour), copied through for the chart to draw the trajectory.
    let ratePerHour: Double
    /// Current 5-hour usage as a 0…100 percentage, anchored (extrapolated) to `now`.
    let currentPct: Double
    let now: Date
    let reset: Date?

    /// Computes a run-out estimate for the 5-hour window.
    ///
    /// - Parameters:
    ///   - forecast: latest `UsageForecast` (only `velocity5h`/`confidence5h` are used).
    ///   - anchorPct: the freshest measured 5h percentage (0…100), e.g. `service.pct5h * 100`.
    ///   - anchorTime: when `anchorPct` was measured, e.g. `service.lastUpdated`.
    ///   - reset: when the 5h window next resets (`service.reset5h`).
    ///   - now: the reference "now" (may be later than `anchorTime`; the estimate
    ///     extrapolates `anchorPct` forward at `velocity5h` so the marker stays live
    ///     between polls).
    static func compute(
        forecast: UsageForecast?,
        anchorPct: Double,
        anchorTime: Date,
        reset: Date?,
        now: Date = Date()
    ) -> RunOutEstimate {
        let base = anchorPct.clamped(to: 0...100)

        guard let forecast, forecast.confidence5h >= minConfidence,
              let reset, reset > now else {
            return RunOutEstimate(outcome: .insufficientData, ratePerHour: 0,
                                   currentPct: base, now: now, reset: reset)
        }

        let rate = forecast.velocity5h
        let hoursSinceAnchor = now.timeIntervalSince(anchorTime) / 3600
        let anchored = (base + rate * hoursSinceAnchor).clamped(to: 0...100)

        // Flat or declining → the window simply resets before it fills.
        guard rate > 0 else {
            return RunOutEstimate(outcome: .lastsUntilReset, ratePerHour: rate,
                                   currentPct: anchored, now: now, reset: reset)
        }

        let rawCrossing = anchorTime.addingTimeInterval((100 - base) / rate * 3600)
        let crossing = max(rawCrossing, now)
        let outcome: Outcome = crossing >= reset ? .lastsUntilReset : .runsOut(at: crossing)

        return RunOutEstimate(outcome: outcome, ratePerHour: rate,
                               currentPct: anchored, now: now, reset: reset)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
