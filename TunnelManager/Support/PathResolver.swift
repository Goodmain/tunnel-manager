import Foundation

/// Resolves executables for spawned processes (design D1).
///
/// A GUI app launched from Finder/login inherits a minimal PATH and won't find
/// `aws-vault`/`aws`/`session-manager-plugin`. We learn the user's login-shell
/// PATH ONCE, cache it, and add Homebrew fallbacks. We then launch binaries by
/// absolute path with an injected PATH env — never via a shell (avoids quoting
/// the `--parameters` JSON).
enum PathResolver {
    static let homebrewFallbacks = ["/opt/homebrew/bin", "/usr/local/bin"]
    static let systemFallbacks = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// Probe the login shell for its PATH. Slow (~100ms) — call once off-main.
    static func resolveLoginPath() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -l login shell, -i interactive so rc files that export PATH run.
        process.arguments = ["-lic", "echo $PATH"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let probed = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !probed.isEmpty {
                return mergedPath(probed: probed)
            }
        } catch {
            NSLog("PATH probe failed: \(error.localizedDescription)")
        }
        return mergedPath(probed: nil)
    }

    /// Merge probed PATH with fallbacks, deduped, preserving order.
    private static func mergedPath(probed: String?) -> String {
        var seen = Set<String>()
        var dirs: [String] = []
        let probedDirs = probed?.split(separator: ":").map(String.init) ?? []
        for dir in homebrewFallbacks + probedDirs + systemFallbacks {
            if !dir.isEmpty, seen.insert(dir).inserted {
                dirs.append(dir)
            }
        }
        return dirs.joined(separator: ":")
    }

    /// Find an executable by name in the given PATH, plus an optional override dir
    /// that takes priority. Returns the absolute path if found and executable.
    static func find(_ binary: String, in path: String, overrideDirectory: String? = nil) -> String? {
        var dirs: [String] = []
        if let override = overrideDirectory, !override.isEmpty {
            dirs.append(override)
        }
        dirs.append(contentsOf: path.split(separator: ":").map(String.init))

        let fm = FileManager.default
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(binary)
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
