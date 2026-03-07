import SwiftUI
import ServiceManagement

struct PopoverView: View {
    @ObservedObject var service: UsageService
    @ObservedObject var historyService: UsageHistoryService
    @ObservedObject var appUpdater: AppUpdater
    @AppStorage("launchAtLoginAsked") private var launchAtLoginAsked = false
    @State private var showLaunchPrompt = false
    @State private var isDetailMode = false

    /// Segments derived from the API's per-model 7-day buckets.
    /// Returns nil when per-model data isn't available yet.
    private var sevenDaySegments: [SegmentedProgressView.Segment]? {
        guard let total = service.usage?.sevenDay?.utilization, total > 0 else { return nil }
        var segs: [SegmentedProgressView.Segment] = []
        if let pct = service.usage?.sevenDaySonnet?.utilization, pct > 0 {
            segs.append(.init(label: "Sonnet", color: .teal, fraction: pct / total))
        }
        if let pct = service.usage?.sevenDayOpus?.utilization, pct > 0 {
            segs.append(.init(label: "Opus", color: .purple, fraction: pct / total))
        }
        let accounted = segs.reduce(0) { $0 + $1.fraction }
        if accounted < 0.99 {
            segs.append(.init(label: "Other", color: .secondary, fraction: 1.0 - accounted))
        }
        return segs.isEmpty ? nil : segs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Claude Usage")
                .font(.headline)

            if !service.isAuthenticated {
                signInView
            } else {
                usageView
            }
        }
        .padding()
        .frame(width: 340)
        .onAppear {
            if !launchAtLoginAsked {
                showLaunchPrompt = true
            }
        }
        .alert("Launch at Login?", isPresented: $showLaunchPrompt) {
            Button("Enable") {
                setLaunchAtLogin(true)
                launchAtLoginAsked = true
            }
            Button("No Thanks", role: .cancel) {
                launchAtLoginAsked = true
            }
        } message: {
            Text("Would you like Claude Usage Bar to start automatically when you log in?")
        }
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
            bucket: service.usage?.fiveHour
        )

        UsageBucketRow(
            label: "7-Day Window",
            bucket: service.usage?.sevenDay,
            segments: isDetailMode ? sevenDaySegments : nil
        )
        .simultaneousGesture(TapGesture().onEnded {
            guard NSEvent.modifierFlags.contains(.option) else { return }
            isDetailMode.toggle()
        })

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
            Text("Polling every")
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                ForEach(UsageService.pollingOptions, id: \.self) { mins in
                    Button {
                        service.updatePollingInterval(mins)
                    } label: {
                        if mins == service.pollingMinutes {
                            Label(pollingOptionLabel(for: mins), systemImage: "checkmark")
                        } else {
                            Text(pollingOptionLabel(for: mins))
                        }
                    }
                }
            } label: {
                Text(localizedPollingInterval(for: service.pollingMinutes, locale: .autoupdatingCurrent))
            }
            .controlSize(.mini)
            .fixedSize()
            .help("Polling interval")
        }

        HStack(spacing: 12) {
            Toggle("Launch at Login", isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()
            Button("Refresh") {
                Task { await service.fetchUsage() }
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
            Button("Sign Out") { service.signOut() }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

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
    var segments: [SegmentedProgressView.Segment]? = nil

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
            if let segs = segments {
                SegmentedProgressView(
                    fillFraction: (bucket?.utilization ?? 0) / 100.0,
                    segments: segs
                )
            } else {
                ProgressView(value: (bucket?.utilization ?? 0) / 100.0, total: 1.0)
                    .tint(colorForPct((bucket?.utilization ?? 0) / 100.0))
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

private func setLaunchAtLogin(_ enabled: Bool) {
    do {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    } catch {
        // Silently ignore — user can toggle again
    }
}

private func colorForPct(_ pct: Double) -> Color {
    switch pct {
    case ..<0.60: return .green
    case 0.60..<0.80: return .yellow
    default: return .red
    }
}
