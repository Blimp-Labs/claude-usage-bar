import SwiftUI
import ServiceManagement

struct SettingsWindowContent: View {
    @ObservedObject var service: UsageService
    @ObservedObject var notificationService: NotificationService

    @AppStorage(AppearanceDefaultsKey.showResetDivider) private var showResetDivider = false
    @AppStorage(AppearanceDefaultsKey.coloredResetDivider) private var coloredResetDivider = true
    @AppStorage(AppearanceDefaultsKey.showForecast) private var showForecast = true
    @AppStorage(AppearanceDefaultsKey.showRunOutProjection) private var showRunOutProjection = false
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

            Section("Appearance") {
                Toggle("Show forecast marker", isOn: $showForecast)
                Toggle("Show run-out projection", isOn: $showRunOutProjection)
                Toggle("Show reset time divider", isOn: $showResetDivider)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Colored reset divider", isOn: $coloredResetDivider)
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

            Section {
                Text(appVersionString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, maxWidth: 400, maxHeight: 600)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            focusSettingsWindow()
        }
    }

    private var appVersionString: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Version \(shortVersion) (\(build))"
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
    private let controlSize: ControlSize
    private let useSwitchStyle: Bool

    init(
        controlSize: ControlSize = .regular,
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
        .controlSize(controlSize)

        if useSwitchStyle {
            baseToggle.toggleStyle(.switch)
        } else {
            baseToggle
        }
    }
}

@MainActor
final class LaunchAtLoginModel: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var isSupported: Bool
    @Published private(set) var message: String?

    private static let intentKey = "launchAtLoginIntent"

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
            UserDefaults.standard.set(enabled, forKey: Self.intentKey)
            isEnabled = SMAppService.mainApp.status == .enabled
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
