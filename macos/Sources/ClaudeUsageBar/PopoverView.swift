import SwiftUI
import os

struct PopoverView: View {
    private static let resizeLogger = Logger(subsystem: "com.local.ClaudeUsageBar", category: "PopoverResize")
    @ObservedObject var service: UsageService
    @ObservedObject var historyService: UsageHistoryService
    @ObservedObject var notificationService: NotificationService
    @ObservedObject var appUpdater: AppUpdater
    var statusMonitor: StatusMonitor?
    @AppStorage("setupComplete") private var setupComplete = false
    @State private var refreshCoolingDown = false
    @AppStorage(AppearanceDefaultsKey.showServiceStatus) private var showServiceStatus = false
    @AppStorage(AppearanceDefaultsKey.showForecast) private var showForecast = true
    @AppStorage(AppearanceDefaultsKey.showRunOutProjection) private var showRunOutProjection = false
    @State private var hostingWindow: NSWindow?
    @State private var measuredSize: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !setupComplete && !service.isAuthenticated {
                SetupView(
                    service: service,
                    notificationService: notificationService,
                    onComplete: { setupComplete = true }
                )
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar.fill")
                        .foregroundStyle(.tint)
                    Text("Claude Usage")
                        .font(.title3)
                        .fontWeight(.semibold)
                }
                if !service.isAuthenticated {
                    signInView
                } else {
                    usageView
                }
            }
        }
        .padding()
        .frame(width: 340)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: PopoverContentSizeKey.self, value: geo.size)
            }
        )
        .background(
            PopoverWindowLocator { w in
                hostingWindow = w
            }
        )
        .onPreferenceChange(PopoverContentSizeKey.self) { size in
            Self.resizeLogger.debug(
                "onPreferenceChange: measuredSize \(String(describing: measuredSize), privacy: .public) -> \(String(describing: size), privacy: .public), hostingWindow=\(hostingWindow != nil, privacy: .public)"
            )
            guard size != .zero else { return }
            measuredSize = size
            if let hostingWindow {
                applySize(size, to: hostingWindow)
            }
        }
        .onChange(of: hostingWindow) { _, window in
            Self.resizeLogger.debug(
                "onChange(hostingWindow): window=\(window != nil, privacy: .public), measuredSize=\(String(describing: measuredSize), privacy: .public)"
            )
            guard let window, measuredSize != .zero else { return }
            applySize(measuredSize, to: window)
        }
    }

    @ViewBuilder
    private var signInView: some View {
        if service.isAwaitingCode {
            CodeEntryView(service: service)
        } else if service.sessionExpired {
            sessionExpiredView
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
    private var sessionExpiredView: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Session Expired")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("Your session has ended. Sign in again to continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

        Button("Sign in again") {
            service.startOAuthFlow()
        }
        .buttonStyle(.borderedProminent)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var usageView: some View {
        UsageBucketRow(
            label: "5-Hour Window",
            bucket: service.usage?.fiveHour,
            forecastPct: showForecast ? service.forecast.map { $0.projected5h / 100.0 } : nil,
            windowSeconds: 5 * 3600
        )

        UsageBucketRow(
            label: "7-Day Window",
            bucket: service.usage?.sevenDay,
            forecastPct: showForecast ? service.forecast.map { $0.projected7d / 100.0 } : nil,
            windowSeconds: 7 * 24 * 3600
        )

        if let opus = service.usage?.sevenDayOpus,
            opus.utilization != nil
        {
            VStack(alignment: .leading, spacing: 6) {
                Text("Per-Model (7 day)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
                UsageBucketRow(label: "Opus", bucket: opus, windowSeconds: 7 * 24 * 3600)
                if let sonnet = service.usage?.sevenDaySonnet {
                    UsageBucketRow(label: "Sonnet", bucket: sonnet, windowSeconds: 7 * 24 * 3600)
                }
            }
        }

        if let extra = service.usage?.extraUsage, extra.isEnabled {
            ExtraUsageRow(extra: extra)
        }

        UsageChartView(historyService: historyService)

        if showRunOutProjection {
            RunOutProjectionView(service: service, onOutcomeCaseChange: forceResize)
        }

        if let error = service.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.caption)
        }

        if let updaterError = appUpdater.lastError {
            Label(updaterError, systemImage: "arrow.triangle.2.circlepath.circle")
                .foregroundStyle(.red)
                .font(.caption)
        }

        if showServiceStatus, let monitor = statusMonitor {
            ServiceStatusSection(monitor: monitor)
        }

        footerView
    }

    private var footerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let updated = service.lastUpdated {
                Text("Updated \(updated, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 10) {
                settingsButton
                Spacer()
                Button {
                    refresh()
                } label: {
                    ZStack {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .opacity(service.isFetching ? 0 : 1)
                        ProgressView()
                            .controlSize(.small)
                            .opacity(service.isFetching ? 1 : 0)
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(service.isFetching || refreshCoolingDown)
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
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// `setContentSize` keeps the window's bottom-left corner fixed and grows/shrinks upward,
    /// which is correct for an ordinary document window but wrong for a menu-bar-anchored
    /// popover: the top edge needs to stay pinned under the status item, with the window
    /// growing/shrinking downward instead. Left uncorrected, a height change (e.g. the
    /// run-out projection card appearing or collapsing) drags the top edge away from its
    /// anchor while the content still renders as if it were pinned there.
    private func applySize(_ size: CGSize, to window: NSWindow) {
        let frameBefore = window.frame
        let contentRect = window.contentRect(forFrameRect: window.frame)
        var newContentRect = contentRect
        newContentRect.size = size
        newContentRect.origin.y = contentRect.maxY - size.height
        let requestedFrame = window.frameRect(forContentRect: newContentRect)
        window.setFrame(requestedFrame, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        let frameAfter = window.frame
        let contentViewFrame = window.contentView?.frame
        let hostingSubviewFrames = window.contentView?.subviews.map { $0.frame } ?? []
        Self.resizeLogger.debug(
            """
            applySize(\(String(describing: size), privacy: .public)): \
            before=\(String(describing: frameBefore), privacy: .public) \
            requested=\(String(describing: requestedFrame), privacy: .public) \
            after=\(String(describing: frameAfter), privacy: .public) \
            contentView=\(String(describing: contentViewFrame), privacy: .public) \
            subviews=\(String(describing: hostingSubviewFrames), privacy: .public)
            """
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Self.resizeLogger.debug(
                "applySize(\(String(describing: size), privacy: .public)) +0.3s: frame=\(String(describing: window.frame), privacy: .public)"
            )
        }
    }

    /// `RunOutProjectionView`'s outcome-driven height change doesn't reach `PopoverContentSizeKey`
    /// (its `TimelineView` doesn't renegotiate its own size with its ancestors when its content's
    /// shape changes — confirmed by a device capture showing zero resize activity across an
    /// observed transition). Sidestep the preference pipeline for this signal and ask AppKit
    /// directly for the hosting view's current ideal size instead.
    private func forceResize() {
        guard let hostingWindow else { return }
        // The SwiftUI state change that triggered this callback needs a run loop turn to reach
        // the underlying NSView tree before fittingSize/intrinsicContentSize reflect it.
        DispatchQueue.main.async {
            guard let contentView = hostingWindow.contentView else { return }
            contentView.layoutSubtreeIfNeeded()

            Self.resizeLogger.debug(
                "forceResize: contentView=\(String(describing: type(of: contentView)), privacy: .public) frame=\(String(describing: contentView.frame), privacy: .public) fittingSize=\(String(describing: contentView.fittingSize), privacy: .public) intrinsic=\(String(describing: contentView.intrinsicContentSize), privacy: .public)"
            )
            for (i, sub) in contentView.subviews.enumerated() {
                Self.resizeLogger.debug(
                    "forceResize: subview[\(i, privacy: .public)]=\(String(describing: type(of: sub)), privacy: .public) frame=\(String(describing: sub.frame), privacy: .public) fittingSize=\(String(describing: sub.fittingSize), privacy: .public) intrinsic=\(String(describing: sub.intrinsicContentSize), privacy: .public)"
                )
                for (j, subsub) in sub.subviews.enumerated() {
                    Self.resizeLogger.debug(
                        "forceResize: subview[\(i, privacy: .public)][\(j, privacy: .public)]=\(String(describing: type(of: subsub)), privacy: .public) frame=\(String(describing: subsub.frame), privacy: .public) fittingSize=\(String(describing: subsub.fittingSize), privacy: .public) intrinsic=\(String(describing: subsub.intrinsicContentSize), privacy: .public)"
                    )
                }
            }

            // Try, in order: the content view's own intrinsic size, its fitting size, then the
            // same two on its first subview — whichever first reports something real wins.
            let noIntrinsic = NSView.noIntrinsicMetric
            let candidates = [
                contentView.intrinsicContentSize,
                contentView.fittingSize,
                contentView.subviews.first?.intrinsicContentSize,
                contentView.subviews.first?.fittingSize,
            ].compactMap { $0 }
            guard
                let resolved = candidates.first(where: {
                    $0 != .zero && $0.width != noIntrinsic && $0.height != noIntrinsic
                })
            else {
                Self.resizeLogger.debug("forceResize: no usable size candidate, giving up")
                return
            }
            Self.resizeLogger.debug("forceResize: resolved=\(String(describing: resolved), privacy: .public)")
            measuredSize = resolved
            applySize(resolved, to: hostingWindow)
        }
    }

    private func refresh() {
        guard !service.isFetching && !refreshCoolingDown else { return }
        refreshCoolingDown = true
        Task { @MainActor in
            await service.fetchUsage()
            await statusMonitor?.refresh()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            refreshCoolingDown = false
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

            Picker(
                "",
                selection: Binding(
                    get: { service.pollingMinutes },
                    set: { service.updatePollingInterval($0) }
                )
            ) {
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

    private var isLockedOut: Bool {
        service.codeAttempts >= UsageService.maxCodeAttempts
    }

    var body: some View {
        Text("Paste the code from your browser:")
            .font(.subheadline)
            .foregroundStyle(.secondary)

        HStack(spacing: 4) {
            TextField("code#state", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { submit() }
                .disabled(isLockedOut)
            Button {
                if let str = NSPasteboard.general.string(forType: .string) {
                    code = str.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
            .disabled(isLockedOut)
        }

        if isLockedOut {
            Label("Too many failed attempts — click Sign in again to restart", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        HStack {
            Button("Cancel") {
                service.isAwaitingCode = false
            }
            .buttonStyle(.borderless)
            Spacer()
            Button("Submit") { submit() }
                .buttonStyle(.borderedProminent)
                .disabled(code.isEmpty || isLockedOut)
        }
    }

    private func submit() {
        let value = code
        Task {
            await service.submitOAuthCode(value)
            // Clear clipboard if it still contains the OAuth code so a one-time
            // secret doesn't linger in the pasteboard after successful authentication.
            if service.isAuthenticated,
                NSPasteboard.general.string(forType: .string) == value
            {
                NSPasteboard.general.clearContents()
            }
        }
    }
}

private struct UsageBucketRow: View {
    let label: String
    let bucket: UsageBucket?
    var forecastPct: Double? = nil
    var windowSeconds: TimeInterval? = nil

    @AppStorage(AppearanceDefaultsKey.showResetDivider) private var showResetDivider = false
    @AppStorage(AppearanceDefaultsKey.coloredResetDivider) private var coloredResetDivider = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text(percentageText)
                    .font(.subheadline)
                    .monospacedDigit()
                    .fontWeight(.semibold)
            }
            UsageProgressBar(
                value: (bucket?.utilization ?? 0) / 100.0,
                forecast: forecastPct,
                resetDivider: resetDividerInfo
            )
            if let resetDate = bucket?.resetsAtDate {
                Text("Resets \(resetDate, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var resetDividerInfo: (position: Double, state: ResetIndicatorState, colored: Bool)? {
        guard showResetDivider,
            let ws = windowSeconds,
            let pos = bucket?.resetPosition(windowSeconds: ws, now: Date()),
            let usagePct = bucket?.utilization
        else { return nil }
        // forecastPct is already gated on the "Show forecast" setting by the caller
        // and stored as a 0...1 fraction; resetIndicatorState wants 0...100.
        let state = resetIndicatorState(
            usagePct: usagePct,
            timeLeftFraction: 1.0 - pos,
            projectedPct: forecastPct.map { $0 * 100 }
        )
        return (position: pos, state: state, colored: coloredResetDivider)
    }

    private var percentageText: String {
        guard let pct = bucket?.utilization else { return "—" }
        return "\(Int(round(pct)))%"
    }
}

private struct UsageProgressBar: View {
    let value: Double
    var forecast: Double? = nil
    var resetDivider: (position: Double, state: ResetIndicatorState, colored: Bool)? = nil

    private let barHeight: CGFloat = 6
    private let markerHeight: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(value, 0), 1)
            let fillColor = colorForPct(clamped)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: geo.size.width, height: barHeight)

                if clamped > 0 {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [fillColor.opacity(0.75), fillColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * clamped, height: barHeight)
                }

                if let f = forecast {
                    let fx = min(max(f, 0), 1)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.purple)
                        .frame(width: 2, height: markerHeight)
                        .offset(x: geo.size.width * fx - 1)
                }

                if let r = resetDivider {
                    Rectangle()
                        .fill(r.state.color(colored: r.colored))
                        .frame(width: 2, height: markerHeight)
                        .offset(x: geo.size.width * r.position - 1)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(height: markerHeight)
    }
}

private struct ExtraUsageRow: View {
    let extra: ExtraUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Extra Usage")
                .font(.subheadline)
                .fontWeight(.medium)
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
                            .fontWeight(.semibold)
                    }
                }
                UsageProgressBar(value: (extra.utilization ?? 0) / 100.0)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
    case ..<0.60: return .mint
    case 0.60..<0.80: return .yellow
    case 0.80..<0.90: return .orange
    default: return .red
    }
}

// MARK: - Service Status section

public enum ServiceStatusDisplayState: Equatable {
    case loading
    case unavailable
    case ready(StatusSnapshot)

    public static func make(snapshot: StatusSnapshot?, lastError: StatusError?)
        -> ServiceStatusDisplayState
    {
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
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

// MARK: - Adaptive window sizing

private struct PopoverContentSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private final class WindowObservingView: NSView {
    var onWindow: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let w = window { onWindow?(w) }
    }
}

private struct PopoverWindowLocator: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> WindowObservingView {
        let v = WindowObservingView()
        v.onWindow = onWindow
        return v
    }
    func updateNSView(_ v: WindowObservingView, context: Context) {
        v.onWindow = onWindow
    }
}
