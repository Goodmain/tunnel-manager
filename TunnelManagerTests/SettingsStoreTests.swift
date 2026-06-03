import XCTest
@testable import TunnelManager

@MainActor
final class SettingsStoreTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    func testDefaults() {
        let (defaults, _) = makeDefaults()
        let s = SettingsStore(defaults: defaults)
        XCTAssertEqual(s.defaultAWSProfile, "")
        XCTAssertEqual(s.reconnectDelay, 5.0)
        XCTAssertTrue(s.autoReconnect)
        XCTAssertFalse(s.killOrphanOnPort)
        XCTAssertEqual(s.maxReconnectAttempts, 5)
        XCTAssertEqual(s.binaryDirectoryOverride, "")
    }

    func testRoundTripPersistence() {
        let (defaults, _) = makeDefaults()
        let s1 = SettingsStore(defaults: defaults)
        s1.defaultAWSProfile = "prod"
        s1.reconnectDelay = 12
        s1.autoReconnect = false
        s1.killOrphanOnPort = true
        s1.maxReconnectAttempts = 9
        s1.binaryDirectoryOverride = "/opt/homebrew/bin"

        // A fresh store on the same suite must load the saved values.
        let s2 = SettingsStore(defaults: defaults)
        XCTAssertEqual(s2.defaultAWSProfile, "prod")
        XCTAssertEqual(s2.reconnectDelay, 12)
        XCTAssertFalse(s2.autoReconnect)
        XCTAssertTrue(s2.killOrphanOnPort)
        XCTAssertEqual(s2.maxReconnectAttempts, 9)
        XCTAssertEqual(s2.binaryDirectoryOverride, "/opt/homebrew/bin")
    }
}
