import SwiftUI
import AppKit
import Combine

@main
struct ClaudeUsageBarApp: App {
    @StateObject private var service = UsageService()
    @StateObject private var historyService = UsageHistoryService()
    @StateObject private var notificationService = NotificationService()
    @StateObject private var appUpdater = AppUpdater()
    @StateObject private var dockTileUpdater = DockTileUpdater()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(
                service: service,
                historyService: historyService,
                notificationService: notificationService,
                appUpdater: appUpdater
            )
        } label: {
            Image(nsImage: service.isAuthenticated
                ? renderIcon(pct5h: service.pct5h, pct7d: service.pct7d)
                : renderUnauthenticatedIcon()
            )
                .task {
                    // Auto-mark existing users as setup-complete
                    if service.isAuthenticated && !UserDefaults.standard.bool(forKey: "setupComplete") {
                        UserDefaults.standard.set(true, forKey: "setupComplete")
                    }
                    historyService.loadHistory()
                    service.historyService = historyService
                    service.notificationService = notificationService
                    service.startPolling()
                    dockTileUpdater.bind(to: service)
                }
                .onReceive(service.objectWillChange) { _ in
                    DispatchQueue.main.async { dockTileUpdater.update(service: service) }
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
}

// MARK: - Dock Tile Updater

@MainActor
class DockTileUpdater: ObservableObject {
    private var cancellables = Set<AnyCancellable>()

    func bind(to service: UsageService) {
        update(service: service)
    }

    func update(service: UsageService) {
        let dockTile = NSApp.dockTile

        if !service.isAuthenticated {
            dockTile.badgeLabel = nil
            dockTile.contentView = nil
            dockTile.display()
            return
        }

        let pct5h = Int(round(min(max(service.pct5h, 0), 1) * 100))
        let pct7d = Int(round(min(max(service.pct7d, 0), 1) * 100))

        let view = DockTileContentView(pct5h: pct5h, pct7d: pct7d)
        let size = dockTile.size
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)

        dockTile.contentView = hostingView
        dockTile.display()
    }
}

// MARK: - Dock Tile SwiftUI View

struct DockTileContentView: View {
    let pct5h: Int
    let pct7d: Int

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Black background filling the entire icon
                RoundedRectangle(cornerRadius: geo.size.width * 0.185)
                    .fill(Color.black)
                    .overlay(
                        RoundedRectangle(cornerRadius: geo.size.width * 0.185)
                            .stroke(Color.white.opacity(0.3), lineWidth: 2)
                    )

                // Usage text centered
                VStack(spacing: 6) {
                    usageRow(label: "5h", pct: pct5h)
                    usageRow(label: "7d", pct: pct7d)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func usageRow(label: String, pct: Int) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 24, weight: .medium, design: .monospaced))
                .foregroundColor(Color.orange.opacity(0.6))
            Text("\(pct)%")
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .foregroundColor(.orange)
        }
    }
}
