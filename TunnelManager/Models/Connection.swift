import Foundation
import SwiftUI

/// Deployment environment for a connection. Drives badge color in the UI.
enum DeploymentEnvironment: String, Codable, CaseIterable, Identifiable {
    case prod
    case staging
    case dev

    var id: String { rawValue }

    var label: String {
        switch self {
        case .prod: return "Prod"
        case .staging: return "Staging"
        case .dev: return "Dev"
        }
    }

    /// Badge color: prod = red, staging = blue, dev = green.
    var color: Color {
        switch self {
        case .prod: return .red
        case .staging: return .blue
        case .dev: return .green
        }
    }
}

/// A single tunnel definition. Persisted to UserDefaults as JSON (see `ConnectionStore`).
/// Holds no secrets — DB auth happens in the user's DB client over the forwarded port.
struct Connection: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var awsProfile: String
    var ecsCluster: String
    var dbHost: String
    var remotePort: Int
    var localPort: Int
    var environment: DeploymentEnvironment

    init(
        id: UUID = UUID(),
        name: String = "",
        awsProfile: String = "",
        ecsCluster: String = "",
        dbHost: String = "",
        remotePort: Int = 5432,
        localPort: Int = 5432,
        environment: DeploymentEnvironment = .dev
    ) {
        self.id = id
        self.name = name
        self.awsProfile = awsProfile
        self.ecsCluster = ecsCluster
        self.dbHost = dbHost
        self.remotePort = remotePort
        self.localPort = localPort
        self.environment = environment
    }

    /// `cluster:remotePort→localPort` summary shown in a row.
    var summary: String {
        "\(ecsCluster):\(remotePort)→\(localPort)"
    }

    /// Fields whose change requires restarting a live tunnel (see design D15).
    func tunnelAffectingFieldsDiffer(from other: Connection) -> Bool {
        localPort != other.localPort
            || remotePort != other.remotePort
            || ecsCluster != other.ecsCluster
            || dbHost != other.dbHost
            || awsProfile != other.awsProfile
    }
}
