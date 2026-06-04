import Foundation
import Combine

/// Owns the list of connection definitions and persists them to UserDefaults
/// as a single JSON-encoded array (design D8). Autosaves on any mutation.
@MainActor
final class ConnectionStore: ObservableObject {
    @Published var connections: [Connection]

    private let defaults: UserDefaults
    private let storageKey = "connections.v1"
    private var cancellables = Set<AnyCancellable>()

    /// Connections ordered A-Z by name (case-insensitive) for display. Storage
    /// order is unchanged.
    var sortedConnections: [Connection] {
        connections.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.connections = Self.load(from: defaults, key: storageKey)

        // Autosave on mutation (design D8) — debounced to coalesce rapid edits.
        $connections
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] value in
                self?.persist(value)
            }
            .store(in: &cancellables)
    }

    // MARK: - Validation

    enum ValidationError: LocalizedError {
        case emptyField(field: String)
        case portOutOfRange(field: String)
        case duplicateLocalPort(Int)

        var errorDescription: String? {
            switch self {
            case .emptyField(let field):
                return "\(field) is required."
            case .portOutOfRange(let field):
                return "\(field) must be between 1 and 65535."
            case .duplicateLocalPort(let port):
                return "Local port \(port) is already used by another connection."
            }
        }
    }

    /// Validates a connection against the rules in connection-management spec.
    /// Returns an optional non-blocking warning string (e.g. privileged port).
    @discardableResult
    func validate(_ connection: Connection, isNew: Bool) throws -> String? {
        // Required fields must be non-empty (whitespace-only counts as empty).
        let required: [(String, String)] = [
            ("Name", connection.name),
            ("AWS profile", connection.awsProfile),
            ("ECS cluster", connection.ecsCluster),
            ("DB host", connection.dbHost),
        ]
        for (label, value) in required
        where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError.emptyField(field: label)
        }
        guard (1...65535).contains(connection.remotePort) else {
            throw ValidationError.portOutOfRange(field: "Remote port")
        }
        guard (1...65535).contains(connection.localPort) else {
            throw ValidationError.portOutOfRange(field: "Local port")
        }
        let duplicate = connections.contains {
            $0.localPort == connection.localPort && $0.id != connection.id
        }
        if duplicate {
            throw ValidationError.duplicateLocalPort(connection.localPort)
        }
        if connection.localPort < 1024 {
            return "Local port \(connection.localPort) is privileged (<1024) and may require elevated privileges to bind."
        }
        return nil
    }

    // MARK: - CRUD

    func add(_ connection: Connection) {
        connections.append(connection)
    }

    func update(_ connection: Connection) {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[index] = connection
    }

    func delete(id: UUID) {
        connections.removeAll { $0.id == id }
    }

    func connection(id: UUID) -> Connection? {
        connections.first { $0.id == id }
    }

    // MARK: - Persistence

    private func persist(_ value: [Connection]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func load(from defaults: UserDefaults, key: String) -> [Connection] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Connection].self, from: data)
        else { return [] }
        return decoded
    }
}
