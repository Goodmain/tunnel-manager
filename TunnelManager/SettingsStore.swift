import Foundation
import Combine
import ServiceManagement

/// Global preferences (app-settings capability). Backed by UserDefaults so the
/// values are reachable from `TunnelManager` (not just SwiftUI `@AppStorage`).
@MainActor
final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults

    @Published var defaultAWSProfile: String {
        didSet { defaults.set(defaultAWSProfile, forKey: Keys.defaultProfile) }
    }

    /// Reconnect delay in seconds (design D3/D14).
    @Published var reconnectDelay: Double {
        didSet { defaults.set(reconnectDelay, forKey: Keys.reconnectDelay) }
    }

    @Published var autoReconnect: Bool {
        didSet { defaults.set(autoReconnect, forKey: Keys.autoReconnect) }
    }

    /// Max consecutive failed reconnects before a tunnel settles in `failed`.
    @Published var maxReconnectAttempts: Int {
        didSet { defaults.set(maxReconnectAttempts, forKey: Keys.maxReconnectAttempts) }
    }

    /// When true, kill whatever process is holding the local port before starting,
    /// instead of failing with an orphan message (network-drop recovery follow-up).
    @Published var killOrphanOnPort: Bool {
        didSet { defaults.set(killOrphanOnPort, forKey: Keys.killOrphanOnPort) }
    }

    /// Optional override directory for aws-vault / aws / session-manager-plugin (design D1).
    @Published var binaryDirectoryOverride: String {
        didSet { defaults.set(binaryDirectoryOverride, forKey: Keys.binaryDir) }
    }

    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin(launchAtLogin) }
    }

    private enum Keys {
        static let defaultProfile = "settings.defaultProfile"
        static let reconnectDelay = "settings.reconnectDelay"
        static let autoReconnect = "settings.autoReconnect"
        static let binaryDir = "settings.binaryDirectoryOverride"
        static let killOrphanOnPort = "settings.killOrphanOnPort"
        static let maxReconnectAttempts = "settings.maxReconnectAttempts"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.defaultAWSProfile = defaults.string(forKey: Keys.defaultProfile) ?? ""
        self.reconnectDelay = defaults.object(forKey: Keys.reconnectDelay) as? Double ?? 5.0
        self.autoReconnect = defaults.object(forKey: Keys.autoReconnect) as? Bool ?? true
        self.killOrphanOnPort = defaults.object(forKey: Keys.killOrphanOnPort) as? Bool ?? false
        self.maxReconnectAttempts = defaults.object(forKey: Keys.maxReconnectAttempts) as? Int ?? 5
        self.binaryDirectoryOverride = defaults.string(forKey: Keys.binaryDir) ?? ""
        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    /// Launch at login via ServiceManagement (app-settings spec). Requires the
    /// app to be code-signed and run from a stable path (design D13).
    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("Launch-at-login toggle failed: \(error.localizedDescription)")
        }
    }
}
