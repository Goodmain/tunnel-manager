import XCTest
import Darwin
@testable import TunnelManager

/// Integration tests for the real process-spawning path (design D2/D11). These
/// spawn actual child processes rather than mocking.
final class SpawnedProcessIntegrationTests: XCTestCase {
    /// Thread-safe accumulator for callback output (callbacks fire off-main).
    private final class Box {
        private let lock = NSLock()
        private var _text = ""
        func append(_ s: String) { lock.lock(); _text += s; lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return _text }
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    func testTerminateGroupReapsGrandchild() {
        let box = Box()
        let gotPID = expectation(description: "captured grandchild pid")
        let terminated = expectation(description: "onTermination fired")
        var grandchildPID: pid_t = -1
        let pidLock = NSLock()

        // sh is the group leader; the backgrounded sleep is a child in the same group.
        let proc = SpawnedProcess(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 30 & echo $!; wait"],
            environment: ProcessInfo.processInfo.environment,
            onOutput: { text in
                box.append(text)
                if let pid = box.text.split(whereSeparator: { !$0.isNumber }).first.flatMap({ Int($0) }) {
                    pidLock.lock()
                    if grandchildPID == -1 {
                        grandchildPID = pid_t(pid)
                        gotPID.fulfill()
                    }
                    pidLock.unlock()
                }
            },
            onTermination: { _ in terminated.fulfill() }
        )
        XCTAssertNotNil(proc, "spawn should succeed")
        guard let proc else { return }

        wait(for: [gotPID], timeout: 5)
        pidLock.lock(); let child = grandchildPID; pidLock.unlock()
        XCTAssertGreaterThan(child, 0)
        XCTAssertTrue(isAlive(child), "grandchild should be alive before teardown")

        // Force quick escalation to SIGKILL.
        proc.terminateGroup(graceSeconds: 0.2)

        // Poll until the grandchild is gone (group kill reaped it).
        let deadline = Date().addingTimeInterval(5)
        while isAlive(child) && Date() < deadline {
            usleep(50_000)
        }
        XCTAssertFalse(isAlive(child), "grandchild must be reaped by the group kill")
        wait(for: [terminated], timeout: 5)
    }

    func testOutputDrainedAndExitCodeReported() {
        let box = Box()
        let terminated = expectation(description: "onTermination fired")
        var exitCode: Int32 = -1

        let proc = SpawnedProcess(
            executable: "/bin/echo",
            arguments: ["hello-tunnel"],
            environment: ProcessInfo.processInfo.environment,
            onOutput: { box.append($0) },
            onTermination: { code in exitCode = code; terminated.fulfill() }
        )
        XCTAssertNotNil(proc)
        wait(for: [terminated], timeout: 5)
        XCTAssertTrue(box.text.contains("hello-tunnel"), "stdout should be drained to onOutput")
        XCTAssertEqual(exitCode, 0)
    }
}
