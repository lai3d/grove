import AppKit
import SwiftUI

/// Makes repository windows native tabs of each other: new windows join the key window's tab group.
struct WindowTabbing: NSViewRepresentable {
    @AppStorage("openInTabs") private var enabled = true

    static let identifier = "grove.repository"

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { configure(v.window, coordinator: context.coordinator) }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { configure(v.window, coordinator: context.coordinator) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var joined = false
    }

    private func configure(_ window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        window.tabbingIdentifier = Self.identifier
        window.tabbingMode = enabled ? .preferred : .automatic
        guard enabled, !coordinator.joined else { return }
        coordinator.joined = true
        // Join an existing Grove window (prefer the one the user was in) unless already tabbed.
        guard (window.tabbedWindows?.count ?? 1) <= 1 else { return }
        let others = NSApp.windows.filter {
            $0 !== window && $0.isVisible && $0.tabbingIdentifier == Self.identifier && !($0 is NSPanel)
        }
        guard let host = others.first(where: { $0 === NSApp.mainWindow }) ?? others.first else { return }
        host.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }
}
