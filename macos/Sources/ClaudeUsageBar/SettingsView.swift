import SwiftUI
import ServiceManagement

struct SettingsWindowContent: View {
    @ObservedObject var service: UsageService
    @ObservedObject var notificationService: NotificationService
    @ObservedObject var appUpdater: AppUpdater

    @AppStorage(AppearanceDefaultsKey.showResetDivider) private var showResetDivider = false
    @AppStorage(AppearanceDefaultsKey.coloredResetDivider) private var coloredResetDivider = true
    @AppStorage(AppearanceDefaultsKey.showServiceStatus) private var showServiceStatus = false
    @AppStorage(AppearanceDefaultsKey.showOverlayWhenOperational) private var showOverlayWhenOperational = false
    @AppStorage(AppearanceDefaultsKey.statusPollMinutes) private var statusPollMinutes = StatusPollOptions.default

    var body: some View {
        Form {
            Section("General") {
                LaunchAtLoginToggle()

                Picker("Polling Interval", selection: Binding(
                    get: { service.pollingMinutes },
                    set: { service.updatePollingInterval($0) }
                )) {
                    ForEach(UsageService.pollingOptions, id: \.self) { mins in
                        Text(pollingOptionLabel(for: mins))
                            .tag(mins)
                    }
                }
            }

            Section("Notifications") {
                if !notificationService.isAvailable {
                    Text(notificationsUnavailableMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ThresholdSlider(
                    label: "5-hour window",
                    value: notificationService.threshold5h,
                    onChange: { notificationService.setThreshold5h($0) }
                )
                ThresholdSlider(
                    label: "7-day window",
                    value: notificationService.threshold7d,
                    onChange: { notificationService.setThreshold7d($0) }
                )
                ThresholdSlider(
                    label: "Extra usage",
                    value: notificationService.thresholdExtra,
                    onChange: { notificationService.setThresholdExtra($0) }
                )
            }
            .disabled(!notificationService.isAvailable)

            // Appearance: control the reset-time divider visibility and coloring on the menubar icon.
            // The divider shows when the usage bucket resets and changes color based on usage/time state.
            Section("Appearance") {
                // Toggle divider visibility on the menubar icon.
                Toggle("Show reset time divider", isOn: $showResetDivider)
                VStack(alignment: .leading, spacing: 4) {
                    // Toggle colored mode (semantic colors) vs. neutral mode (gray).
                    // Only meaningful when divider is shown, so disabled when divider is off.
                    // Colored: orange (warning), dark orange (critical), red (in usage limit).
                    // Neutral: always gray (secondary label color).
                    Toggle("Colored status", isOn: $coloredResetDivider)
                        .disabled(!showResetDivider)
                    Text("Off uses a single neutral color.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Service Status: optional indicator that polls https://status.claude.com and tints
            // the menubar Claude logo when Claude services are degraded. Default OFF.
            Section("Service Status") {
                Toggle("Show Claude service status", isOn: $showServiceStatus)
                Toggle("Show non-operational statuses on menubar", isOn: $showOverlayWhenOperational)
                    .disabled(!showServiceStatus)
                Picker("Poll interval", selection: $statusPollMinutes) {
                    ForEach(StatusPollOptions.minutes, id: \.self) { mins in
                        Text("\(mins) min").tag(mins)
                    }
                }
                .disabled(!showServiceStatus)
                Text("Polls https://status.claude.com (no auth, public endpoint).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if service.isAuthenticated {
                Section("Account") {
                    if let email = service.accountEmail {
                        Text(email)
                    }
                    Button("Sign Out") {
                        service.signOut()
                    }
                }
            }

            Section("Updates") {
                LabeledContent("Version") {
                    Text(Self.appVersion)
                        .textSelection(.enabled)
                }

                if appUpdater.isConfigured {
                    Toggle("Check daily for updates", isOn: $appUpdater.automaticallyChecksForUpdates)

                    Button("Check for Updates…") {
                        appUpdater.checkForUpdates()
                    }
                    .disabled(!appUpdater.canCheckForUpdates)

                    if let error = appUpdater.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else {
                    Text("This build has no update feed, so it cannot check for updates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, maxWidth: 400, maxHeight: 600)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            focusSettingsWindow()
        }
    }
}

extension SettingsWindowContent {
    static var appVersion: String {
        displayVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }

    /// `CFBundleVersion` is derived from the version string by build.sh
    /// (0.0.10 -> 10), so appending it would only restate the number beside it.
    /// The marketing version stands alone.
    static func displayVersion(_ shortVersion: String?) -> String {
        let trimmed = shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return "unknown" }
        return trimmed
    }
}

@MainActor
private func focusSettingsWindow() {
    DispatchQueue.main.async {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.last(where: { $0.isVisible && $0.canBecomeKey }) {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

struct LaunchAtLoginToggle: View {
    @StateObject private var model: LaunchAtLoginModel
    /// nil means "inherit whatever the container provides". Forcing a size here
    /// made this switch a different size from every other control in the
    /// Settings form, which sets the ambient size for its section.
    private let controlSize: ControlSize?
    private let useSwitchStyle: Bool

    init(
        controlSize: ControlSize? = nil,
        useSwitchStyle: Bool = false,
        bundleURL: URL = Bundle.main.bundleURL
    ) {
        _model = StateObject(
            wrappedValue: LaunchAtLoginModel(bundleURL: bundleURL)
        )
        self.controlSize = controlSize
        self.useSwitchStyle = useSwitchStyle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            toggle

            if let message = model.message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var toggle: some View {
        let baseToggle = Toggle("Launch at Login", isOn: Binding(
            get: { model.isEnabled },
            set: { model.setEnabled($0) }
        ))
        .disabled(!model.isSupported)

        let sized = baseToggle.modifier(OptionalControlSize(controlSize: controlSize))

        if useSwitchStyle {
            sized.toggleStyle(.switch)
        } else {
            sized
        }
    }
}

/// Applies `.controlSize` only when one was requested, so the default is to
/// inherit the container's.
private struct OptionalControlSize: ViewModifier {
    let controlSize: ControlSize?

    func body(content: Content) -> some View {
        if let controlSize {
            content.controlSize(controlSize)
        } else {
            content
        }
    }
}

@MainActor
final class LaunchAtLoginModel: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var isSupported: Bool
    @Published private(set) var message: String?

    init(bundleURL: URL = Bundle.main.bundleURL) {
        isSupported = supportsLaunchAtLoginManagement(appURL: bundleURL)

        guard isSupported else {
            message = "Install the app in Applications to manage launch at login."
            return
        }

        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        guard isSupported else { return }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isEnabled = enabled
            message = nil
        } catch {
            isEnabled = SMAppService.mainApp.status == .enabled
            message = "Could not update launch at login."
        }
    }
}

func supportsLaunchAtLoginManagement(
    appURL: URL = Bundle.main.bundleURL,
    installDirectories: [URL] = launchAtLoginInstallDirectories()
) -> Bool {
    let normalizedAppURL = appURL.resolvingSymlinksInPath().standardizedFileURL

    return installDirectories.contains { directory in
        let normalizedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let directoryPath = normalizedDirectory.path
        let appPath = normalizedAppURL.path

        return appPath == directoryPath || appPath.hasPrefix(directoryPath + "/")
    }
}

func launchAtLoginInstallDirectories(fileManager: FileManager = .default) -> [URL] {
    [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        fileManager.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory)
    ]
}

private struct ThresholdSlider: View {
    let label: String
    let value: Int
    let onChange: (Int) -> Void

    var body: some View {
        LabeledContent {
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { onChange(Int($0)) }
                ),
                in: 0...100,
                step: 5
            )
        } label: {
            Text(label)
            Text(value > 0 ? "\(value)%" : "Off")
                .foregroundStyle(.secondary)
        }
        .alignmentGuide(.firstTextBaseline) { d in
            d[VerticalAlignment.center]
        }
    }
}
