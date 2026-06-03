import Foundation

/// Appends log lines to `~/Library/Logs/TunnelManager/TunnelManager.log` with
/// size-based rotation. Best-effort: I/O errors are swallowed so logging can
/// never crash or block the app. All file work runs on a serial queue.
final class FileLogger: @unchecked Sendable {
    static let shared = FileLogger()

    let logDirectoryURL: URL
    let logFileURL: URL
    private let rotatedURL: URL
    private let maxBytes: Int = 1_000_000   // ~1 MB, then rotate
    private let queue = DispatchQueue(label: "tunnelmanager.filelogger", qos: .utility)

    private init() {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        logDirectoryURL = base.appendingPathComponent("Logs/TunnelManager", isDirectory: true)
        logFileURL = logDirectoryURL.appendingPathComponent("TunnelManager.log")
        rotatedURL = logDirectoryURL.appendingPathComponent("TunnelManager.log.1")
    }

    /// Append one line (a newline is added). Safe to call from any thread.
    func write(_ line: String) {
        queue.async { [self] in
            let fm = FileManager.default
            try? fm.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: logFileURL.path) {
                fm.createFile(atPath: logFileURL.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: logFileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            if let data = (line + "\n").data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
            rotateIfNeeded(fm: fm, handle: handle)
        }
    }

    /// Rotate when the file exceeds the cap: current → `.log.1` (replacing any prior).
    private func rotateIfNeeded(fm: FileManager, handle: FileHandle) {
        guard let size = try? handle.offset(), size > UInt64(maxBytes) else { return }
        try? handle.close()
        try? fm.removeItem(at: rotatedURL)            // drop the older backup
        try? fm.moveItem(at: logFileURL, to: rotatedURL)
        fm.createFile(atPath: logFileURL.path, contents: nil)
    }
}
