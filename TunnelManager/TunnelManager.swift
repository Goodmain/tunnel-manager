import Foundation
import Combine
import AppKit

/// Runtime engine for tunnels (tunnel-lifecycle capability). `@MainActor` so all
/// state mutation and `@Published` updates happen on main (design D12); blocking
/// work (spawn, probe, kill, ECS resolve) hops off-main and back.
@MainActor
final class TunnelManager: ObservableObject {
    /// Per-connection state, observed by the UI.
    @Published private(set) var states: [UUID: TunnelState] = [:]
    /// Count of connected tunnels, drives the menu bar icon (D19).
    @Published private(set) var activeCount: Int = 0
    /// Whether `aws-vault` was found on launch (preflight, D1).
    @Published private(set) var dependencyError: String?

    private let store: ConnectionStore
    private let settings: SettingsStore

    private var processes: [UUID: SpawnedProcess] = [:]
    private var startTasks: [UUID: Task<Void, Never>] = [:]
    private var intent: [UUID: Bool] = [:]            // userWantsConnected (D4)
    private var reconnectAttempts: [UUID: Int] = [:]
    private var reconnectWork: [UUID: DispatchWorkItem] = [:]
    private var lastOutput: [UUID: String] = [:]      // bounded ring buffer (D11)
    private var credentialWarmers: [String: Task<Void, Never>] = [:]  // per-profile auth gate

    /// Connections whose drop is expected because the machine is sleeping (D14).
    private var expectedSleepDrops: Set<UUID> = []
    private var isSleeping = false

    private var cachedPath: String = ""
    private var awsVaultPath: String?

    private let readinessTimeout: TimeInterval = 45  // generous: covers slow MFA (D5/D10)
    private let maxReconnectAttempts = 5             // bound the storm (tunnel-lifecycle)
    private let outputBufferLimit = 8 * 1024

    init(store: ConnectionStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
        registerSleepWakeObservers()
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
                var missing: [String] = []
                if found.vault == nil { missing.append("aws-vault") }
                if found.aws == nil { missing.append("aws") }
                if found.plugin == nil { missing.append("session-manager-plugin") }
                self.dependencyError = missing.isEmpty
                    ? nil
                    : "Missing on PATH: \(missing.joined(separator: ", ")). Install them or set a binary directory in Settings."
                NSLog("[TunnelManager] PATH=%@ aws-vault=%@ aws=%@ plugin=%@", path,
                      found.vault ?? "MISSING", found.aws ?? "MISSING", found.plugin ?? "MISSING")
            }
        }
    }

    private func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = cachedPath
        env["AWS_VAULT_PROMPT"] = "osascript"  // GUI MFA prompt (D5)
        return env
    }

    // MARK: - Public state accessors

    func state(for id: UUID) -> TunnelState { states[id] ?? .disconnected }
    func lastError(for id: UUID) -> String? { states[id]?.failureMessage }

    // MARK: - Toggle / start / stop

    func toggle(_ connection: Connection) {
        let current = state(for: connection.id)
        if current.isActive || current.isBusy {
            stop(id: connection.id, intentional: true)
        } else {
            start(connection)
        }
    }

    func start(_ connection: Connection) {
        let id = connection.id
        intent[id] = true
        cancelReconnect(id: id)
        startTasks[id]?.cancel()

        guard let vault = awsVaultPath else {
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

        // Pre-flight: port already taken? Possibly an orphan from a prior run (D7/D18).
        let port = connection.localPort
        let occupied = await Task.detached { PortProbe.isListening(port: port) }.value
        if occupied {
            let pid = await Task.detached { PortProbe.holdingPID(port: port) }.value
            let pidText = pid.map { " (PID \($0))" } ?? ""
            setState(id, .failed("Local port \(port) in use\(pidText) — possibly an orphaned tunnel from a previous session."))
            return
        }
        if Task.isCancelled || intent[id] != true { setState(id, .disconnected); return }

        // Serialize credential acquisition per profile so concurrent starts trigger
        // ONE MFA prompt, not one each. The first start warms creds; others await it.
        await ensureCredentials(profile: connection.awsProfile, vault: vault)
        if Task.isCancelled || intent[id] != true { setState(id, .disconnected); return }

        // Resolve ECS target fresh (D6).
        let env = childEnvironment()
        let ctx = ECSResolver.Context(
            awsVaultPath: vault, environment: env, profile: connection.awsProfile,
            cluster: connection.ecsCluster, remotePort: connection.remotePort
        )
        let resolution: ECSResolver.Resolution
        do {
            resolution = try await Task.detached(priority: .userInitiated) {
                try ECSResolver.resolve(ctx)
            }.value
        } catch {
            setState(id, .failed(error.localizedDescription))
            return
        }
        if Task.isCancelled || intent[id] != true { setState(id, .disconnected); return }

        // Spawn the long-running tunnel (own process group, D2). Handlers wired
        // in init so no early stderr is lost (the cause of the empty-output bug).
        let args = ssmArguments(connection: connection, target: resolution.target)
        guard let process = SpawnedProcess(
            executable: vault,
            arguments: args,
            environment: env,
            onOutput: { [weak self] text in
                Task { @MainActor in self?.appendOutput(id: id, text: text) }
            },
            onTermination: { [weak self] code in
                Task { @MainActor in self?.handleTermination(id: id, exitCode: code) }
            }
        ) else {
            setState(id, .failed("Failed to launch aws-vault (posix_spawn failed)."))
            return
        }
        processes[id] = process

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
            setState(id, .failed("Tunnel did not become ready within \(Int(readinessTimeout))s. \(lastOutput[id] ?? "")".trimmingCharacters(in: .whitespaces)))
        }
    }

    func stop(id: UUID, intentional: Bool) {
        if intentional { intent[id] = false }
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

        // Intentional stop already settled the state.
        guard intent[id] == true else { return }

        // Log exit code + captured output on unexpected exit so the real error is visible.
        let out = lastOutput[id] ?? ""
        if out.isEmpty {
            NSLog("[tunnel %@] exited unexpectedly, code=%d, no output. (127=exec failed)", id.uuidString.prefix(8) as CVarArg, exitCode)
        } else {
            NSLog("[tunnel %@] exited unexpectedly, code=%d. Output:\n%@", id.uuidString.prefix(8) as CVarArg, exitCode, out)
        }

        // Sleep-induced drop: don't count toward the cap, wait for wake (D14).
        if isSleeping || expectedSleepDrops.contains(id) {
            setState(id, .reconnecting)
            return
        }

        guard settings.autoReconnect else {
            setState(id, .disconnected)
            return
        }

        let attempts = (reconnectAttempts[id] ?? 0) + 1
        reconnectAttempts[id] = attempts
        if attempts > maxReconnectAttempts {
            let detail = (lastOutput[id]?.split(separator: "\n").last).map { " Last: \($0)" } ?? ""
            setState(id, .failed("Stopped after \(maxReconnectAttempts) failed reconnects.\(detail)"))
            return
        }
        scheduleReconnect(id: id, delay: settings.reconnectDelay)
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

        // Creds may have expired during sleep — drop cached warmers so the first
        // staggered reconnect re-warms once; the rest await it (D14).
        credentialWarmers.removeAll()

        // Stagger with per-tunnel jitter to avoid a thundering herd / dialog pileup.
        var offset = 0.0
        for id in toReconnect {
            guard let connection = store.connection(id: id) else { continue }
            reconnectAttempts[id] = 0
            let jitter = Double(abs(id.hashValue) % 1000) / 1000.0  // 0–1s deterministic jitter
            let delay = settings.reconnectDelay + offset + jitter
            setState(id, .reconnecting)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.intent[id] == true else { return }
                self.start(connection)
            }
            offset += 1.0
        }
    }

    /// Ensure credentials for `profile` are warm before any tunnel for it spawns.
    /// Concurrent callers share one warming task → exactly one MFA prompt per profile.
    private func ensureCredentials(profile: String, vault: String) async {
        if let existing = credentialWarmers[profile] {
            await existing.value
            return
        }
        let env = childEnvironment()
        let task = Task.detached(priority: .userInitiated) {
            // A cheap call that forces aws-vault to acquire + cache session creds.
            _ = try? CommandRunner.run(
                executable: vault,
                arguments: ["exec", profile, "--prompt=osascript", "--", "aws", "sts", "get-caller-identity"],
                environment: env
            )
        }
        credentialWarmers[profile] = task   // atomic on @MainActor: later starts see it
        await task.value
    }

    // MARK: - Teardown

    private func teardownProcess(id: UUID) {
        if let process = processes[id] {
            process.terminateGroup()
        }
        processes[id] = nil
    }

    /// Synchronous teardown of all tunnels for app quit (D2).
    func terminateAll() {
        for (_, process) in processes {
            process.terminateGroupSync()
        }
        processes.removeAll()
    }

    // MARK: - Helpers

    private func ssmArguments(connection: Connection, target: String) -> [String] {
        // Literal JSON passed as ONE argv element — no shell, no escaping (D1).
        let parameters = "{\"host\":[\"\(connection.dbHost)\"],\"portNumber\":[\"\(connection.remotePort)\"],\"localPortNumber\":[\"\(connection.localPort)\"]}"
        return [
            "exec", connection.awsProfile, "--prompt=osascript", "--",
            "aws", "ssm", "start-session",
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
        states[id] = newState
        activeCount = states.values.filter { $0.isActive }.count
    }
}
