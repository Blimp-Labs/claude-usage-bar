import AppKit
import SwiftUI

/// Wraps the menu bar icon in an NSView so right-click can be intercepted.
/// A left-click still opens the MenuBarExtra window as normal.
/// A right-click shows a minimal context menu with a Quit action.
struct RightClickableMenuBarLabel: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> MenuBarIconView {
        MenuBarIconView()
    }

    func updateNSView(_ nsView: MenuBarIconView, context: Context) {
        nsView.image = image
    }

    final class MenuBarIconView: NSView {
        var image: NSImage? { didSet { needsDisplay = true } }

        override var intrinsicContentSize: NSSize {
            image?.size ?? NSSize(width: 22, height: 18)
        }

        override func draw(_ dirtyRect: NSRect) {
            image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        }

        override func rightMouseDown(with event: NSEvent) {
            let menu = NSMenu()
            menu.addItem(NSMenuItem(
                title: "Quit Claude Usage Bar",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            ))
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}
