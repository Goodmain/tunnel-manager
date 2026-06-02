import XCTest
@testable import TunnelManager

@MainActor
final class ConnectionStoreValidationTests: XCTestCase {
    private func makeStore() -> ConnectionStore {
        // Isolated, empty UserDefaults so tests are order-independent and touch no real state.
        let suite = "tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return ConnectionStore(defaults: defaults)
    }

    private func valid(localPort: Int = 5432) -> Connection {
        Connection(name: "DB", awsProfile: "prof", ecsCluster: "cluster",
                   dbHost: "db.example.com", remotePort: 5432, localPort: localPort, environment: .dev)
    }

    func testBlankNameThrows() {
        let store = makeStore()
        var c = valid(); c.name = "   "
        XCTAssertThrowsError(try store.validate(c, isNew: true))
    }

    func testBlankHostThrows() {
        let store = makeStore()
        var c = valid(); c.dbHost = ""
        XCTAssertThrowsError(try store.validate(c, isNew: true))
    }

    func testPortOutOfRangeThrows() {
        let store = makeStore()
        var c = valid(); c.remotePort = 70000
        XCTAssertThrowsError(try store.validate(c, isNew: true))
    }

    func testDuplicateLocalPortThrows() {
        let store = makeStore()
        store.add(valid(localPort: 5432))
        let dup = valid(localPort: 5432)  // different id, same local port
        XCTAssertThrowsError(try store.validate(dup, isNew: true))
    }

    func testPrivilegedPortWarnsWithoutThrowing() throws {
        let store = makeStore()
        let warning = try store.validate(valid(localPort: 80), isNew: true)
        XCTAssertNotNil(warning)
    }

    func testValidConnectionNoWarning() throws {
        let store = makeStore()
        let warning = try store.validate(valid(localPort: 5432), isNew: true)
        XCTAssertNil(warning)
    }
}
