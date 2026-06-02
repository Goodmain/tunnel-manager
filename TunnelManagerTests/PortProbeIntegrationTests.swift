import XCTest
import Darwin
@testable import TunnelManager

/// Integration tests for `PortProbe` against real loopback sockets (design D7/D10).
final class PortProbeIntegrationTests: XCTestCase {
    /// Bind + listen on 127.0.0.1:0 and return (fd, assignedPort).
    private func openListener() -> (Int32, Int)? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // OS assigns an ephemeral port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindOK = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0, Darwin.listen(fd, 1) == 0 else { close(fd); return nil }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameOK = withUnsafeMutablePointer(to: &bound) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard nameOK == 0 else { close(fd); return nil }
        let port = Int(UInt16(bigEndian: bound.sin_port))

        // Service connections on a background thread, like a real tunnel would,
        // so probes complete instead of sitting unaccepted in the backlog.
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { break }  // listener closed → exit
                close(client)
            }
        }
        return (fd, port)
    }

    func testListeningPortDetected() throws {
        guard let (fd, port) = openListener() else {
            return XCTFail("could not open listener")
        }
        defer { close(fd) }
        XCTAssertTrue(PortProbe.isListening(port: port))
        XCTAssertTrue(PortProbe.waitUntilListening(port: port, timeout: 2))
    }

    func testWaitUntilFree() {
        guard let (fd, port) = openListener() else {
            return XCTFail("could not open listener")
        }
        // Listening → not free within the timeout.
        XCTAssertFalse(PortProbe.waitUntilFree(port: port, timeout: 0.5))
        close(fd)
        // Closed → becomes free.
        XCTAssertTrue(PortProbe.waitUntilFree(port: port, timeout: 2.0))
    }

    func testUnboundPortNotDetected() {
        // Get a port the OS just assigned, then close it so nothing listens there.
        guard let (fd, port) = openListener() else {
            return XCTFail("could not open listener")
        }
        close(fd)
        // Nothing is accepting on this port now → connect refused → not listening.
        XCTAssertFalse(PortProbe.isListening(port: port))
    }
}
