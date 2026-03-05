import SwiftUI

@main
struct ClaudeUsageBarApp: App {
    @StateObject private var historyService: UsageHistoryService
    @StateObject private var service: UsageService

    init() {
        let hs = UsageHistoryService()
        _historyService = StateObject(wrappedValue: hs)
        _service = StateObject(wrappedValue: UsageService(historyService: hs))
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(service: service, historyService: historyService)
        } label: {
            Image(nsImage: service.isAuthenticated
                ? renderIcon(pct5h: service.pct5h, pct7d: service.pct7d)
                : renderUnauthenticatedIcon()
            )
        }
        .menuBarExtraStyle(.window)
    }
}
