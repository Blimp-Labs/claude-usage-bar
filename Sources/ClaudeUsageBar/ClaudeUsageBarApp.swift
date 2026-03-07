import SwiftUI

@main
struct ClaudeUsageBarApp: App {
    @StateObject private var service = UsageService()
    @StateObject private var historyService = UsageHistoryService()
    @StateObject private var appUpdater = AppUpdater()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(
                service: service,
                historyService: historyService,
                appUpdater: appUpdater
            )
        } label: {
            RightClickableMenuBarLabel(
                image: service.isAuthenticated
                    ? renderIcon(pct5h: service.pct5h, pct7d: service.pct7d)
                    : renderUnauthenticatedIcon()
            )
                .task {
                    historyService.loadHistory()
                    service.historyService = historyService
                    service.startPolling()
                }
        }
        .menuBarExtraStyle(.window)
    }
}
