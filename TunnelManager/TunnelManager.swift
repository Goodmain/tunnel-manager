import Foundation
import Combine
import AppKit
import Network
import Darwin

/// Runtime engine for tunnels (tunnel-lifecycle capability). `@MainActor` so all
/// state mutation and `@Published` updates happen on main (design D12); blocking
/// work (spawn, probe, kill, ECS resolve) hops off-main and back.
@MainActor
final class TunnelManager: ObservableObject {
    /// Per-connection state, observed by the UI.
    @Published private(set) var states: [UUID: TunnelState] = [:]
    /// Count of connected tunnels, drives the menu bar icon (D19).
    @Published private(set) var activeCount: Int = 0
    /// Count of connecting/reconnecting tunnels; drives the orange in-progress icon.
    @Published private(set) var connectingCount: Int = 0
    /// Whether `aws-vault` was found on launch (preflight, D1).
    @Published private(set) var dependencyError: String?
    /// Connections the user currently wants up. Drives the row toggle so it stays
    /// on through connecting/reconnecting and only off on stop or terminal failure.
    @Published private(set) var wanted: Set<UUID> = []

    private let store: ConnectionStore
    private let settings: SettingsStore

    private var processes: [UUID: SpawnedProcess] = [:]
    private var startTasks: [UUID: Task<Void, Never>] = [:]
    private var intent: [UUID: Bool] = [:]            // userWantsConnected (D4)
    private var reconnectAttempts: [UUID: Int] = [:]
    private var reconnectWork: [UUID: DispatchWorkItem] = [:]
    private var lastOutput: [UUID: String] = [:]      // bounded ring buffer (D11)
    /// Cached temp credentials per profile + the in-flight fetch, so concurrent
    /// (re)connects share ONE aws-vault invocation → one prompt per profile.
    private var cachedCreds: [String: VaultCredentials] = [:]
    private var credFetch: [String: Task<VaultCredentials?, Never>] = [:]

    /// Connections whose drop is expected because the machine is sleeping (D14).
    private var expectedSleepDrops: Set<UUID> = []
    private var isSleeping = false

    /// Process-group id per connection, so the port-in-use check can recognize a
    /// stale process WE spawned (vs a foreign orphan).
    private var spawnedPgids: [UUID: pid_t] = [:]

    /// Network-connectivity monitoring (network-drop recovery).
    private let pathMonitor = NWPathMonitor()
    private var networkDown = false
    private var suspendedForNetwork: Set<UUID> = []

    private var cachedPath: String = ""
    private var awsVaultPath: String?
    private var awsPath: String?

    private let readinessTimeout: TimeInterval = 45  // generous: covers slow MFA (D5/D10)
    private let outputBufferLimit = 8 * 1024

    init(store: ConnectionStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
        registerSleepWakeObservers()
        startNetworkMonitor()
    }

    // MARK: - Launch configuration (D1)

    /// Resolve PATH + locate aws-vault off the main thread, then preflight.
    func configure() {
        let override = settings.binaryDirectoryOverride
        Task { [weak self] in
            let path = await Task.detached(priority: .userInitiated) {
                PathResolver.resolveLoginPath()
            }.value
            let dir = override.isEmpty ? nil : override
            let found = await Task.detached(priority: .userInitiated) {
                (
                    vault: PathResolver.find("aws-vault", in: path, overrideDirectory: dir),
                    aws: PathResolver.find("aws", in: path, overrideDirectory: dir),
                    plugin: PathResolver.find("session-manager-plugin", in: path, overrideDirectory: dir)
                )
            }.value
            await MainActor.run {
                guard let self else { return }
                self.cachedPath = path
                self.awsVaultPath = found.vault
                self.awsPath = found.aws
                var missing: [String] = []
                if found.vault == nil { missing.append("aws-vault") }
                if found.aws == nil { missing.append("aws") }
                if found.plugin == nil { missing.append("session-manager-plugin") }
                self.dependencyError = missing.isEmpty
                    ? nil
                    : "Missing on PATH: \(missing.joined(separator: ", ")). Install them or set a binary directory in Settings."
                self.log(nil, "configured — aws-vault=\(found.vault ?? "MISSING") aws=\(found.aws ?? "MISSING") plugin=\(found.plugin ?? "MISSING")")
            }
        }
    }

    /// Environment for the single aws-vault credential fetch (PATH + GUI prompt).
    private func baseEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = cachedPath
        env["AWS_VAULT_PROMPT"] = "osascript"  // GUI prompt, no TTY needed
        return env
    }

    /// Environment for the tunnel/ECS `aws` commands: PATH + injected credentials
    /// for `profile`, so they run without an aws-vault wrapper.
    private func childEnvironment(for profile: String) -> [String: String] {
        var env = baseEnvironment()
        if let creds = cachedCreds[profile] {
            for (k, v) in creds.environment { env[k] = v }
        }
        return env
    }

    // MARK: - Public state accessors

    func state(for id: UUID) -> TunnelState { states[id] ?? .disconnected }
    func lastError(for id: UUID) -> String? { states[id]?.failureMessage }
    func isWanted(_ id: UUID) -> Bool { wanted.contains(id) }

    // MARK: - Intent + logging

    /// Set whether the user wants a connection up. Keeps `intent` (internal gate)
    /// and `wanted` (published, drives the toggle) in sync.
    private func setWanted(_ id: UUID, _ on: Bool) {
        intent[id] = on
        if on { wanted.insert(id) } else { wanted.remove(id) }
    }

    private static let logClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Structured log: `[HH:mm:ss.SSS] [name#id8] [state] message` (diagnostics-logging).
    private func log(_ id: UUID?, _ message: String) {
        let time = Self.logClock.string(from: Date())
        let line: String
        if let id {
            let name = store.connection(id: id)?.name.isEmpty == false
                ? store.connection(id: id)!.name : "?"
            let short = String(id.uuidString.prefix(8))
            line = "\(time) [\(name)#\(short)] [\(stateLabel(state(for: id)))] \(message)"
        } else {
            line = "\(time) [app] \(message)"
        }
        NSLog("%@", line)
        FileLogger.shared.write(line)   // durable, rotating file (~/Library/Logs/TunnelManager)
    }

    private func stateLabel(_ s: TunnelState) -> String {
        switch s {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reconnecting: return "reconnecting"
        case .failed: return "failed"
        }
    }

    // MARK: - Toggle / start / stop

    func toggle(_ connection: Connection) {
        if isWanted(connection.id) {
            stop(id: connection.id, intentional: true)
        } else {
            start(connection)
        }
    }

    func start(_ connection: Connection) {
        let id = connection.id
        setWanted(id, true)
        cancelReconnect(id: id)
        startTasks[id]?.cancel()
        log(id, "start requested")

        guard let vault = awsVaultPath else {
            setWanted(id, false)
            setState(id, .failed("aws-vault not found. Check Settings."))
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runStart(connection, vault: vault)
        }
        startTasks[id] = task
    }

    /// The cancellable start flow (D17). Each step checks cancellation/intent.
    private func runStart(_ connection: Connection, vault: String) async {
        let id = connection.id
        setState(id, .connecting)

        // Pre-flight: free the local port. Recycle our own stale process (e.g. a
        // wedged tunnel after a network drop); only a foreign holder is an orphan.
        let port = connection.localPort
        if let portError = await reclaimPort(id: id, port: port) {
            failAttempt(id: id, reason: portError)
            return
        }
        if Task.isCancelled || intent[id] != true { setState(id, .disconnected); return }

        // Fetch credentials ONCE per profile (one prompt), then run aws directly.
        guard let _ = await credentials(for: connection.awsProfile, vault: vault) else {
            failAttempt(id: id, reason: "Could not obtain credentials from aws-vault for profile \(connection.awsProfile).")
            return
        }
        if Task.isCancelled || intent[id] != true { setState(id, .disconnected); return }
        guard let aws = awsPath else {
            setWanted(id, false)
            setState(id, .failed("aws CLI not found. Check Settings."))
            return
        }

        // Resolve ECS target fresh (D6), running `aws` with injected credentials.
        let env = childEnvironment(for: connection.awsProfile)
        let ctx = ECSResolver.Context(
            awsPath: aws, environment: env,
            cluster: connection.ecsCluster, remotePort: connection.remotePort
        )
        let resolution: ECSResolver.Resolution
        do {
            resolution = try await Task.detached(priority: .userInitiated) {
                try ECSResolver.resolve(ctx)
            }.value
        } catch {
            invalidateCredentials(profile: connection.awsProfile)  // maybe expired; refetch next time
            failAttempt(id: id, reason: error.localizedDescription)
            return
        }
        log(id, "ECS target \(resolution.target) (container \(resolution.chosenContainerName))")
        if Task.isCancelled || intent[id] != true { setState(id, .disconnected); return }

        // Spawn the long-running tunnel (own process group, D2), aws directly.
        let args = ssmArguments(connection: connection, target: resolution.target)
        guard let process = SpawnedProcess(
            executable: aws,
            arguments: args,
            environment: env,
            onOutput: { [weak self] text in
                Task { @MainActor in self?.appendOutput(id: id, text: text) }
            },
            onTermination: { [weak self] code in
                Task { @MainActor in self?.handleTermination(id: id, exitCode: code) }
            }
        ) else {
            failAttempt(id: id, reason: "Failed to launch aws (posix_spawn failed).")
            return
        }
        processes[id] = process
        spawnedPgids[id] = process.pgid

        // If the user toggled off while we were resolving/spawning, tear down now (D17).
        if Task.isCancelled || intent[id] != true {
            teardownProcess(id: id)
            setState(id, .disconnected)
            return
        }

        // Readiness gate: connected only when the local port actually listens (D10).
        let ready = await Task.detached(priority: .userInitiated) { [readinessTimeout] in
            PortProbe.waitUntilListening(port: port, timeout: readinessTimeout)
        }.value

        if Task.isCancelled || intent[id] != true {
            teardownProcess(id: id)
            setState(id, .disconnected)
            return
        }
        if ready {
            reconnectAttempts[id] = 0
            setState(id, .connected)
        } else {
            teardownProcess(id: id)
            let tail = (lastOutput[id]?.split(separator: "\n").last).map { " \($0)" } ?? ""
            failAttempt(id: id, reason: "Did not become ready within \(Int(readinessTimeout))s.\(tail)")
        }
    }

    func stop(id: UUID, intentional: Bool) {
        if intentional { setWanted(id, false); log(id, "stop requested (user)") }
        cancelReconnect(id: id)
        startTasks[id]?.cancel()
        startTasks[id] = nil
        teardownProcess(id: id)
        if intentional { setState(id, .disconnected) }
    }

    // MARK: - Edit-restart (D15)

    /// Called after an edit is saved. Restarts the tunnel if tunnel-affecting
    /// fields changed while it was live; otherwise leaves it running.
    func handleEdit(old: Connection, new: Connection) {
        let current = state(for: new.id)
        let live = current.isActive || current.isBusy
        guard live, new.tunnelAffectingFieldsDiffer(from: old) else { return }
        stop(id: new.id, intentional: true)
        // Brief gap to let the port free before re-probing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.start(new)
        }
    }

    // MARK: - Termination handling (D4)

    private func handleTermination(id: UUID, exitCode: Int32) {
        processes[id] = nil
        spawnedPgids[id] = nil

        // Intentional stop already settled the state.
        guard intent[id] == true else { return }

        let lastLine = (lastOutput[id]?.split(separator: "\n").last).map(String.init) ?? ""
        log(id, "process exited unexpectedly (code \(exitCode))\(lastLine.isEmpty ? "" : ": \(lastLine)")")

        // Sleep- or network-induced drop: don't count toward the cap; wait for
        // wake / network restore to recycle (D14 + network-drop recovery).
        if isSleeping || expectedSleepDrops.contains(id) || networkDown || suspendedForNetwork.contains(id) {
            setState(id, .reconnecting)
            return
        }

        guard settings.autoReconnect else {
            setWanted(id, false)
            setState(id, .failed(lastLine.isEmpty ? "Tunnel dropped (auto-reconnect off)." : lastLine))
            return
        }

        failAttempt(id: id, reason: lastLine.isEmpty ? "tunnel dropped (exit \(exitCode))" : lastLine)
    }

    private func scheduleReconnect(id: UUID, delay: TimeInterval) {
        guard let connection = store.connection(id: id) else { return }
        setState(id, .reconnecting)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.intent[id] == true else { return }
            self.start(connection)
        }
        reconnectWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelReconnect(id: UUID) {
        reconnectWork[id]?.cancel()
        reconnectWork[id] = nil
    }

    // MARK: - Port reclamation (network-drop recovery: own stale vs foreign orphan)

    /// Make `port` free before spawning. Returns nil to proceed, or an error reason
    /// (a foreign process holds it) for the caller to route through `failAttempt`.
    private func reclaimPort(id: UUID, port: Int) async -> String? {
        // 1. Our own tracked process for this connection (e.g. wedged after a
        //    network drop, process never exited): tear it down and reuse the port.
        if let process = processes[id] {
            processes[id] = nil
            spawnedPgids[id] = nil
            log(id, "reclaiming own stale process before restart")
            await Task.detached { process.terminateGroupBlocking(timeout: 2.0) }.value
            _ = await Task.detached { PortProbe.waitUntilFree(port: port, timeout: 2.0) }.value
            return nil
        }

        let occupied = await Task.detached { PortProbe.isListening(port: port) }.value
        guard occupied else { return nil }

        let holder = await Task.detached { PortProbe.holdingPID(port: port) }.value

        // 2. Untracked, but the holder is in a process group WE spawned for this
        //    connection → still ours; kill the group and reuse the port.
        if let holder, let pgid = spawnedPgids[id],
           getpgid(pid_t(holder)) == pgid {
            spawnedPgids[id] = nil
            await Task.detached { _ = kill(-pgid, SIGKILL) }.value
            _ = await Task.detached { PortProbe.waitUntilFree(port: port, timeout: 2.0) }.value
            return nil
        }

        // 3. A foreign process holds the port. If the user opted in, kill it and
        //    reuse the port; otherwise surface the orphan message.
        if settings.killOrphanOnPort, let holder {
            let pid = pid_t(holder)
            let freed = await Task.detached { () -> Bool in
                _ = kill(pid, SIGTERM)
                if PortProbe.waitUntilFree(port: port, timeout: 1.5) { return true }
                _ = kill(pid, SIGKILL)
                return PortProbe.waitUntilFree(port: port, timeout: 1.5)
            }.value
            if freed {
                log(id, "killed process \(holder) holding port \(port) (killOrphanOnPort)")
                return nil
            }
        }

        let pidText = holder.map { " (PID \($0))" } ?? ""
        return "Local port \(port) in use\(pidText) — possibly an orphaned tunnel from a previous session."
    }

    // MARK: - Sleep / wake (D14)

    private func registerSleepWakeObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func willSleep() {
        isSleeping = true
        for (id, want) in intent where want { expectedSleepDrops.insert(id) }
    }

    @objc private func didWake() {
        isSleeping = false
        let toReconnect = expectedSleepDrops.filter { intent[$0] == true }
        expectedSleepDrops.removeAll()
        guard !toReconnect.isEmpty else { return }

        recycle(ids: toReconnect)
    }

    // MARK: - Network monitoring (network-drop recovery)

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in self?.handleNetwork(satisfied: satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "tunnelmanager.network", qos: .utility))
    }

    private func handleNetwork(satisfied: Bool) {
        if !satisfied {
            // Network lost: suspend wanted tunnels (their processes are likely
            // wedged but still holding the port). Don't retry / burn the cap now.
            guard !networkDown else { return }
            networkDown = true
            for (id, want) in intent where want {
                suspendedForNetwork.insert(id)
                cancelReconnect(id: id)
                setState(id, .reconnecting)
            }
        } else {
            // Network restored: recycle the suspended tunnels (kill wedged process,
            // free the port, restart). start() reclaims the port (D4/D5).
            guard networkDown else { return }
            networkDown = false
            let toRecycle = suspendedForNetwork.filter { intent[$0] == true }
            suspendedForNetwork.removeAll()
            guard !toRecycle.isEmpty else { return }
            recycle(ids: toRecycle)
        }
    }

    /// Staggered, credential-warmed restart of a set of connections (used by both
    /// wake and network-restore). Each start reclaims its port first.
    private func recycle(ids: Set<UUID>) {
        cachedCreds.removeAll()   // creds may have expired during the outage; one fetch (one prompt) re-acquires
        var offset = 0.0
        for id in ids {
            guard let connection = store.connection(id: id) else { continue }
            reconnectAttempts[id] = 0
            let jitter = Double(abs(id.hashValue) % 1000) / 1000.0  // 0–1s deterministic
            let delay = settings.reconnectDelay + offset + jitter
            setState(id, .reconnecting)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.intent[id] == true else { return }
                self.start(connection)
            }
            offset += 1.0
        }
    }

    /// Obtain temp credentials for `profile`, fetching from aws-vault at most once
    /// (D1). A valid cache is reused; concurrent callers join the single in-flight
    /// fetch, so N tunnels for one profile trigger ONE aws-vault prompt.
    private func credentials(for profile: String, vault: String) async -> VaultCredentials? {
        if let cached = cachedCreds[profile], !cached.isExpired { return cached }
        if let inflight = credFetch[profile] { return await inflight.value }  // join existing fetch

        let env = baseEnvironment()
        let aws = awsPath
        let task = Task<VaultCredentials?, Never> { () -> VaultCredentials? in
            await Task.detached(priority: .userInitiated) { () -> VaultCredentials? in
                // The ONE aws-vault invocation that touches the credential store.
                guard let result = try? CommandRunner.run(
                    executable: vault,
                    arguments: ["exec", profile, "--prompt=osascript", "--", "env"],
                    environment: env
                ), result.exitCode == 0, var creds = VaultCredentials.parse(env: result.stdout) else {
                    return nil
                }
                // Region fallback from profile config (no credentials/prompt).
                if creds.region == nil, let aws,
                   let reg = try? CommandRunner.run(
                       executable: aws,
                       arguments: ["configure", "get", "region", "--profile", profile],
                       environment: env),
                   reg.exitCode == 0 {
                    let region = reg.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !region.isEmpty { creds = creds.withRegion(region) }
                }
                return creds
            }.value
        }
        credFetch[profile] = task
        let creds = await task.value
        credFetch[profile] = nil
        if let creds { cachedCreds[profile] = creds }
        return creds
    }

    /// Drop cached credentials for a profile (e.g. an `aws` call hit an auth error)
    /// so the next connect re-fetches — still one prompt via the join above.
    private func invalidateCredentials(profile: String) {
        cachedCreds[profile] = nil
    }

    // MARK: - Teardown

    private func teardownProcess(id: UUID) {
        if let process = processes[id] {
            process.terminateGroup()
        }
        processes[id] = nil
        spawnedPgids[id] = nil
    }

    /// Quit path (D1/D2): cancel everything that could respawn a tunnel and hand
    /// back the live processes so the caller can kill them (off-main, blocking).
    /// Clears the process map so a follow-up `terminateAll()` is a no-op.
    func prepareForQuit() -> [SpawnedProcess] {
        for id in Array(intent.keys) { intent[id] = false }   // nothing is "wanted" anymore
        wanted.removeAll()
        reconnectWork.values.forEach { $0.cancel() }
        reconnectWork.removeAll()
        startTasks.values.forEach { $0.cancel() }
        startTasks.removeAll()
        let live = Array(processes.values)
        processes.removeAll()
        return live
    }

    /// Best-effort synchronous teardown, used as a fallback from
    /// `applicationWillTerminate`. Idempotent after `prepareForQuit`.
    func terminateAll() {
        for process in prepareForQuit() {
            process.terminateGroupSync()
        }
    }

    // MARK: - Helpers

    private func ssmArguments(connection: Connection, target: String) -> [String] {
        // Plain `aws ssm` — credentials injected via environment, no aws-vault wrapper.
        // Literal JSON passed as ONE argv element — no shell, no escaping.
        let parameters = "{\"host\":[\"\(connection.dbHost)\"],\"portNumber\":[\"\(connection.remotePort)\"],\"localPortNumber\":[\"\(connection.localPort)\"]}"
        return [
            "ssm", "start-session",
            "--target", target,
            "--document-name", "AWS-StartPortForwardingSessionToRemoteHost",
            "--parameters", parameters,
        ]
    }

    private func appendOutput(id: UUID, text: String) {
        var buffer = (lastOutput[id] ?? "") + text
        if buffer.count > outputBufferLimit {
            buffer = String(buffer.suffix(outputBufferLimit))
        }
        lastOutput[id] = buffer
        // Surface tunnel output so failures are diagnosable.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { NSLog("[tunnel %@] %@", id.uuidString.prefix(8) as CVarArg, trimmed) }
        // Fast-path readiness hint (D10): the probe is the source of truth, this
        // just nudges; no state change here.
    }

    private func setState(_ id: UUID, _ newState: TunnelState) {
        let old = state(for: id)
        states[id] = newState
        activeCount = states.values.filter { $0.isActive }.count
        connectingCount = states.values.filter { $0.isBusy }.count
        if stateLabel(old) != stateLabel(newState) {
            var line = "\(stateLabel(old)) → \(stateLabel(newState))"
            if let msg = newState.failureMessage { line += ": \(msg)" }
            log(id, line)
        }
    }

    /// Single failure path (D1): retry within the cap while the connection is
    /// wanted + auto-reconnect is on; otherwise terminal `failed` (uncheck + error).
    private func failAttempt(id: UUID, reason: String) {
        guard intent[id] == true else { setState(id, .disconnected); return }  // user already stopped
        let cap = settings.maxReconnectAttempts
        let attempts = (reconnectAttempts[id] ?? 0) + 1
        if settings.autoReconnect && attempts <= cap {
            reconnectAttempts[id] = attempts
            log(id, "attempt \(attempts)/\(cap) failed: \(reason) — retrying in \(Int(settings.reconnectDelay))s")
            scheduleReconnect(id: id, delay: settings.reconnectDelay)
        } else {
            log(id, "giving up after \(attempts - 1)/\(cap) attempts: \(reason)")
            setWanted(id, false)
            setState(id, .failed(reason))
        }
    }
}
