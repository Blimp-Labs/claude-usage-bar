import SwiftUI
import Charts

struct UsageChartView: View {
    @ObservedObject var historyService: UsageHistoryService
    @State private var selectedRange: TimeRange = .day1
    @State private var hoverDate: Date?
    @State private var cachedPoints: [UsageDataPoint] = []
    @State private var sortedCachedPoints: [UsageDataPoint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $selectedRange) {
                ForEach(TimeRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if cachedPoints.isEmpty {
                Text("No history data yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                chartView(points: cachedPoints, sortedPoints: sortedCachedPoints)
            }
        }
        .onAppear { updateCache() }
        .onChange(of: selectedRange) { updateCache() }
        .onChange(of: historyService.history.dataPoints.count) { updateCache() }
    }

    private func updateCache() {
        cachedPoints = historyService.downsampledPoints(for: selectedRange)
        sortedCachedPoints = cachedPoints.sorted { $0.timestamp < $1.timestamp }
    }

    @ViewBuilder
    private func chartView(points: [UsageDataPoint], sortedPoints: [UsageDataPoint]) -> some View {
        let interpolated = hoverDate.flatMap { interpolateValues(at: $0, sortedPoints: sortedPoints) }

        VStack(alignment: .leading, spacing: 2) {
            // Fixed-height tooltip area — empty when not hovering
            Group {
                if let iv = interpolated {
                    tooltipView(date: iv.date, pct5h: iv.pct5h, pct7d: iv.pct7d)
                } else {
                    Color.clear
                }
            }
            .frame(height: 28)

            Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Usage", point.pct5h * 100)
                    )
                    .foregroundStyle(by: .value("Window", "5h"))
                    .interpolationMethod(.monotone)
                }

                ForEach(points) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Usage", point.pct7d * 100)
                    )
                    .foregroundStyle(by: .value("Window", "7d"))
                    .interpolationMethod(.monotone)
                }

                if let iv = interpolated {
                    RuleMark(x: .value("Selected", iv.date))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1))

                    PointMark(
                        x: .value("Time", iv.date),
                        y: .value("Usage", iv.pct5h * 100)
                    )
                    .foregroundStyle(.teal)
                    .symbolSize(24)

                    PointMark(
                        x: .value("Time", iv.date),
                        y: .value("Usage", iv.pct7d * 100)
                    )
                    .foregroundStyle(.indigo)
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
                "5h": Color.teal,
                "7d": Color.indigo
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
                                guard let plotFrame = proxy.plotFrame else { return }
                                let plotOrigin = geo[plotFrame].origin
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
            .frame(height: 120)
            .padding(.top, 4)
        }
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
                    .foregroundStyle(.teal)
                Label("\(Int(round(pct7d * 100)))%", systemImage: "circle.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.indigo)
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

    private func interpolateValues(at date: Date, sortedPoints: [UsageDataPoint]) -> InterpolatedValues? {
        guard !sortedPoints.isEmpty else { return nil }

        // Outside data range — show zeros
        guard let first = sortedPoints.first, let last = sortedPoints.last else { return nil }
        if date < first.timestamp || date > last.timestamp {
            return InterpolatedValues(date: date, pct5h: 0, pct7d: 0)
        }

        // Find surrounding points and lerp
        for i in 0..<(sortedPoints.count - 1) {
            let a = sortedPoints[i]
            let b = sortedPoints[i + 1]
            if date >= a.timestamp && date <= b.timestamp {
                let span = b.timestamp.timeIntervalSince(a.timestamp)
                let t = span > 0 ? date.timeIntervalSince(a.timestamp) / span : 0
                return InterpolatedValues(
                    date: date,
                    pct5h: a.pct5h + (b.pct5h - a.pct5h) * t,
                    pct7d: a.pct7d + (b.pct7d - a.pct7d) * t
                )
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
