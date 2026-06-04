import AppKit
import SwiftUI

/// Owns the single reusable management window (settings + connection CRUD).
/// Created lazily; hidden (not released) on close so state is reused.
@MainActor
final class ManagementWindowController {
    private var window: NSWindow?
    private let state = ManagementState()

    private let connectionStore: ConnectionStore
    private let settingsStore: SettingsStore
    private let tunnelManager: TunnelManager
    private let profileStore: AWSProfileStore

    init(connectionStore: ConnectionStore, settingsStore: SettingsStore,
         tunnelManager: TunnelManager, profileStore: AWSProfileStore) {
        self.connectionStore = connectionStore
        self.settingsStore = settingsStore
        self.tunnelManager = tunnelManager
        self.profileStore = profileStore
    }

    /// Open (creating if needed) on the given section and focus the window.
    func show(_ section: ManagementSection) {
        if section == .addConnection {
            state.section = .connections
            state.addToken &+= 1          // triggers the add sheet
        } else {
            state.section = section
        }

        if window == nil {
            let root = ManagementView()
                .environmentObject(connectionStore)
                .environmentObject(settingsStore)
                .environmentObject(tunnelManager)
                .environmentObject(profileStore)
                .environmentObject(state)
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 470),
                styleMask: [.titled, .closable, .miniaturizable],   // no .resizable → fixed size
                backing: .buffered, defer: false
            )
            win.title = "Tunnel Manager"
            win.contentViewController = NSHostingController(rootView: root)
            win.isReleasedWhenClosed = false   // reuse; don't deallocate on close
            win.center()
            window = win
        }

        // Accessory (LSUIElement) apps must activate to bring a window to front.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
