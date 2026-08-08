import Foundation

// MARK: - Output

/// Forecast of near-future utilization for both Claude rolling-window metrics.
///
/// All utilization projections (`projected*`, `*Bound*`) are percentages in 0…100,
/// matching the `UsageBucket.utilization` scale returned by the API.
/// Velocity is in %/hour; acceleration is in %/hour².
struct UsageForecast {
    /// Smoothed and extrapolated 5-hour utilization at the forecast horizon.
    let projected5h: Double
    /// Smoothed and extrapolated 7-day utilization at the forecast horizon.
    let projected7d: Double

    /// Lower bound of the 90 % prediction interval for the 5-hour forecast.
    let lowerBound5h: Double
    /// Upper bound of the 90 % prediction interval for the 5-hour forecast.
    let upperBound5h: Double

    /// Lower bound of the 90 % prediction interval for the 7-day forecast.
    let lowerBound7d: Double
    /// Upper bound of the 90 % prediction interval for the 7-day forecast.
    let upperBound7d: Double

    /// Instantaneous rate of change of 5-hour utilization, positive = increasing. (%/hour)
    let velocity5h: Double
    /// Instantaneous rate of change of 7-day utilization, positive = increasing. (%/hour)
    let velocity7d: Double

    /// Rate of change of `velocity5h`. (%/hour²)
    let acceleration5h: Double
    /// Rate of change of `velocity7d`. (%/hour²)
    let acceleration7d: Double

    /// Forecast reliability for the 5-hour metric: 0 = unreliable, 1 = high confidence.
    let confidence5h: Double
    /// Forecast reliability for the 7-day metric: 0 = unreliable, 1 = high confidence.
    let confidence7d: Double

    /// Characteristic memory horizon (seconds) of the model that produced the 5-hour forecast.
    let effectiveWindow5h: TimeInterval
    /// Characteristic memory horizon (seconds) of the model that produced the 7-day forecast.
    let effectiveWindow7d: TimeInterval
}

// MARK: - Service

/// Adaptive weighted regression forecast engine for Claude usage metrics.
///
/// ## Architecture
///
/// The pipeline for each metric (5h, 7d) runs through five stages:
///
///   1. **Preprocessing** – extracts history samples, converts fractions to
///      percent, ages them in hours, and attenuates samples recorded before a
///      detected rolling-window reset drop.
///
///   2. **Adaptive λ** – estimates signal volatility from a quick first-pass
///      regression and adjusts the exponential decay constant so that memory
///      shortens when the signal changes rapidly and lengthens when it is stable.
///
///   3. **WLS regression** – fits `y = α + β·t` (linear) and `y = α + β·t + γ·t²`
///      (quadratic) using exponentially-decaying weights. `t` is hours from now,
///      so `α` is the current smoothed estimate, `β` is velocity, and `2γ` is
///      acceleration.
///
///   4. **Head / Tail ensemble** – runs two separate models at different memory
///      horizons (head: aggressive, τ ≈ 20 min; tail: conservative, τ ≈ 8 h)
///      and blends them with a smooth sigmoid whose mixing ratio is driven by
///      an instability score derived from velocity, acceleration, and noise.
///
///   5. **Confidence** – combines regression R², effective data density, and a
///      stability penalty into a single 0…1 score.
///
/// All computation is pure (no side effects, injectable `now`) for easy testing.
final class UsageForecastService {

    // -------------------------------------------------------------------------
    // MARK: Configuration
    // -------------------------------------------------------------------------

    /// Characteristic decay time (hours) for the tail (conservative) model.
    /// τ_tail = 8 h → λ_tail = 0.125 /h.  A sample from 8 hours ago has weight e⁻¹ ≈ 0.37.
    private static let tauTailHours: Double = 8.0

    /// Characteristic decay time (hours) for the head (aggressive) model.
    /// τ_head = 1/3 h = 20 min → λ_head = 3.0 /h.  Samples older than ~1 h are negligible.
    private static let tauHeadHours: Double = 1.0 / 3.0

    /// Lookahead horizon for the 5-hour forecast (seconds).
    /// 1 hour = 20 % of the 5-hour window; meaningful but not over-speculative.
    static let horizon5hSeconds: TimeInterval = 3600

    /// Lookahead horizon for the 7-day forecast (seconds).
    /// 4 hours ≈ 2.4 % of the 7-day window; captures slow-moving trends.
    static let horizon7dSeconds: TimeInterval = 4 * 3600

    /// Minimum sample count for a statistically meaningful regression.
    private static let minSamples: Int = 3

    /// A utilization drop larger than this (%) between consecutive samples is
    /// treated as a rolling-window expiry event.  Pre-drop samples are attenuated
    /// to prevent them from anchoring the regression to a now-irrelevant regime.
    private static let dropResetThreshold: Double = 20.0

    /// Weight multiplier applied to samples recorded before a detected reset drop.
    /// 0.15 ≈ 2.6 additional equivalent hours of age (at λ_tail ≈ 0.125 /h).
    private static let preDropWeightMultiplier: Double = 0.15

    // -------------------------------------------------------------------------
    // MARK: Public API
    // -------------------------------------------------------------------------

    /// Produce a forecast from persisted usage history and the current API response.
    ///
    /// - Parameters:
    ///   - history: `UsageHistory` from `UsageHistoryService` (pct values in 0–1).
    ///   - current: Most recent `UsageResponse` from the polling API.
    ///   - now:     Injection point for deterministic testing; defaults to `Date()`.
    func forecast(
        history: UsageHistory,
        current: UsageResponse,
        now: Date = Date()
    ) -> UsageForecast {

        let ch5h = computeChannel(
            history: history,
            historyKeyPath: \.pct5h,
            currentUtilization: current.fiveHour?.utilization,
            horizon: Self.horizon5hSeconds,
            tauHead: Self.tauHeadHours,
            tauTail: Self.tauTailHours,
            now: now
        )

        let ch7d = computeChannel(
            history: history,
            historyKeyPath: \.pct7d,
            currentUtilization: current.sevenDay?.utilization,
            horizon: Self.horizon7dSeconds,
            tauHead: Self.tauHeadHours,
            tauTail: Self.tauTailHours,
            now: now
        )

        func predictionInterval(_ ch: ChannelResult) -> (lower: Double, upper: Double) {
            // 90 % prediction interval: ±1.645σ.  The band is divided by confidence
            // so that low-confidence forecasts produce wider intervals automatically.
            // At confidence = 1.0 the band is ±1.645σ; at confidence = 0.2 it is ±8.2σ.
            let halfWidth = ch.residualStd * 1.645 / max(0.1, ch.confidence)
            return (
                (ch.projected - halfWidth).clamped(to: 0...100),
                (ch.projected + halfWidth).clamped(to: 0...100)
            )
        }

        let iv5h = predictionInterval(ch5h)
        let iv7d = predictionInterval(ch7d)

        return UsageForecast(
            projected5h:    ch5h.projected.clamped(to: 0...100),
            projected7d:    ch7d.projected.clamped(to: 0...100),
            lowerBound5h:   iv5h.lower,
            upperBound5h:   iv5h.upper,
            lowerBound7d:   iv7d.lower,
            upperBound7d:   iv7d.upper,
            velocity5h:     ch5h.velocity,
            velocity7d:     ch7d.velocity,
            acceleration5h: ch5h.acceleration,
            acceleration7d: ch7d.acceleration,
            confidence5h:   ch5h.confidence,
            confidence7d:   ch7d.confidence,
            effectiveWindow5h: ch5h.effectiveWindow,
            effectiveWindow7d: ch7d.effectiveWindow
        )
    }
}

// -------------------------------------------------------------------------
// MARK: Internal Types
// -------------------------------------------------------------------------

private extension UsageForecastService {

    /// A preprocessed, age-weighted observation.
    struct Sample {
        /// Time from now in hours; always ≤ 0 (past).  `t = 0` is the current moment.
        let t: Double
        /// Utilization in percent (0–100).
        let value: Double
        /// Extra weight scaling on top of the exponential decay.
        /// Set to `preDropWeightMultiplier` for samples before a detected reset drop;
        /// 1.0 otherwise.  This is lambda-independent, unlike shifting `t`.
        let weightMultiplier: Double

        /// Age in hours (≥ 0).  Used to compute `exp(-λ · age)`.
        var age: Double { -t }
    }

    /// Result of a 2-parameter weighted least-squares fit:  y = α + β·t.
    struct LinearFit {
        /// Estimated utilization at t = 0 (right now), %.
        let alpha: Double
        /// Slope: rate of change at t = 0, %/hour.  Positive = utilization is rising.
        let beta: Double
        /// Coefficient of determination (0–1).  Higher = better fit.
        let rSquared: Double
        /// Weighted mean-squared residual, %².  Square-root gives residual std.
        let residualVariance: Double
        /// Effective sample count: (Σw)² / Σ(w²).  Accounts for downweighting.
        let effectiveN: Double
    }

    /// Result of a 3-parameter weighted least-squares fit:  y = α + β·t + γ·t².
    struct QuadraticFit {
        /// Estimated utilization at t = 0, %.
        let alpha: Double
        /// Velocity at t = 0: dy/dt |_{t=0} = β, %/hour.
        let beta: Double
        /// Half-curvature coefficient.  Acceleration = 2γ, %/hour².
        let gamma: Double
        /// `false` when the 3×3 system was (near-)singular; model falls back to linear.
        let valid: Bool

        var acceleration: Double { 2.0 * gamma }  // %/hour²
    }

    /// Fully-blended result for one usage channel (5h or 7d).
    struct ChannelResult {
        let projected: Double          // %
        let velocity: Double           // %/hour
        let acceleration: Double       // %/hour²
        let confidence: Double         // 0…1
        let effectiveWindow: TimeInterval  // seconds
        let residualStd: Double        // %
    }
}

// -------------------------------------------------------------------------
// MARK: Pipeline
// -------------------------------------------------------------------------

private extension UsageForecastService {

    /// Run the full forecast pipeline for one utilization channel.
    func computeChannel(
        history: UsageHistory,
        historyKeyPath: KeyPath<UsageDataPoint, Double>,
        currentUtilization: Double?,
        horizon: TimeInterval,
        tauHead: Double,
        tauTail: Double,
        now: Date
    ) -> ChannelResult {

        let samples = preprocessSamples(
            history: history,
            historyKeyPath: historyKeyPath,
            currentUtilization: currentUtilization,
            now: now
        )

        // Degenerate case: too few samples for meaningful regression.
        guard samples.count >= Self.minSamples else {
            let value = (currentUtilization ?? 0).clamped(to: 0...100)
            let tau   = (tauHead + tauTail) / 2
            return ChannelResult(
                projected:       value,
                velocity:        0,
                acceleration:    0,
                confidence:      max(0.05, Double(samples.count) * 0.03),
                effectiveWindow: tau * 3600,
                residualStd:     max(1.0, value * 0.1)
            )
        }

        let horizonHours = horizon / 3600

        // --- Head model: aggressive, short-memory, tracks recent spikes ---
        let lambdaHead = adaptLambda(base: 1.0 / tauHead, samples: samples)
        let head = fitAndProject(samples: samples, lambda: lambdaHead, horizonHours: horizonHours)

        // --- Tail model: conservative, long-memory, anchors to sustained trend ---
        let lambdaTail = adaptLambda(base: 1.0 / tauTail, samples: samples)
        let tail = fitAndProject(samples: samples, lambda: lambdaTail, horizonHours: horizonHours)

        // --- Ensemble blend via smooth sigmoid ---
        // Instability score from the head model (more sensitive to recent changes).
        // At instability ≈ 0 the tail dominates (sigmoid ≈ 0.1).
        // At instability ≈ 2 the head dominates (sigmoid ≈ 0.88).
        // Midpoint at instability = 1.0, steepness = 3: the transition spans roughly
        // [0.2, 1.8] and avoids any hard threshold.
        let instability = computeInstabilityScore(
            velocity:     head.velocity,
            acceleration: head.acceleration,
            residualStd:  head.residualStd
        )
        let w = sigmoid(instability, midpoint: 1.0, steepness: 3.0)

        let projected    = w * head.projected    + (1 - w) * tail.projected
        let velocity     = w * head.velocity     + (1 - w) * tail.velocity
        let acceleration = w * head.acceleration + (1 - w) * tail.acceleration
        let residualStd  = w * head.residualStd  + (1 - w) * tail.residualStd

        // Blend confidences from both models. Velocity/acceleration-driven volatility is
        // already penalized once per-model via `computeConfidence`'s stabilityComponent;
        // stacking a second instability-based penalty here would double-punish exactly the
        // fast, clean trend a run-out warning most needs to surface, without adding any
        // protection against genuine noise (already captured per-model via R²).
        let confidence = (w * head.confidence + (1 - w) * tail.confidence).clamped(to: 0...1)

        // Effective memory horizon from the blended decay constant.
        let lambdaBlended  = w * lambdaHead + (1 - w) * lambdaTail
        let effectiveWindow = (1.0 / max(lambdaBlended, 1e-6)) * 3600  // hours⁻¹ → seconds

        return ChannelResult(
            projected:       projected,
            velocity:        velocity,
            acceleration:    acceleration,
            confidence:      confidence,
            effectiveWindow: effectiveWindow,
            residualStd:     residualStd
        )
    }

    // -------------------------------------------------------------------------
    // MARK: Stage 1 – Preprocessing
    // -------------------------------------------------------------------------

    /// Build a sorted, scaled sample array from raw history and the current reading.
    ///
    /// Steps:
    ///   1. Convert history `pct` values (stored as 0–1 fractions) to percent.
    ///   2. Append the current API utilization as the freshest sample at t = 0.
    ///   3. Drop samples older than 7 days (beyond even the tail's lookback).
    ///   4. Sort chronologically (oldest first, t most negative → t = 0).
    ///   5. Detect rolling-window reset drops and attenuate pre-drop samples via
    ///      `weightMultiplier`; this isolates the regression to the post-reset regime.
    func preprocessSamples(
        history: UsageHistory,
        historyKeyPath: KeyPath<UsageDataPoint, Double>,
        currentUtilization: Double?,
        now: Date
    ) -> [Sample] {

        let maxLookbackHours: Double = 7.0 * 24.0

        // Collect raw (t_hours, value_pct) tuples from the persisted history.
        var rawPairs: [(t: Double, value: Double)] = history.dataPoints.compactMap { point in
            let ageHours = now.timeIntervalSince(point.timestamp) / 3600.0
            guard ageHours >= 0, ageHours <= maxLookbackHours else { return nil }
            return (-ageHours, point[keyPath: historyKeyPath] * 100.0)  // fraction → %
        }

        // Inject the current API reading as a sample exactly at t = 0.
        if let u = currentUtilization {
            rawPairs.append((0.0, u.clamped(to: 0...100)))
        }

        guard !rawPairs.isEmpty else { return [] }

        rawPairs.sort { $0.t < $1.t }  // oldest (most negative t) first

        // --- Rolling-window reset detection ---
        //
        // Claude's utilization windows are rolling: old usage falls out of the
        // window progressively.  A sharp downward jump — larger than
        // `dropResetThreshold` % between consecutive samples — typically marks
        // the moment a cluster of old high-usage requests aged out.
        //
        // After such an event the prior trend is misleading: if we kept
        // pre-drop samples at full weight, the regression would fit a phantom
        // downtrend and underestimate utilization.
        //
        // Strategy: find the most recent drop event and multiply the weight of
        // all samples recorded before it by `preDropWeightMultiplier`.  We use
        // the most recent drop (not the first) to handle multiple partial resets.
        var dropBoundaryIndex: Int? = nil
        for i in 1 ..< rawPairs.count {
            let delta = rawPairs[i].value - rawPairs[i - 1].value
            if delta < -Self.dropResetThreshold {
                dropBoundaryIndex = i  // update to always use the latest drop
            }
        }

        return rawPairs.enumerated().map { idx, pair in
            let multiplier: Double
            if let boundary = dropBoundaryIndex, idx < boundary {
                multiplier = Self.preDropWeightMultiplier
            } else {
                multiplier = 1.0
            }
            return Sample(t: pair.t, value: pair.value, weightMultiplier: multiplier)
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Stage 2 – Adaptive λ
    // -------------------------------------------------------------------------

    /// Adapt the exponential decay constant based on the signal's current volatility.
    ///
    /// Algorithm:
    ///   1. Run a quick first-pass regression at `base` λ.
    ///   2. Compute an instability score from velocity, acceleration, and residual noise.
    ///   3. Scale λ by `exp(instability / 2)`:
    ///        - stable   (instability → 0): scale ≈ 1.0  → memory unchanged
    ///        - moderate (instability = 1): scale ≈ 1.65 → 65 % shorter memory
    ///        - volatile (instability = 2): scale ≈ 2.7  → 2.7× shorter memory
    ///   4. Clamp to [0.5×, 20×] base to prevent pathological forgetting or over-retention.
    func adaptLambda(base lambda0: Double, samples: [Sample]) -> Double {
        let linearFit = weightedLinearRegression(samples: samples, lambda: lambda0)
        let quadFit   = weightedQuadraticRegression(samples: samples, lambda: lambda0, linearFallback: linearFit)

        let instability = computeInstabilityScore(
            velocity:     quadFit.valid ? quadFit.beta        : linearFit.beta,
            acceleration: quadFit.valid ? quadFit.acceleration : 0,
            residualStd:  sqrt(max(0, linearFit.residualVariance))
        )

        let scale = exp(instability / 2.0).clamped(to: 0.5...20.0)
        return lambda0 * scale
    }

    // -------------------------------------------------------------------------
    // MARK: Stage 3 – Fit & Project
    // -------------------------------------------------------------------------

    /// Fit both linear and quadratic WLS models, extrapolate to `horizonHours`,
    /// and return the blended result with velocity, acceleration, and confidence.
    func fitAndProject(samples: [Sample], lambda: Double, horizonHours: Double) -> ChannelResult {
        let linear = weightedLinearRegression(samples: samples, lambda: lambda)
        let quad   = weightedQuadraticRegression(samples: samples, lambda: lambda, linearFallback: linear)

        // Extrapolate each model to the forecast horizon.
        let h = horizonHours
        let projLinear = linear.alpha + linear.beta * h
        let projQuad   = quad.valid
            ? quad.alpha + quad.beta * h + quad.gamma * h * h
            : projLinear

        // Blend linear and quadratic projections, weighting quadratic conservatively.
        // The quadratic contribution grows with R² (better fit = more curvature trusted)
        // but is capped at 35 % to avoid overfitting, especially with sparse data.
        // With only 3 samples the quadratic nearly passes through every point, making
        // its extrapolation unreliable beyond a short horizon.
        let quadWeight = (linear.rSquared * 0.35).clamped(to: 0...0.35)
        let projected  = (1 - quadWeight) * projLinear + quadWeight * projQuad

        // Velocity and acceleration from the quadratic when it converged.
        let velocity     = quad.valid ? quad.beta        : linear.beta
        let acceleration = quad.valid ? quad.acceleration : 0.0

        let confidence = computeConfidence(linearFit: linear, velocity: velocity, acceleration: acceleration)
        let residualStd = sqrt(max(0, linear.residualVariance))

        let effectiveWindow = (1.0 / max(lambda, 1e-6)) * 3600  // hours⁻¹ → seconds

        return ChannelResult(
            projected:       projected,
            velocity:        velocity,
            acceleration:    acceleration,
            confidence:      confidence,
            effectiveWindow: effectiveWindow,
            residualStd:     residualStd
        )
    }

    // -------------------------------------------------------------------------
    // MARK: WLS Linear Regression:  y = α + β·t
    // -------------------------------------------------------------------------

    /// Weighted least-squares linear regression with exponential sample weights.
    ///
    /// **Weight for sample i:**
    ///   w_i = exp(−λ · age_i) · weightMultiplier_i
    ///   where age_i = −t_i ≥ 0 (hours since sample was recorded).
    ///
    /// **WLS normal equations** (Σ denotes weighted sum):
    ///
    ///   ┌ Σw    Σwt  ┐ ┌ α ┐   ┌ Σwy  ┐
    ///   │             │ │   │ = │      │
    ///   └ Σwt   Σwt² ┘ └ β ┘   └ Σwty ┘
    ///
    /// **Closed-form solution (Cramer's rule):**
    ///   det = Σw · Σwt² − (Σwt)²
    ///   α   = (Σwy · Σwt² − Σwty · Σwt) / det
    ///   β   = (Σw  · Σwty − Σwt  · Σwy) / det
    ///
    /// When det ≈ 0 (all samples at the same time-point, or a single sample)
    /// the system is singular; we fall back to the weighted mean with zero slope.
    ///
    /// **Interpretation:**
    ///   - α: smoothed utilization estimate *right now* (t = 0), %.
    ///   - β: instantaneous velocity at t = 0, %/hour.
    func weightedLinearRegression(samples: [Sample], lambda: Double) -> LinearFit {
        var Sw   = 0.0, Swt = 0.0, Swtt = 0.0
        var Swy  = 0.0, Swty = 0.0
        var Sw2  = 0.0  // Σw² for effective-N calculation

        for s in samples {
            let w  = exp(-lambda * s.age) * s.weightMultiplier
            let t  = s.t
            let y  = s.value
            Sw   += w
            Swt  += w * t
            Swtt += w * t * t
            Swy  += w * y
            Swty += w * t * y
            Sw2  += w * w
        }

        guard Sw > 1e-12 else {
            return LinearFit(alpha: 0, beta: 0, rSquared: 0, residualVariance: 0, effectiveN: 0)
        }

        let det = Sw * Swtt - Swt * Swt

        let alpha: Double
        let beta: Double
        if abs(det) < 1e-10 {
            // Singular (e.g. all samples at the same t).  Weighted mean, zero slope.
            alpha = Swy / Sw
            beta  = 0
        } else {
            alpha = (Swy * Swtt - Swty * Swt) / det
            beta  = (Sw  * Swty - Swt  * Swy) / det
        }

        // --- Goodness of fit ---
        let yMean = Swy / Sw
        var SS_res = 0.0, SS_tot = 0.0

        for s in samples {
            let w      = exp(-lambda * s.age) * s.weightMultiplier
            let fitted = alpha + beta * s.t
            let resid  = s.value - fitted
            SS_res += w * resid * resid
            SS_tot += w * (s.value - yMean) * (s.value - yMean)
        }

        let rSquared        = SS_tot < 1e-12 ? 1.0 : max(0, 1.0 - SS_res / SS_tot)
        let residualVariance = SS_res / Sw         // weighted MSE
        let effectiveN       = Sw2 < 1e-12 ? 0 : (Sw * Sw) / Sw2

        return LinearFit(
            alpha:            alpha,
            beta:             beta,
            rSquared:         rSquared,
            residualVariance: residualVariance,
            effectiveN:       effectiveN
        )
    }

    // -------------------------------------------------------------------------
    // MARK: WLS Quadratic Regression:  y = α + β·t + γ·t²
    // -------------------------------------------------------------------------

    /// Weighted least-squares quadratic regression.
    ///
    /// **WLS normal equations** (3×3 system):
    ///
    ///   ┌ Σw    Σwt    Σwt²   ┐ ┌ α ┐   ┌ Σwy   ┐
    ///   │ Σwt   Σwt²   Σwt³   │ │ β │ = │ Σwty  │
    ///   └ Σwt²  Σwt³   Σwt⁴  ┘ └ γ ┘   └ Σwt²y ┘
    ///
    /// Solved by **Gaussian elimination with partial pivoting** to maximise
    /// numerical stability with the varying magnitudes produced by different λ values.
    ///
    /// Falls back to `linearFallback` when:
    ///   - fewer than 4 samples are available (the quadratic would be under-constrained),
    ///   - the pivot is too small (system is singular — e.g. all values identical), or
    ///   - the estimated curvature |γ| exceeds a physical sanity bound.
    ///
    /// **Interpretation:**
    ///   - β = velocity at t = 0 (%/hour)
    ///   - 2γ = acceleration (%/hour²); positive γ → usage is accelerating upward
    func weightedQuadraticRegression(
        samples: [Sample],
        lambda: Double,
        linearFallback: LinearFit
    ) -> QuadraticFit {

        // Quadratic needs at least 4 samples to be more informative than linear.
        guard samples.count >= 4 else {
            return QuadraticFit(alpha: linearFallback.alpha, beta: linearFallback.beta, gamma: 0, valid: false)
        }

        var Sw    = 0.0
        var Swt   = 0.0, Swtt   = 0.0, Swttt  = 0.0, Swtttt = 0.0
        var Swy   = 0.0, Swty   = 0.0, Swtty  = 0.0

        for s in samples {
            let w  = exp(-lambda * s.age) * s.weightMultiplier
            let t  = s.t
            let t2 = t * t
            let t3 = t2 * t
            let t4 = t3 * t
            let y  = s.value

            Sw     += w
            Swt    += w * t
            Swtt   += w * t2
            Swttt  += w * t3
            Swtttt += w * t4
            Swy    += w * y
            Swty   += w * t * y
            Swtty  += w * t2 * y
        }

        // Augmented matrix [A | b] — 3 rows × 4 columns.
        var M: [[Double]] = [
            [Sw,    Swt,    Swtt,   Swy  ],
            [Swt,   Swtt,   Swttt,  Swty ],
            [Swtt,  Swttt,  Swtttt, Swtty]
        ]

        // Gaussian elimination with partial pivoting.
        for col in 0 ..< 3 {
            var pivotRow = col
            var pivotMag = abs(M[col][col])
            for row in (col + 1) ..< 3 where abs(M[row][col]) > pivotMag {
                pivotMag = abs(M[row][col])
                pivotRow = row
            }
            guard pivotMag > 1e-10 else {
                return QuadraticFit(alpha: linearFallback.alpha, beta: linearFallback.beta, gamma: 0, valid: false)
            }
            if pivotRow != col { M.swapAt(col, pivotRow) }
            let pivot = M[col][col]
            for row in (col + 1) ..< 3 {
                let f = M[row][col] / pivot
                for c in col ..< 4 { M[row][c] -= f * M[col][c] }
            }
        }

        // Back substitution.
        var x = [Double](repeating: 0, count: 3)
        for row in stride(from: 2, through: 0, by: -1) {
            guard abs(M[row][row]) > 1e-14 else {
                return QuadraticFit(alpha: linearFallback.alpha, beta: linearFallback.beta, gamma: 0, valid: false)
            }
            var sum = M[row][3]
            for c in (row + 1) ..< 3 { sum -= M[row][c] * x[c] }
            x[row] = sum / M[row][row]
        }

        // Sanity clamp: |γ| > 200 %/h² would mean going from 0 % to 100 % in under
        // a minute — physically impossible given Claude's rolling window mechanics.
        // Such values indicate an over-fitted quadratic on noisy sparse data.
        guard abs(x[2]) <= 200 else {
            return QuadraticFit(alpha: linearFallback.alpha, beta: linearFallback.beta, gamma: 0, valid: false)
        }

        return QuadraticFit(alpha: x[0], beta: x[1], gamma: x[2], valid: true)
    }

    // -------------------------------------------------------------------------
    // MARK: Stage 5 – Confidence
    // -------------------------------------------------------------------------

    /// Derive forecast confidence from three orthogonal components.
    ///
    /// **R² component** (0–1):
    ///   Measures how well the linear model explains the observed variance.
    ///   A noisy, erratic signal yields a low R², indicating unreliable extrapolation.
    ///
    /// **Density component** (0–1):
    ///   `log(1 + n_eff) / log(1 + 10)`
    ///   Saturates at n_eff ≈ 10 effective samples.  Uses the log scale because
    ///   going from 1 to 3 samples matters far more than going from 30 to 32.
    ///
    /// **Stability component** (0–1):
    ///   `exp(−|v|/50 − |a|/10)`
    ///   High velocity and acceleration mean the signal is extrapolating aggressively
    ///   into uncertain territory.  Reference scales: 50 %/h for velocity ("fast"),
    ///   10 %/h² for acceleration ("rapidly accelerating").
    ///
    /// The three components are **multiplied** together so that a single very bad
    /// factor (e.g. only 1 sample, or R² = 0.02) tanks the overall score.
    func computeConfidence(linearFit: LinearFit, velocity: Double, acceleration: Double) -> Double {
        let r2Component = linearFit.rSquared.clamped(to: 0...1)

        let densityComponent = (log(1 + linearFit.effectiveN) / log(1 + 10)).clamped(to: 0...1)

        let stabilityComponent = exp(-abs(velocity) / 50.0 - abs(acceleration) / 10.0)

        return (r2Component * densityComponent * stabilityComponent).clamped(to: 0...1)
    }

    // -------------------------------------------------------------------------
    // MARK: Instability Score
    // -------------------------------------------------------------------------

    /// Scalar instability score used for adaptive λ and ensemble blending.
    ///
    /// Normalised to natural reference magnitudes:
    ///   velocity:    50 %/h  (= 0→100 % in 2 hours)
    ///   acceleration: 10 %/h² (= doubling rate per hour)
    ///   noise:        10 % std (typical polling jitter)
    ///
    /// Score ≈ 0: stable, long-memory regime.
    /// Score ≈ 1: moderately volatile — head and tail begin to diverge.
    /// Score ≥ 2: rapid change — recent observations dominate.
    func computeInstabilityScore(velocity: Double, acceleration: Double, residualStd: Double) -> Double {
        let v = abs(velocity)    / 50.0
        let a = abs(acceleration) / 10.0
        let n = residualStd      / 10.0
        // Acceleration and noise are weighted higher because they indicate
        // structural change in the signal, not just a sustained trend.
        return (v * 0.5 + a * 1.0 + n * 0.5).clamped(to: 0...10)
    }

    // -------------------------------------------------------------------------
    // MARK: Sigmoid
    // -------------------------------------------------------------------------

    /// Smooth sigmoid function for continuously blending two models.
    ///
    /// Returns ≈ 0 when `x << midpoint` (tail dominates) and ≈ 1 when
    /// `x >> midpoint` (head dominates).  `steepness` controls the sharpness of
    /// the transition without introducing any hard threshold.
    func sigmoid(_ x: Double, midpoint: Double, steepness: Double) -> Double {
        1.0 / (1.0 + exp(-steepness * (x - midpoint)))
    }
}

// -------------------------------------------------------------------------
// MARK: Double Clamping
// -------------------------------------------------------------------------

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
