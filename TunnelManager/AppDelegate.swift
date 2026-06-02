import AppKit
import SwiftUI
import Combine

/// Owns the menu bar status item and popover (menu-bar-presentation capability).
/// Creates the shared stores and injects them into the SwiftUI popover.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    private let connectionStore = ConnectionStore()
    private let settingsStore = SettingsStore()
    private lazy var tunnelManager = TunnelManager(store: connectionStore, settings: settingsStore)

    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[TunnelManager] applicationDidFinishLaunching")
        // Menu bar agent: no Dock icon, lives as an accessory (also enforced by LSUIElement).
        NSApp.setActivationPolicy(.accessory)
        tunnelManager.configure()
        setupStatusItem()
        setupPopover()

        // Update the icon whenever the active-tunnel count changes (D19).
        tunnelManager.$activeCount
            .receive(on: RunLoop.main)
            .sink { [weak self] count in self?.updateIcon(activeCount: count) }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Tear down all tunnels synchronously so no plugin/port is orphaned (D2).
        tunnelManager.terminateAll()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        updateIcon(activeCount: 0)
        NSLog("[TunnelManager] status item created, button=%@", statusItem.button != nil ? "yes" : "nil")
    }

    /// Active = non-template green image; inactive = template (adapts to light/dark) (D19).
    private func updateIcon(activeCount: Int) {
        guard let button = statusItem.button else { return }
        let symbolName = activeCount > 0 ? "point.3.filled.connected.trianglepath.dotted" : "point.3.connected.trianglepath.dotted"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Tunnel Manager")
        if activeCount > 0 {
            image?.isTemplate = false
            button.contentTintColor = .systemGreen
            button.title = " \(activeCount)"
        } else {
            image?.isTemplate = true
            button.contentTintColor = nil
            button.title = ""
        }
        button.image = image
        // Fallback so the item is never zero-width/invisible even if the symbol fails to load.
        if image == nil && button.title.isEmpty {
            button.title = "TM"
        }
        button.imagePosition = button.title.isEmpty ? .imageOnly : .imageLeading
    }

    // MARK: - Popover

    private func setupPopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 460)
        let root = PopoverView()
            .environmentObject(connectionStore)
            .environmentObject(settingsStore)
            .environmentObject(tunnelManager)
        popover.contentViewController = NSHostingController(rootView: root)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
