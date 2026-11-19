import SwiftUI

struct PopoverView: View {
    @ObservedObject var service: UsageService
    @ObservedObject var historyService: UsageHistoryService
    @Environment(\.openSettings) private var openSettings

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
    }

    @ViewBuilder
    private var signInView: some View {
        if service.isWaitingForBrowser {
            BrowserSignInView(service: service)
        } else if service.isAwaitingCode {
            CodeEntryView(service: service)
        } else {
            Text("Sign in to view your usage.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                Task { await service.startOAuthFlow() }
            } label: {
                Text("Sign in with Claude")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }

        if let error = service.lastError {
            ErrorLabel(message: error)
        }

        Divider()
        HStack {
            settingsButton
            Spacer()
            quitButton
        }
    }

    @ViewBuilder
    private var usageView: some View {
        if service.hasFiveHourWindow {
            UsageBucketRow(
                label: "5-Hour Window",
                bucket: service.usage?.fiveHour
            )
        }

        UsageBucketRow(
            label: "7-Day Window",
            bucket: service.usage?.sevenDay
        )

        let perModel = service.usage?.perModelWeekly ?? []
        if !perModel.isEmpty {
            Divider()
            Text("Per-Model (7 day)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            perModelRows(perModel)
        }

        if let extra = service.usage?.extraUsage, extra.isEnabled {
            Divider()
            ExtraUsageRow(extra: extra)
        }

        Divider()
        UsageChartView(historyService: historyService, showsFiveHour: service.hasFiveHourWindow)

        if let error = service.lastError {
            Divider()
            ErrorLabel(message: error)
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

        HStack(spacing: 12) {
            settingsButton
            Spacer()
            Button("Refresh") {
                Task { await service.fetchUsage() }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            quitButton
        }
    }

    /// How many per-model rows render inline before the section starts scrolling.
    private static let inlinePerModelRowLimit = 6
    /// Approximate height of one `UsageBucketRow`, used only to size the scroller.
    private static let perModelRowHeight: CGFloat = 52

    /// The number of model-scoped windows the server reports is unbounded, and
    /// the popover has a fixed width and no outer scroll view — so past a
    /// handful of rows this section scrolls instead of pushing the chart and
    /// the controls off-screen.
    @ViewBuilder
    private func perModelRows(_ entries: [PerModelUsage]) -> some View {
        let rows = VStack(alignment: .leading, spacing: 8) {
            ForEach(entries) { entry in
                UsageBucketRow(label: entry.displayName, bucket: entry.bucket)
            }
        }

        if entries.count > Self.inlinePerModelRowLimit {
            ScrollView {
                rows
            }
            .frame(height: CGFloat(Self.inlinePerModelRowLimit) * Self.perModelRowHeight)
        } else {
            rows
        }
    }

    private var settingsButton: some View {
        Button("Settings…") {
            openSettings()
            focusSettingsWindow()
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }

    private var quitButton: some View {
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Subviews

struct BrowserSignInView: View {
    @ObservedObject var service: UsageService

    var body: some View {
        Text("Approve access in your browser to finish signing in.")
            .font(.subheadline)
            .foregroundStyle(.secondary)

        HStack {
            Button("Cancel") {
                service.endOAuthFlow()
            }
            .buttonStyle(.borderless)
            Spacer()
            Button("Paste a code instead") {
                service.switchToPastedCode()
            }
            .buttonStyle(.borderless)
        }
    }
}

struct CodeEntryView: View {
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
                service.endOAuthFlow()
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

struct ErrorLabel: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .font(.caption)
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

private func colorForPct(_ pct: Double) -> Color {
    switch pct {
    case ..<0.60: return .green
    case 0.60..<0.80: return .yellow
    default: return .red
    }
}
