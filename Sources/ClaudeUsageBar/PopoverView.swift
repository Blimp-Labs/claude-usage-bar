import SwiftUI
import ServiceManagement

struct PopoverView: View {
    @ObservedObject var service: UsageService
    @ObservedObject var historyService: UsageHistoryService
    @AppStorage("launchAtLoginAsked") private var launchAtLoginAsked = false
    @State private var showLaunchPrompt = false

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
            bucket: service.usage?.sevenDay
        )

        if let opus = service.usage?.sevenDayOpus,
           opus.utilization != nil {
            Divider()
            Text("Per-Model (7 day)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            UsageBucketRow(label: "Opus", bucket: opus)
            if let sonnet = service.usage?.sevenDaySonnet {
                UsageBucketRow(label: "Sonnet", bucket: sonnet)
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
                
            Picker("", selection: $service.pollingMinutes) {
                ForEach(UsageService.pollingOptions, id: \.self) { mins in
                    Text(mins < 60 ? "\(mins)m" : "\(mins / 60)h").tag(mins)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.mini)
            .frame(width: 60)
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
            ProgressView(value: (bucket?.utilization ?? 0) / 100.0, total: 1.0)
                .tint(colorForPct((bucket?.utilization ?? 0) / 100.0))
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
            if let used = extra.usedCredits, let limit = extra.monthlyLimit {
                HStack {
                    Text(String(format: "$%.2f / $%.2f", used, limit))
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
