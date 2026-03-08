import SwiftUI
import Charts

struct UsageChartView: View {
    @ObservedObject var historyService: UsageHistoryService
    @State private var selectedRange: TimeRange = .day1
    @State private var hoverDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $selectedRange) {
                ForEach(TimeRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            let points = historyService.downsampledPoints(for: selectedRange)

            if points.isEmpty {
                Text("No history data yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                chartView(points: points)
            }
        }
    }

    @ViewBuilder
    private func chartView(points: [UsageDataPoint]) -> some View {
        let interpolated = hoverDate.flatMap { interpolateValues(at: $0, in: points) }

        Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Usage", point.pct5h * 100)
                )
                .foregroundStyle(by: .value("Window", "5h"))
                .interpolationMethod(.catmullRom)
            }

            ForEach(points) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Usage", point.pct7d * 100)
                )
                .foregroundStyle(by: .value("Window", "7d"))
                .interpolationMethod(.catmullRom)
            }

            if let iv = interpolated {
                RuleMark(x: .value("Selected", iv.date))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1))

                PointMark(
                    x: .value("Time", iv.date),
                    y: .value("Usage", iv.pct5h * 100)
                )
                .foregroundStyle(.blue)
                .symbolSize(24)

                PointMark(
                    x: .value("Time", iv.date),
                    y: .value("Usage", iv.pct7d * 100)
                )
                .foregroundStyle(.orange)
                .symbolSize(24)
            }
        }
        .chartXScale(domain: Date.now.addingTimeInterval(-selectedRange.interval)...Date.now)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text("\(v)%")
                            .font(.caption2)
                    }
                }
                AxisGridLine()
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisValueLabel(format: xAxisFormat)
                    .font(.caption2)
                AxisGridLine()
            }
        }
        .chartForegroundStyleScale([
            "5h": Color.blue,
            "7d": Color.orange
        ])
        .chartLegend(.visible)
        .chartPlotStyle { plot in
            plot.clipped()
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let plotOrigin = geo[proxy.plotFrame!].origin
                            let x = location.x - plotOrigin.x
                            if let date: Date = proxy.value(atX: x) {
                                hoverDate = date
                            }
                        case .ended:
                            hoverDate = nil
                        }
                    }
            }
        }
        .overlay(alignment: .top) {
            if let iv = interpolated {
                tooltipView(date: iv.date, pct5h: iv.pct5h, pct7d: iv.pct7d)
            }
        }
        .frame(height: 120)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func tooltipView(date: Date, pct5h: Double, pct7d: Double) -> some View {
        VStack(spacing: 2) {
            Text(date, format: tooltipDateFormat)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Label("\(Int(round(pct5h * 100)))%", systemImage: "circle.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.blue)
                Label("\(Int(round(pct7d * 100)))%", systemImage: "circle.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Interpolation

    private struct InterpolatedValues {
        let date: Date
        let pct5h: Double
        let pct7d: Double
    }

    private func catmullRom(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, t: Double) -> Double {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * (
            (2 * p1) +
            (-p0 + p2) * t +
            (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
            (-p0 + 3 * p1 - 3 * p2 + p3) * t3
        )
    }

    private func interpolateValues(at date: Date, in points: [UsageDataPoint]) -> InterpolatedValues? {
        guard points.count >= 2 else { return nil }

        let sorted = points.sorted { $0.timestamp < $1.timestamp }

        if date < sorted.first!.timestamp || date > sorted.last!.timestamp {
            return InterpolatedValues(date: date, pct5h: 0, pct7d: 0)
        }

        for i in 0..<(sorted.count - 1) {
            if date >= sorted[i].timestamp && date <= sorted[i + 1].timestamp {
                let span = sorted[i + 1].timestamp.timeIntervalSince(sorted[i].timestamp)
                let t = span > 0 ? date.timeIntervalSince(sorted[i].timestamp) / span : 0

                // Four control points, clamping at boundaries
                let i0 = max(0, i - 1)
                let i3 = min(sorted.count - 1, i + 2)

                let pct5h = catmullRom(
                    sorted[i0].pct5h, sorted[i].pct5h,
                    sorted[i + 1].pct5h, sorted[i3].pct5h, t: t
                )
                let pct7d = catmullRom(
                    sorted[i0].pct7d, sorted[i].pct7d,
                    sorted[i + 1].pct7d, sorted[i3].pct7d, t: t
                )

                return InterpolatedValues(date: date, pct5h: pct5h, pct7d: pct7d)
            }
        }

        return nil
    }

    // MARK: - Formatting

    private var xAxisFormat: Date.FormatStyle {
        switch selectedRange {
        case .hour1:
            return .dateTime.hour().minute()
        case .hour6, .day1:
            return .dateTime.hour()
        case .day7:
            return .dateTime.weekday(.abbreviated)
        case .day30:
            return .dateTime.day().month(.abbreviated)
        }
    }

    private var tooltipDateFormat: Date.FormatStyle {
        switch selectedRange {
        case .hour1, .hour6, .day1:
            return .dateTime.hour().minute()
        case .day7:
            return .dateTime.weekday(.abbreviated).hour().minute()
        case .day30:
            return .dateTime.month(.abbreviated).day().hour()
        }
    }
}
