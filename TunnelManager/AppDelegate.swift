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
            .combineLatest(tunnelManager.$connectingCount)
            .receive(on: RunLoop.main)
            .sink { [weak self] active, connecting in
                self?.updateIcon(activeCount: active, connectingCount: connecting)
            }
            .store(in: &cancellables)
    }

    /// Guarantee teardown finishes before the app exits (D1). Cancel respawn
    /// sources on the main actor, then kill process groups off-main (escalating
    /// to SIGKILL), then allow termination. Capped so quit never hangs.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let live = tunnelManager.prepareForQuit()
        guard !live.isEmpty else { return .terminateNow }

        DispatchQueue.global(qos: .userInitiated).async {
            let group = DispatchGroup()
            for process in live {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    process.terminateGroupBlocking(timeout: 1.0)
                    group.leave()
                }
            }
            // Overall budget: quit regardless after this, so a wedged child can't hang it.
            _ = group.wait(timeout: .now() + 1.5)
            DispatchQueue.main.async {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Fallback for termination paths that skip applicationShouldTerminate.
        // Idempotent after prepareForQuit (empty process map second time).
        tunnelManager.terminateAll()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        statusItem.button?.imageScaling = .scaleProportionallyDown
        updateIcon(activeCount: 0, connectingCount: 0)
        NSLog("[TunnelManager] status item created, button=%@", statusItem.button != nil ? "yes" : "nil")
    }

    /// Custom three-dot glyph (template) from the asset catalog; tinted green when
    /// any tunnel is active. Template images accept `contentTintColor`, so one
    /// image covers both states (D19).
    /// Color precedence: any connecting/reconnecting → orange; else any connected →
    /// green; else idle (template). Status-bar buttons ignore contentTintColor on
    /// template images, so colors are baked into a non-template image.
    private func updateIcon(activeCount: Int, connectingCount: Int) {
        guard let button = statusItem.button else { return }
        let base = NSImage(named: "StatusBarIcon")
            ?? NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted",
                       accessibilityDescription: "Tunnel Manager")
        base?.size = NSSize(width: 18, height: 18)

        if connectingCount > 0 {
            button.image = base.map { Self.tinted($0, with: .systemOrange) }
            button.contentTintColor = nil
            button.title = activeCount > 0 ? " \(activeCount)" : ""
        } else if activeCount > 0 {
            button.image = base.map { Self.tinted($0, with: .systemGreen) }
            button.contentTintColor = nil
            button.title = " \(activeCount)"
        } else {
            base?.isTemplate = true   // idle: adapts black/white to the menu bar
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
