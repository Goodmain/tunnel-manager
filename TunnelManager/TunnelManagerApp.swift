import SwiftUI

/// App entry. Menu bar only (no Dock icon via LSUIElement). The real UI lives in
/// the popover wired up by `AppDelegate`; the `Settings` scene stays empty.
@main
struct TunnelManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
