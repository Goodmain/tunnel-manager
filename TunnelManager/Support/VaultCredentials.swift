import Foundation

/// Temporary AWS credentials obtained once per profile from aws-vault and injected
/// into the tunnel/ECS commands, so those run as plain `aws` without re-invoking
/// aws-vault (one credential prompt per profile, not per tunnel).
struct VaultCredentials: Sendable {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String?
    let region: String?
    let expiration: Date?

    /// Considered expired ~1 min before the real expiry, to refresh proactively.
    var isExpired: Bool {
        guard let expiration else { return false }
        return Date() >= expiration.addingTimeInterval(-60)
    }

    /// Parse from the stdout of `aws-vault exec <profile> -- env` (KEY=VALUE lines).
    static func parse(env output: String) -> VaultCredentials? {
        var map: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            map[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        guard let ak = map["AWS_ACCESS_KEY_ID"], !ak.isEmpty,
              let sk = map["AWS_SECRET_ACCESS_KEY"], !sk.isEmpty else { return nil }
        var exp: Date?
        if let raw = map["AWS_CREDENTIAL_EXPIRATION"] {
            exp = ISO8601DateFormatter().date(from: raw)
        }
        return VaultCredentials(
            accessKeyId: ak,
            secretAccessKey: sk,
            sessionToken: map["AWS_SESSION_TOKEN"],
            region: map["AWS_REGION"] ?? map["AWS_DEFAULT_REGION"],
            expiration: exp
        )
    }

    func withRegion(_ region: String) -> VaultCredentials {
        VaultCredentials(accessKeyId: accessKeyId, secretAccessKey: secretAccessKey,
                         sessionToken: sessionToken, region: region, expiration: expiration)
    }

    /// Environment variables to inject into the spawned `aws` processes.
    var environment: [String: String] {
        var e = ["AWS_ACCESS_KEY_ID": accessKeyId, "AWS_SECRET_ACCESS_KEY": secretAccessKey]
        if let sessionToken { e["AWS_SESSION_TOKEN"] = sessionToken }
        if let region { e["AWS_REGION"] = region; e["AWS_DEFAULT_REGION"] = region }
        return e
    }
}
