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
    private let profileStore = AWSProfileStore()
    private lazy var tunnelManager = TunnelManager(store: connectionStore, settings: settingsStore)

    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[TunnelManager] applicationDidFinishLaunching")
        // Menu bar agent: no Dock icon, lives as an accessory (also enforced by LSUIElement).
        NSApp.setActivationPolicy(.accessory)
        tunnelManager.configure()
        profileStore.refresh()
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
        statusItem.button?.imageScaling = .scaleProportionallyDown
        updateIcon(activeCount: 0)
        NSLog("[TunnelManager] status item created, button=%@", statusItem.button != nil ? "yes" : "nil")
    }

    /// Custom three-dot glyph (template) from the asset catalog; tinted green when
    /// any tunnel is active. Template images accept `contentTintColor`, so one
    /// image covers both states (D19).
    private func updateIcon(activeCount: Int) {
        guard let button = statusItem.button else { return }
        // Prefer the bundled StatusBarIcon; fall back to an SF Symbol, then text.
        let base = NSImage(named: "StatusBarIcon")
            ?? NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted",
                       accessibilityDescription: "Tunnel Manager")
        base?.size = NSSize(width: 18, height: 18)

        if activeCount > 0 {
            // Status-bar buttons IGNORE contentTintColor for template images, so
            // bake the green into a non-template image instead.
            button.image = base.map { Self.tinted($0, with: .systemGreen) }
            button.contentTintColor = nil
            button.title = " \(activeCount)"
        } else {
            base?.isTemplate = true   // adapts black/white to the menu bar
            button.image = base
            button.contentTintColor = nil
            button.title = ""
        }
        if button.image == nil && button.title.isEmpty {
            button.title = "TM"   // never zero-width/invisible
        }
        button.imagePosition = button.title.isEmpty ? .imageOnly : .imageLeading
    }

    /// Returns a non-template copy of `image` with every opaque pixel filled `color`.
    /// Used for the active (green) status-bar glyph, since status-bar buttons drop
    /// contentTintColor on template images.
    private static func tinted(_ image: NSImage, with color: NSColor) -> NSImage {
        let result = NSImage(size: image.size)
        result.lockFocus()
        image.draw(at: .zero, from: NSRect(origin: .zero, size: image.size),
                   operation: .sourceOver, fraction: 1.0)
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        result.unlockFocus()
        result.isTemplate = false
        return result
    }

    // MARK: - Popover

    private func setupPopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 460)
        let root = PopoverView()
            .environmentObject(connectionStore)
            .environmentObject(settingsStore)
            .environmentObject(tunnelManager)
            .environmentObject(profileStore)
        popover.contentViewController = NSHostingController(rootView: root)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            profileStore.refresh()  // pick up profiles added since launch (D3)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
