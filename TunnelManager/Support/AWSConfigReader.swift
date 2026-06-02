import Foundation
import Combine

/// Parses `~/.aws/config` into the list of AWS profile names (aws-profile-discovery).
/// Pure, testable parsing — no I/O state. Recognizes `[default]` and `[profile NAME]`
/// only; ignores `[sso-session ...]`, `[services ...]`, bare names, comments, and
/// key=value lines (design D2).
enum AWSConfigReader {
    /// Absolute path to the AWS config file (expands `~` via the home directory).
    static var configURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".aws")
            .appendingPathComponent("config")
    }

    /// Profile names sorted A–Z (case-insensitive), deduped. Empty if the file is
    /// absent/unreadable (D2/D4).
    static func profiles() -> [String] {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return []
        }
        return parse(text).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Extract profile names from config text. Exposed for testing.
    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), line.hasSuffix("]") else { continue }
            // Strip the surrounding brackets and collapse internal whitespace.
            let inner = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            let name: String?
            if inner == "default" {
                name = "default"
            } else if inner.hasPrefix("profile ") {
                name = inner.dropFirst("profile ".count).trimmingCharacters(in: .whitespaces)
            } else {
                name = nil  // sso-session, services, bare [name], etc.
            }
            if let name, !name.isEmpty, seen.insert(name).inserted {
                result.append(name)
            }
        }
        return result
    }
}

/// Holds the discovered profile list for the UI; refreshed on popover open (D1/D3).
@MainActor
final class AWSProfileStore: ObservableObject {
    @Published private(set) var profiles: [String] = []

    func refresh() {
        Task { [weak self] in
            let list = await Task.detached(priority: .userInitiated) {
                AWSConfigReader.profiles()
            }.value
            self?.profiles = list
        }
    }
}
