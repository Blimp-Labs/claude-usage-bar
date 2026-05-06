import SwiftUI
import AppKit

@main
struct ClaudeUsageBarApp: App {
    @StateObject private var service = UsageService()
    @StateObject private var historyService = UsageHistoryService()
    @StateObject private var notificationService = NotificationService()
    @StateObject private var appUpdater = AppUpdater()

    @AppStorage(AppearanceDefaultsKey.showResetDivider) private var showResetDivider = false
    @AppStorage(AppearanceDefaultsKey.coloredResetDivider) private var coloredResetDivider = true

    var body: some Scene {
        MenuBarExtra {
            PopoverView(
                service: service,
                historyService: historyService,
                notificationService: notificationService,
                appUpdater: appUpdater
            )
        } label: {
            Image(nsImage: iconImage())
                .task {
                    // Auto-mark existing users as setup-complete
                    if service.isAuthenticated && !UserDefaults.standard.bool(forKey: "setupComplete") {
                        UserDefaults.standard.set(true, forKey: "setupComplete")
                    }
                    historyService.loadHistory()
                    service.historyService = historyService
                    service.notificationService = notificationService
                    service.startPolling()
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsWindowContent(
                service: service,
                notificationService: notificationService
            )
        }
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
    }

    @MainActor
    private func iconImage() -> NSImage {
        guard service.isAuthenticated else { return renderUnauthenticatedIcon() }
        let now = Date()
        let pos5 = service.usage?.fiveHour?.resetPosition(windowSeconds: 5 * 3600, now: now)
        let pos7 = service.usage?.sevenDay?.resetPosition(windowSeconds: 7 * 24 * 3600, now: now)
        let usagePct5 = service.pct5h * 100
        let usagePct7 = service.pct7d * 100
        let state5 = resetIndicatorState(
            usagePct: usagePct5,
            timeLeftFraction: 1.0 - (pos5 ?? .zero)
        )
        let state7 = resetIndicatorState(
            usagePct: usagePct7,
            timeLeftFraction: 1.0 - (pos7 ?? .zero)
        )
        return renderIcon(MenuBarIconParams(
            pct5h: service.pct5h,
            pct7d: service.pct7d,
            resetPos5h: pos5,
            state5h: state5,
            resetPos7d: pos7,
            state7d: state7,
            showResetDivider: showResetDivider,
            coloredResetDivider: coloredResetDivider
        ))
    }
}
