import SwiftUI

struct PopoverView: View {
    @ObservedObject var service: UsageService
    @ObservedObject var historyService: UsageHistoryService
    @ObservedObject var notificationService: NotificationService
    @ObservedObject var appUpdater: AppUpdater
    /// Optional so existing tests / call sites that don't care about service status keep compiling.
    var statusMonitor: StatusMonitor?
    @AppStorage("setupComplete") private var setupComplete = false
    @AppStorage(AppearanceDefaultsKey.showServiceStatus) private var showServiceStatus = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !setupComplete && !service.isAuthenticated {
                SetupView(
                    service: service,
                    notificationService: notificationService,
                    onComplete: { setupComplete = true }
                )
            } else {
                Text("Claude Usage")
                    .font(.headline)
                if !service.isAuthenticated {
                    signInView
                } else {
                    usageView
                }
            }
        }
        .padding()
        .frame(width: 340)
    }

    @ViewBuilder
    private var signInView: some View {
        if service.isAwaitingCode {
            CodeEntryView(service: service)
        } else {
            Text("Sign in to view your usage.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Sign in with Claude") {
                service.startOAuthFlow()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }

        if let error = service.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.caption)
        }

        Divider()
        HStack {
            settingsButton
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var usageView: some View {
        UsageBucketRow(
            label: "5-Hour Window",
            bucket: service.usage?.fiveHour,
            windowSeconds: 5 * 3600
        )

        UsageBucketRow(
            label: "7-Day Window",
            bucket: service.usage?.sevenDay,
            windowSeconds: 7 * 24 * 3600
        )

        if let opus = service.usage?.sevenDayOpus,
           opus.utilization != nil {
            Divider()
            Text("Per-Model (7 day)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            UsageBucketRow(label: "Opus", bucket: opus, windowSeconds: 7 * 24 * 3600)
            if let sonnet = service.usage?.sevenDaySonnet {
                UsageBucketRow(label: "Sonnet", bucket: sonnet, windowSeconds: 7 * 24 * 3600)
            }
        }

        if let extra = service.usage?.extraUsage, extra.isEnabled {
            Divider()
            ExtraUsageRow(extra: extra)
        }

        Divider()
        UsageChartView(historyService: historyService)

        if let error = service.lastError {
            Divider()
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.caption)
        }

        if let updaterError = appUpdater.lastError {
            Divider()
            Label(updaterError, systemImage: "arrow.triangle.2.circlepath.circle")
                .foregroundStyle(.red)
                .font(.caption)
        }

        Divider()

        HStack(spacing: 12) {
            if let updated = service.lastUpdated {
                Text("Updated \(updated, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }

        if showServiceStatus, let monitor = statusMonitor {
            ServiceStatusSection(monitor: monitor)
            Divider()
        }
        
        HStack(spacing: 12) {
            settingsButton
            Spacer()
            Button("Refresh") {
                Task { 
                    await service.fetchUsage()
                    await statusMonitor?.refresh()
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            if appUpdater.isConfigured {
                Button("Check for Updates…") {
                    appUpdater.checkForUpdates()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(!appUpdater.canCheckForUpdates)
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var settingsButton: some View {
        SettingsLink {
            Text("Settings…")
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}

// MARK: - Setup (first launch)

private struct SetupView: View {
    @ObservedObject var service: UsageService
    @ObservedObject var notificationService: NotificationService
    var onComplete: () -> Void

    var body: some View {
        Text("Welcome")
            .font(.headline)
        Text("Configure your preferences to get started.")
            .font(.subheadline)
            .foregroundStyle(.secondary)

        Divider()

        LaunchAtLoginToggle(controlSize: .small, useSwitchStyle: true)

        Divider()

        VStack(alignment: .leading, spacing: 8) {
            Text("Notifications")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            SetupThresholdSlider(
                label: "5-hour window",
                value: notificationService.threshold5h,
                onChange: { notificationService.setThreshold5h($0) }
            )
            SetupThresholdSlider(
                label: "7-day window",
                value: notificationService.threshold7d,
                onChange: { notificationService.setThreshold7d($0) }
            )
            SetupThresholdSlider(
                label: "Extra usage",
                value: notificationService.thresholdExtra,
                onChange: { notificationService.setThresholdExtra($0) }
            )
        }

        Divider()

        VStack(alignment: .leading, spacing: 6) {
            Text("Polling Interval")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("", selection: Binding(
                get: { service.pollingMinutes },
                set: { service.updatePollingInterval($0) }
            )) {
                ForEach(UsageService.pollingOptions, id: \.self) { mins in
                    Text(localizedPollingInterval(for: mins, locale: .autoupdatingCurrent))
                        .tag(mins)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if isDiscouragedPollingOption(service.pollingMinutes) {
                Text("Frequent polling may cause rate limiting")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }

        Divider()

        Button("Get Started") {
            onComplete()
        }
        .buttonStyle(.borderedProminent)
        .frame(maxWidth: .infinity)

        HStack {
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Subviews

private struct CodeEntryView: View {
    @ObservedObject var service: UsageService
    @State private var code = ""

    var body: some View {
        Text("Paste the code from your browser:")
            .font(.subheadline)
            .foregroundStyle(.secondary)

        HStack(spacing: 4) {
            TextField("code#state", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { submit() }
            Button {
                if let str = NSPasteboard.general.string(forType: .string) {
                    code = str.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
        }

        HStack {
            Button("Cancel") {
                service.isAwaitingCode = false
            }
            .buttonStyle(.borderless)
            Spacer()
            Button("Submit") { submit() }
                .buttonStyle(.borderedProminent)
                .disabled(code.isEmpty)
        }
    }

    private func submit() {
        let value = code
        Task { await service.submitOAuthCode(value) }
    }
}

private struct UsageBucketRow: View {
    let label: String
    let bucket: UsageBucket?
    let windowSeconds: TimeInterval

    @AppStorage(AppearanceDefaultsKey.showResetDivider) private var showResetDivider = false
    @AppStorage(AppearanceDefaultsKey.coloredResetDivider) private var coloredResetDivider = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text(percentageText)
                    .font(.subheadline)
                    .monospacedDigit()
            }
            ZStack(alignment: .leading) {
                ProgressView(value: (bucket?.utilization ?? 0) / 100.0, total: 1.0)
                    .tint(colorForPct((bucket?.utilization ?? 0) / 100.0))
                if showResetDivider,
                   bucket?.resetsAtDate != nil,
                   let pos = bucket?.resetPosition(windowSeconds: windowSeconds, now: Date()),
                   let usagePct = bucket?.utilization {
                    // Calculate the divider state based on current usage and time remaining in the reset window.
                    // pos (0...1): position where the divider is drawn (0 = left/start, 1 = right/end)
                    // timeLeftFraction: how much of the reset window remains (1 = full window, 0 = reset is now)
                    // Thresholds: state becomes "critical" at 80% usage, "warning" at 33% time remaining.
                    // When both conditions are true, state is "inUsageLimit" (the highest alert).
                    let timeLeftFraction = 1.0 - pos
                    let state = resetIndicatorState(
                        usagePct: usagePct,
                        timeLeftFraction: timeLeftFraction
                    )
                    ResetIndicatorView(position: pos, state: state, colored: coloredResetDivider)
                }
            }
            if let resetDate = bucket?.resetsAtDate {
                Text("Resets \(resetDate, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var percentageText: String {
        guard let pct = bucket?.utilization else { return "—" }
        return "\(Int(round(pct)))%"
    }
}

/// Renders the reset-time divider on the usage progress bar.
/// The divider is a 2-point vertical line that indicates when the usage bucket resets (position)
/// and which changes color based on usage intensity and time remaining (state).
private struct ResetIndicatorView: View {
    /// Normalized position (0...1) where the divider should be drawn: 0 = left edge, 1 = right edge.
    /// Corresponds to how far through the reset window we are.
    let position: Double
    /// Current state of the divider (normal/warning/critical/inUsageLimit), driving the color.
    let state: ResetIndicatorState
    /// Whether to use semantic colors (orange/red) or a neutral gray. When false, all states render as .secondary.
    let colored: Bool

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(state.color(colored: colored))
                .frame(width: 2)
                .offset(x: geo.size.width * position - 1)
                .accessibilityHidden(true)
        }
        .frame(height: 8)
    }
}

private struct ExtraUsageRow: View {
    let extra: ExtraUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Extra Usage")
                .font(.subheadline)
            if let used = extra.usedCreditsAmount, let limit = extra.monthlyLimitAmount {
                HStack {
                    Text("\(ExtraUsage.formatUSD(used)) / \(ExtraUsage.formatUSD(limit))")
                        .font(.caption)
                        .monospacedDigit()
                    Spacer()
                    if let pct = extra.utilization {
                        Text("\(Int(round(pct)))%")
                            .font(.caption)
                            .monospacedDigit()
                    }
                }
                ProgressView(value: (extra.utilization ?? 0) / 100.0, total: 1.0)
                    .tint(.blue)
            }
        }
    }
}

private struct SetupThresholdSlider: View {
    let label: String
    let value: Int
    let onChange: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.callout)
                Spacer()
                Text(value > 0 ? "\(value)%" : "Off")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { onChange(Int($0)) }
                ),
                in: 0...100,
                step: 5
            )
            .controlSize(.small)
        }
    }
}

private func colorForPct(_ pct: Double) -> Color {
    switch pct {
    case ..<0.60: .green
    case 0.60..<0.80: .yellow
    default: .red
    }
}

// MARK: - Service Status section

/// Display state for the popover Service Status block. Pure view-model so it can be unit-tested
/// without spinning up SwiftUI.
public enum ServiceStatusDisplayState: Equatable {
    case loading
    case unavailable
    case ready(StatusSnapshot)

    public static func make(snapshot: StatusSnapshot?, lastError: StatusError?) -> ServiceStatusDisplayState {
        if let snapshot {
            return .ready(snapshot)
        }
        if lastError != nil {
            return .unavailable
        }
        return .loading
    }
}

@MainActor
struct ServiceStatusSection: View {
    let monitor: StatusMonitor
    private let statusPageURL = URL(string: "https://status.claude.com")!

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Service Status")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            switch ServiceStatusDisplayState.make(
                snapshot: monitor.snapshot,
                lastError: monitor.lastError
            ) {
            case .loading:
                Text("Checking status…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .unavailable:
                HStack {
                    Label("Status unavailable", systemImage: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") {
                        Task { await monitor.refresh() }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            case .ready(let snap):
                ForEach(snap.allMonitoredComponents) { component in
                    HStack {
                        Circle()
                            .fill(componentColor(component.status))
                            .frame(width: 6, height: 6)
                        Text(component.name)
                            .font(.caption)
                        Spacer()
                        Text(humanReadable(component.status))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(snap.activeIncidents) { incident in
                    Label(incident.name, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }

            HStack {
                Button("View status page") {
                    NSWorkspace.shared.open(statusPageURL)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Spacer()
            }
        }
    }

    private func componentColor(_ status: ClaudeServiceStatus) -> Color {
        switch status {
        case .operational, .underMaintenance: return .green
        case .degradedPerformance, .partialOutage: return .orange
        case .majorOutage: return .red
        }
    }

    private func humanReadable(_ status: ClaudeServiceStatus) -> String {
        switch status {
        case .operational: return "Operational"
        case .underMaintenance: return "Under maintenance"
        case .degradedPerformance: return "Degraded"
        case .partialOutage: return "Partial outage"
        case .majorOutage: return "Major outage"
        }
    }
}
