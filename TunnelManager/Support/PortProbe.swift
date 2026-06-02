import Foundation
import Darwin

/// Local-port utilities for readiness detection (D10), pre-flight availability
/// (D7), and orphan detection (D18).
enum PortProbe {
    /// True if something is accepting TCP connections on 127.0.0.1:port right now.
    static func isListening(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Poll until the port is listening or the timeout elapses (readiness gate, D10).
    /// Runs its own sleeps; call from a background context.
    static func waitUntilListening(port: Int, timeout: TimeInterval, pollInterval: TimeInterval = 0.25) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isListening(port: port) { return true }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return isListening(port: port)
    }

    /// PID holding a local port, via `lsof` (orphan reporting, D18). Best-effort.
    static func holdingPID(port: Int) -> Int? {
        let lsof = "/usr/sbin/lsof"
        let path = FileManager.default.isExecutableFile(atPath: lsof) ? lsof : "/usr/bin/lsof"
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-ti", "tcp:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.split(separator: "\n").first.flatMap { Int($0) }
        } catch {
            return nil
        }
    }
}
