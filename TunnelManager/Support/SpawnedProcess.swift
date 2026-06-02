import Foundation
import Darwin

/// A child process spawned in its OWN process group (design D2), so the whole
/// tree (`aws-vault` → `aws` → `session-manager-plugin`) can be reaped with one
/// signal to the group without touching the app. Foundation's `Process` cannot
/// set a process group, so we use `posix_spawn` directly.
///
/// Output is captured by blocking read-loops draining to EOF (design D11). The
/// `onOutput`/`onTermination` handlers are passed into init so they are wired
/// BEFORE the child runs — no early-output race. Termination fires only after
/// both pipes hit EOF, so the last error line is never lost.
final class SpawnedProcess: @unchecked Sendable {
    let pid: pid_t
    /// Process-group id. Equals `pid` because the child is its own group leader.
    var pgid: pid_t { pid }

    private var exitSource: DispatchSourceProcess?
    private let drainGroup = DispatchGroup()
    private let queue = DispatchQueue(label: "tunnelmanager.spawn", qos: .utility, attributes: .concurrent)
    private var terminated = false
    private var exitStatus: Int32 = 0

    /// Spawn `executable` (absolute path, design D1) with `arguments` and `environment`.
    /// `onOutput` receives combined stdout/stderr chunks. `onTermination` receives the
    /// decoded exit code (or 128+signal). Returns nil if the spawn fails.
    init?(
        executable: String,
        arguments: [String],
        environment: [String: String],
        onOutput: @escaping (String) -> Void,
        onTermination: @escaping (Int32) -> Void
    ) {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { return nil }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            return nil
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, outPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, outPipe[1])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[1])

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // New process group with the child as leader (pgid = child pid).
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        let argv: [UnsafeMutablePointer<CChar>?] =
            ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] =
            environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for case let p? in argv { free(p) }
            for case let p? in envp { free(p) }
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attr)
        }

        var childPid: pid_t = 0
        let rc = posix_spawn(&childPid, executable, &fileActions, &attr, argv, envp)

        // Parent closes the write ends; it only reads.
        close(outPipe[1])
        close(errPipe[1])

        guard rc == 0 else {
            close(outPipe[0]); close(errPipe[0])
            NSLog("[SpawnedProcess] posix_spawn failed rc=%d (%s)", rc, strerror(rc))
            return nil
        }

        self.pid = childPid

        // Drain both pipes to EOF with blocking reads (no readabilityHandler race).
        startDraining(fd: outPipe[0], onOutput: onOutput)
        startDraining(fd: errPipe[0], onOutput: onOutput)

        startExitWatch(onTermination: onTermination)
    }

    // MARK: - Draining (D11)

    private func startDraining(fd: Int32, onOutput: @escaping (String) -> Void) {
        drainGroup.enter()
        queue.async { [drainGroup] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n <= 0 { break }
                let data = Data(buffer[0..<n])
                if let text = String(data: data, encoding: .utf8) {
                    onOutput(text)
                }
            }
            close(fd)
            drainGroup.leave()
        }
    }

    // MARK: - Exit watch

    private func startExitWatch(onTermination: @escaping (Int32) -> Void) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(self.pid, &status, 0)
            self.terminated = true
            // Decode: normal exit code, or 128+signal if killed.
            let code: Int32
            if (status & 0x7f) == 0 {
                code = (status >> 8) & 0xff
            } else {
                code = 128 + (status & 0x7f)
            }
            self.exitStatus = code
            self.exitSource?.cancel()
            // Fire termination only after BOTH pipes reach EOF, so no output is lost.
            self.drainGroup.notify(queue: self.queue) {
                onTermination(code)
            }
        }
        self.exitSource = source
        source.resume()
    }

    // MARK: - Teardown (D2)

    /// SIGTERM the whole process group, then SIGKILL after a grace period if still alive.
    func terminateGroup(graceSeconds: TimeInterval = 2.0) {
        kill(-pgid, SIGTERM)
        queue.asyncAfter(deadline: .now() + graceSeconds) { [weak self] in
            guard let self, !self.terminated else { return }
            kill(-self.pgid, SIGKILL)
        }
    }

    /// Synchronous best-effort kill for app teardown (design D2 / applicationWillTerminate).
    func terminateGroupSync() {
        kill(-pgid, SIGTERM)
    }

    /// Blocking, escalating group kill for quit teardown: SIGTERM → poll until the
    /// group is gone or `timeout` elapses → SIGKILL any survivor. Call off-main.
    func terminateGroupBlocking(timeout: TimeInterval = 1.0) {
        kill(-pgid, SIGTERM)
        let deadline = Date().addingTimeInterval(timeout)
        // kill(-pgid, 0) returns -1/ESRCH once no process in the group remains.
        while kill(-pgid, 0) == 0 && Date() < deadline {
            usleep(50_000)  // 50ms
        }
        if kill(-pgid, 0) == 0 {
            kill(-pgid, SIGKILL)
        }
    }
}
