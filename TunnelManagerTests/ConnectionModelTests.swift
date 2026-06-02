import XCTest
@testable import TunnelManager

final class ConnectionModelTests: XCTestCase {
    private func base() -> Connection {
        Connection(name: "DB", awsProfile: "prof", ecsCluster: "cluster",
                   dbHost: "db.example.com", remotePort: 5432, localPort: 5432, environment: .prod)
    }

    func testSummaryFormat() {
        XCTAssertEqual(base().summary, "cluster:5432→5432")
    }

    func testTunnelAffectingDiffOnPortChange() {
        var other = base()
        other.localPort = 5433
        XCTAssertTrue(base().tunnelAffectingFieldsDiffer(from: other))
    }

    func testNoTunnelAffectingDiffOnNameChange() {
        var other = base()
        other.name = "Renamed"
        XCTAssertFalse(base().tunnelAffectingFieldsDiffer(from: other))
    }

    func testEnvironmentColorMapping() {
        XCTAssertEqual(DeploymentEnvironment.prod.label, "Prod")
        XCTAssertEqual(DeploymentEnvironment.allCases.count, 3)
    }
}
