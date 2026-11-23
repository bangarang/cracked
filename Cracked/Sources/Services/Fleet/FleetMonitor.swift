import Foundation
import SwiftUI
import AppKit

/// A value shared with the server's queue.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}

/// What the app last heard from each paired Mac.
struct PeerState: Sendable, Equatable {
    var report: SystemReport?
    var lastSeen: Date?
    var error: String?

    static func == (lhs: PeerState, rhs: PeerState) -> Bool {
        lhs.lastSeen == rhs.lastSeen && lhs.error == rhs.error && lhs.report?.timestamp == rhs.report?.timestamp
    }

    /// Answered within the last 3 minutes.
    func isOnline(now: Date = Date()) -> Bool {
        guard let lastSeen else { return false }
        return now.timeIntervalSince(lastSeen) < 180 && error == nil
    }
}

/// A remote agent and the Mac it's on.
struct FleetAgent: Identifiable, Sendable {
    let peer: FleetPeer
    let agent: SystemReport.Agent
    var id: String { "\(peer.id)/\(agent.sessionID)" }
    var isWaiting: Bool { ["needsInput", "done", "error"].contains(agent.status) }
}

/// The fleet as of the app's last poll, written for `Cracked hook`, `status --fleet` and the
/// MCP server, which run as separate short-lived processes.
struct FleetCache: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let peer: FleetPeer
        let report: SystemReport?
        let lastSeen: Date?
    }
    let writtenAt: Date
    let entries: [Entry]

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cracked", isDirectory: true)
            .appendingPathComponent("fleet-cache.json")
    }

    static func load() -> FleetCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.fleet.decode(FleetCache.self, from: data)
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder.fleet.encode(self).write(to: Self.url, options: .atomic)
    }

    /// Reports from peers seen in the last 3 minutes.
    func onlineReports(now: Date = Date()) -> [SystemReport] {
        entries.compactMap { entry in
            guard let seen = entry.lastSeen, now.timeIntervalSince(seen) < 180 else { return nil }
            return entry.report
        }
    }
}

@MainActor
final class FleetMonitor: ObservableObject {
    @Published private(set) var peers: [FleetPeer] = []
    @Published private(set) var states: [String: PeerState] = [:]
    @Published private(set) var candidates: [TailscalePeers.Candidate] = []
    @Published private(set) var isEnabled = false
    @Published private(set) var serverError: String?
    @Published private(set) var pairingCode: String?
    @Published private(set) var pairingExpiry: Date?
    /// Actions in flight, by "peerID/target", so buttons can show progress.
    @Published var busy: Set<String> = []
    @Published var lastActionMessage: String?

    /// Whether the menu is open; polls every 10 s while it is, every 60 s otherwise.
    var menuOpen = false {
        didSet { if menuOpen && !oldValue { pollSoon() } }
    }

    let store: FleetStore
    let latestReport = Locked<SystemReport?>(nil)
    let machine = Locked<MachineIdentity>(MachineIdentity.current())
    private let pairing = PairingSession()
    private var server: FleetServer?
    private var pollTask: Task<Void, Never>?
    private var lastPoll = Date.distantPast
    private var knownStatuses: [String: String] = [:]
    private let db: DatabaseManager?
    var notifyAgent: ((FleetAgent) -> Void)?

    private var wakeObserver: NSObjectProtocol?

    init(db: DatabaseManager?, store: FleetStore = .shared) {
        self.db = db
        self.store = store
        peers = store.peers()
        // Sockets don't reliably survive sleep; re-bind and poll right after waking.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.server?.restart()
                self?.pollSoon()
            }
        }
    }

    var client: FleetClient { FleetClient(store: store, me: machine.get()) }

    // MARK: - Lifecycle

    func startIfEnabled() {
        isEnabled = store.isEnabled
        guard isEnabled else { return }
        startServer()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval: TimeInterval = self.menuOpen ? 10 : 60
                if Date().timeIntervalSince(self.lastPoll) >= interval {
                    // Watchdog: a listener that isn't accepting connections gets re-bound.
                    if let server = self.server, !server.isReady { server.restart() }
                    await self.poll()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        Task.detached { [weak self] in
            let found = TailscalePeers.discover()
            await MainActor.run { self?.candidates = found }
        }
    }

    func setEnabled(_ enabled: Bool) {
        store.defaults.set(enabled, forKey: FleetStore.enabledKey)
        if enabled {
            startIfEnabled()
        } else {
            isEnabled = false
            pollTask?.cancel()
            server?.stop()
            server = nil
            closePairing()
            states = [:]
            try? FileManager.default.removeItem(at: FleetCache.url)
        }
    }

    /// Applies changes made outside the app (the CLI): on/off and new peers.
    func syncWithSettings() {
        let enabled = store.isEnabled
        if enabled != isEnabled {
            if enabled { startIfEnabled() } else { setEnabled(false) }
        }
        reloadPeers()
        pollSoon()
    }

    /// After a settings change (LAN on/off): the server reads the scope live, so a restart
    /// just re-binds; it retries by itself if the port is still being released.
    func restartServer() {
        server?.restart()
    }

    private func startServer() {
        guard server == nil else { return }
        let db = self.db
        let latest = latestReport
        let machine = self.machine
        let environment = FleetRouter.Environment(
            machine: { machine.get() },
            report: { latest.get() },
            records: { (try? db?.allRecords()) ?? [] },
            history: { hours in (try? db?.recentSnapshots(hours: hours)) ?? [] },
            periodStats: { start, end in try? db?.periodStats(from: start, to: end, defaultCores: machine.get().cpuCores) },
            unloadModel: { name in await Ollama.unload(model: name) },
            restartApp: { pid, path in AppActions.restart(pid: pid, bundlePath: path) },
            snoozeApp: { path, until in
                var ignored = IgnoredApps.load()
                ignored.prune()
                ignored.until[path] = until
                ignored.save()
            },
            peersChanged: { [weak self] in
                Task { @MainActor in
                    self?.reloadPeers()
                    self?.pairingCode = nil
                    self?.pollSoon()
                }
            })
        let store = self.store
        let server = FleetServer(router: FleetRouter(environment: environment, store: store, pairing: pairing),
                                 port: store.port, scope: { store.scope })
        server.onStateChange = { [weak self] message in
            Task { @MainActor in self?.serverError = message }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            serverError = error.localizedDescription
        }
    }

    func reloadPeers() {
        peers = store.peers()
        states = states.filter { id, _ in peers.contains { $0.id == id } }
    }

    func refreshCandidates() {
        Task.detached { [weak self] in
            let found = TailscalePeers.discover()
            await MainActor.run { self?.candidates = found }
        }
    }

    /// Tailscale Macs that aren't paired yet (matched by address).
    var unpairedCandidates: [TailscalePeers.Candidate] {
        candidates.filter { candidate in !peers.contains { $0.address == candidate.address } }
    }

    // MARK: - Polling

    func pollSoon() {
        lastPoll = .distantPast
    }

    func poll() async {
        lastPoll = Date()
        let client = self.client
        let peers = self.peers
        let results = await withTaskGroup(of: (String, Result<SystemReport, Error>).self) { group in
            for peer in peers {
                group.addTask { (peer.id, await Result(catching: { try await client.report(peer) })) }
            }
            var results: [String: Result<SystemReport, Error>] = [:]
            for await (id, result) in group { results[id] = result }
            return results
        }
        var newStates = states
        for (id, result) in results {
            var state = newStates[id] ?? PeerState()
            switch result {
            case .success(let report):
                state.report = report
                state.lastSeen = Date()
                state.error = nil
                // Keep the stored name and hardware current.
                if let machine = report.machine, machine != peers.first(where: { $0.id == id })?.machine {
                    store.update(id) { $0.machine = machine }
                }
            case .failure(let error):
                state.error = error.localizedDescription
            }
            newStates[id] = state
        }
        if newStates != states { states = newStates }
        reloadPeers()
        notifyNewlyWaiting()
        FleetCache(writtenAt: Date(), entries: self.peers.map {
            FleetCache.Entry(peer: $0, report: states[$0.id]?.report, lastSeen: states[$0.id]?.lastSeen)
        }).save()
    }

    // MARK: - Agents and notifications

    var remoteAgents: [FleetAgent] {
        peers.flatMap { peer -> [FleetAgent] in
            guard let state = states[peer.id], state.isOnline(), let report = state.report else { return [] }
            return report.agents.map { FleetAgent(peer: peer, agent: $0) }
        }
    }

    /// With more than one Mac awake, only the one used most recently notifies, so an
    /// agent finishing doesn't ping all three. The others stay quiet.
    func shouldNotifyHere(localIdleSeconds: Double = UserActivity.idleSeconds()) -> Bool {
        let peerIdle = peers.compactMap { peer -> Double? in
            guard let state = states[peer.id], state.isOnline(), let report = state.report,
                  let idle = report.idleSeconds, let seen = state.lastSeen else { return nil }
            // Account for the time since that report was taken.
            return idle + Date().timeIntervalSince(seen)
        }
        return peerIdle.allSatisfy { localIdleSeconds <= $0 }
    }

    private func notifyNewlyWaiting() {
        let agents = remoteAgents
        let first = knownStatuses.isEmpty
        defer { knownStatuses = Dictionary(agents.map { ($0.id, $0.agent.status) }, uniquingKeysWith: { a, _ in a }) }
        guard !first, shouldNotifyHere() else { return }
        for agent in agents where agent.isWaiting && knownStatuses[agent.id] != agent.agent.status {
            notifyAgent?(agent)
        }
    }

    // MARK: - Pairing

    func openPairing() {
        if !isEnabled { setEnabled(true) }
        pairingCode = pairing.open()
        pairingExpiry = pairing.expiry
    }

    func closePairing() {
        pairing.close()
        pairingCode = nil
        pairingExpiry = nil
    }

    /// Whether the code is still valid (it expires and locks after 5 wrong tries).
    func checkPairingCode() {
        if pairingCode != nil, pairing.currentCode() == nil {
            pairingCode = nil
            pairingExpiry = nil
        }
    }

    func pair(address: String, port: Int, code: String) async throws -> FleetPeer {
        if !isEnabled { setEnabled(true) }
        let peer = try await client.pair(address: address.trimmingCharacters(in: .whitespaces), port: port,
                                         code: code, myPort: store.port)
        reloadPeers()
        pollSoon()
        return peer
    }

    func remove(_ peer: FleetPeer) {
        let client = self.client
        Task {
            await client.unpair(peer)
            store.remove(peer.id)
            reloadPeers()
        }
    }

    func setPermission(_ peer: FleetPeer, unloadModels: Bool? = nil, restartApps: Bool? = nil) {
        store.update(peer.id) {
            if let unloadModels { $0.allowUnloadModels = unloadModels }
            if let restartApps { $0.allowRestartApps = restartApps }
        }
        reloadPeers()
    }

    // MARK: - Remote actions

    func perform(_ action: String, on peer: FleetPeer, target: String, days: Int? = nil) {
        let key = "\(peer.id)/\(target)"
        busy.insert(key)
        let client = self.client
        Task {
            do {
                let response = try await client.action(peer, action, target: target, days: days)
                lastActionMessage = response.message
            } catch {
                lastActionMessage = error.localizedDescription
            }
            busy.remove(key)
            pollSoon()
        }
    }
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
