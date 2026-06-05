import AppKit

// AppKit entry point (no SwiftUI scene), so the app launches straight to the
// status bar with no window. `AppDelegate` builds the status item, popover, and
// (on demand) the management window. A SwiftUI `Settings` scene previously
// surfaced an empty "<App> Settings" window at launch — removed.
//
// `main.swift` top-level code runs on the main thread; the strong `delegate`
// reference keeps it alive for the process lifetime (NSApplication.delegate is weak).
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let appDelegate = AppDelegate()
    application.delegate = appDelegate
    application.setActivationPolicy(.accessory)   // menu-bar only (with LSUIElement)
    _ = appDelegate                               // keep the delegate alive
    application.run()
}
