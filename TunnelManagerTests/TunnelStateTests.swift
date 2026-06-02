import XCTest
@testable import TunnelManager

final class TunnelStateTests: XCTestCase {
    func testIsActive() {
        XCTAssertTrue(TunnelState.connected.isActive)
        XCTAssertFalse(TunnelState.connecting.isActive)
        XCTAssertFalse(TunnelState.disconnected.isActive)
        XCTAssertFalse(TunnelState.failed("x").isActive)
    }

    func testIsBusy() {
        XCTAssertTrue(TunnelState.connecting.isBusy)
        XCTAssertTrue(TunnelState.reconnecting.isBusy)
        XCTAssertFalse(TunnelState.connected.isBusy)
        XCTAssertFalse(TunnelState.disconnected.isBusy)
    }

    func testFailureMessage() {
        XCTAssertEqual(TunnelState.failed("boom").failureMessage, "boom")
        XCTAssertNil(TunnelState.connected.failureMessage)
    }
}
