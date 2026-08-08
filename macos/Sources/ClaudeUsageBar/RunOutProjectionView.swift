import SwiftUI
import Charts
import os

/// A forward-looking "when will the 5-hour window run out?" illustration: a one-line status
/// plus a chart spanning now → the next 5h reset, with a red rule at the projected run-out.
///
/// Deliberately separate from `UsageChartView` (the history chart) — this reads live state off
/// `UsageService` (`pct5h`, `forecast`, `reset5h`) rather than raw persisted history.
struct RunOutProjectionView: View {
    private static let logger = Logger(subsystem: "com.local.ClaudeUsageBar", category: "RunOutProjection")

    @ObservedObject var service: UsageService

    var body: some View {
        // Re-evaluate every minute so "now" and the red line stay live while the popover is
        // open, independent of the (possibly slow) poll cadence.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let estimate = RunOutEstimate.compute(
            forecast: service.forecast,
            anchorPct: service.pct5h * 100,
            anchorTime: service.lastUpdated ?? now,
            reset: service.reset5h,
            now: now
        )
        let showsChart = estimate.reset != nil && estimate.outcome != .insufficientData
        let _ = Self.logger.debug(
            "content(now:): outcome=\(String(describing: estimate.outcome), privacy: .public) showsChart=\(showsChart, privacy: .public)"
        )

        VStack(alignment: .leading, spacing: 8) {
            statusText(for: estimate.outcome)

            if let reset = estimate.reset, estimate.outcome != .insufficientData {
                chart(estimate: estimate, reset: reset)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Status line

    @ViewBuilder
    private func statusText(for outcome: RunOutEstimate.Outcome) -> some View {
        switch outcome {
        case .insufficientData:
            Text("Not enough data to project a run-out yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .lastsUntilReset:
            Label("Lasts until reset", systemImage: "checkmark.circle")
                .font(.subheadline)
                .foregroundStyle(.green)
        case .runsOut(let date):
            Label("Projected to run out at \(date, format: .dateTime.hour().minute())",
                  systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Chart

    private struct RunOutPoint: Identifiable {
        let id = UUID()
        let date: Date
        let pct: Double
    }

    /// Drawing parameters derived from an estimate (kept out of the `@ViewBuilder` so the
    /// imperative branching below is treated as plain code, not view content).
    private struct ChartGeometry {
        let points: [RunOutPoint]
        let color: Color
        let runsOutDate: Date?
        let now: Date
        let startPct: Double
    }

    private func geometry(estimate: RunOutEstimate, reset: Date) -> ChartGeometry {
        let now = estimate.now
        let startPct = estimate.currentPct

        // The trajectory ends at the crossing (if it runs out before reset) or at the reset
        // edge (staying below 100 % — visually confirming "lasts until reset").
        let endDate: Date
        let endPct: Double
        var runsOutDate: Date?
        if case .runsOut(let date) = estimate.outcome {
            endDate = date
            endPct = 100
            runsOutDate = date
        } else {
            endDate = reset
            let projected = estimate.currentPct + estimate.ratePerHour * (reset.timeIntervalSince(now) / 3600)
            endPct = min(max(projected, 0), 100)
        }

        return ChartGeometry(
            points: [RunOutPoint(date: now, pct: startPct), RunOutPoint(date: endDate, pct: endPct)],
            color: runsOutDate != nil ? .red : .green,
            runsOutDate: runsOutDate,
            now: now,
            startPct: startPct
        )
    }

    @ViewBuilder
    private func chart(estimate: RunOutEstimate, reset: Date) -> some View {
        let geo = geometry(estimate: estimate, reset: reset)

        Chart {
            // 100 % limit reference.
            RuleMark(y: .value("Limit", 100))
                .foregroundStyle(.secondary.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))

            // Projected trajectory (dashed).
            ForEach(geo.points) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Usage", point.pct)
                )
                .foregroundStyle(geo.color)
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }

            // Current usage marker at "now".
            PointMark(
                x: .value("Time", geo.now),
                y: .value("Usage", geo.startPct)
            )
            .foregroundStyle(geo.color)
            .symbolSize(28)

            // Red vertical line at the projected run-out time (clock time shown in the status).
            if let runsOutDate = geo.runsOutDate {
                RuleMark(x: .value("Runs out", runsOutDate))
                    .foregroundStyle(.red)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
        .chartXScale(domain: geo.now...reset)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text("\(v)%").font(.caption2)
                    }
                }
                AxisGridLine()
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: Date.FormatStyle.dateTime.hour().minute())
                    .font(.caption2)
                AxisGridLine()
            }
        }
        .chartPlotStyle { plot in
            plot.clipped()
        }
        .frame(height: 100)
        .padding(.top, 4)
    }
}
