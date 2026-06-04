import SwiftUI
import Combine

/// Which section the management window should show.
enum ManagementSection {
    case connections
    case settings
    case addConnection
}

/// Shared state the management window observes so the menu bar can drive it.
@MainActor
final class ManagementState: ObservableObject {
    @Published var section: ManagementSection = .connections
    /// Bumped to request presenting the add-connection sheet.
    @Published var addToken: Int = 0
}

/// Lets SwiftUI menu-bar views open the management window. `open` is wired by
/// `AppDelegate` to the window controller.
@MainActor
final class AppCoordinator: ObservableObject {
    var open: (ManagementSection) -> Void = { _ in }
    var quit: () -> Void = { NSApp.terminate(nil) }
}
