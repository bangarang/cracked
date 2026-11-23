import Foundation
import Testing
import CryptoKit
@testable import Cracked

// MARK: - Helpers

private func machine(_ id: String, name: String = "Test Mac", chip: String = "Apple M4 Pro", cores: Int = 12) -> MachineIdentity {
    MachineIdentity(id: id, name: name, model: "Mac16,11", chip: chip, cpuCores: cores, performanceCores: 8,
                    memoryGB: 48, formFactor: .mini)
}

private func tempStore() -> FleetStore {
    let suite = "cracked-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let keys = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite)-keys.json")
    return FleetStore(defaults: defaults, keysURL: keys)
}

private func report(load: Double = 2, cores: Int = 12, used: Double = 20, total: Double = 48,
                    pressure: MemoryPressure = .normal, machine: MachineIdentity? = nil,
                    agents: [SystemReport.Agent] = [], restart: [SystemReport.RestartCandidate] = []) -> SystemReport {
    var r = SystemReport(timestamp: Date(timeIntervalSince1970: 1_800_000_000), pressure: .normal, loadAverage: load,
                         cpuCores: cores, memoryUsedGB: used, memoryTotalGB: total, totalProcesses: 900,
                         cpuHogs: [], worthARestart: restart, trackedApps: [], agents: agents,
                         memoryPressure: pressure, localModels: [])
    r.machine = machine
    r.schemaVersion = SystemReport.currentSchemaVersion
    return r
}

private func environment(_ me: MachineIdentity, report: SystemReport?, restarted: Locked<[String]> = Locked([])) -> FleetRouter.Environment {
    FleetRouter.Environment(
        machine: { me }, report: { report }, records: { [] }, history: { _ in [] },
        periodStats: { _, _ in nil }, unloadModel: { _ in true },
        restartApp: { _, path in restarted.set(restarted.get() + [path]); return true },
        snoozeApp: { _, _ in })
}

// MARK: - Auth

@Suite("Fleet auth")
struct FleetAuthTests {
    @Test("Both sides derive the same key; a wrong code fails the proof")
    func pairingCrypto() throws {
        let a = Curve25519.KeyAgreement.PrivateKey()
        let b = Curve25519.KeyAgreement.PrivateKey()
        let proof = FleetAuth.pairingProof(code: "123456", publicKey: a.publicKey.rawRepresentation, otherMachineID: "B")
        #expect(FleetAuth.verifyPairingProof(proof, code: "123456", publicKey: a.publicKey.rawRepresentation, otherMachineID: "B"))
        #expect(!FleetAuth.verifyPairingProof(proof, code: "123457", publicKey: a.publicKey.rawRepresentation, otherMachineID: "B"))
        #expect(!FleetAuth.verifyPairingProof(proof, code: "123456", publicKey: b.publicKey.rawRepresentation, otherMachineID: "B"))

        let keyA = try FleetAuth.sharedKey(privateKey: a, peerPublicKey: b.publicKey.rawRepresentation, machineIDs: ("A", "B"), code: "123456")
        let keyB = try FleetAuth.sharedKey(privateKey: b, peerPublicKey: a.publicKey.rawRepresentation, machineIDs: ("B", "A"), code: "123456")
        #expect(keyA == keyB)
        #expect(keyA.count == 32)
    }

    @Test("Signed requests verify; tampering, old timestamps and unknown machines don't")
    func signing() {
        let key = Data(repeating: 7, count: 32)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let headers = FleetAuth.signedHeaders(machineID: "A", key: key, method: "GET", path: "/v1/report", body: Data(), now: now)
        let lookup: (String) -> Data? = { $0 == "A" ? key : nil }

        #expect(FleetAuth.verify(method: "GET", path: "/v1/report", headers: headers, body: Data(), now: now, keyFor: lookup) == .ok(machineID: "A"))
        #expect(FleetAuth.verify(method: "GET", path: "/v1/records", headers: headers, body: Data(), now: now, keyFor: lookup) != .ok(machineID: "A"))
        #expect(FleetAuth.verify(method: "POST", path: "/v1/report", headers: headers, body: Data("x".utf8), now: now, keyFor: lookup) != .ok(machineID: "A"))
        #expect(FleetAuth.verify(method: "GET", path: "/v1/report", headers: headers, body: Data(), now: now + 600, keyFor: lookup) != .ok(machineID: "A"))
        #expect(FleetAuth.verify(method: "GET", path: "/v1/report", headers: headers, body: Data(), now: now, keyFor: { _ in nil }) == .unauthorized("Not paired"))
    }

    @Test("Only Tailscale and loopback by default; private LAN ranges when allowed")
    func networkScope() {
        for allowed in ["100.103.44.69", "100.64.0.1", "127.0.0.1", "::1", "fd7a:115c:a1e0::1234", "::ffff:100.77.74.100"] {
            #expect(FleetAuth.isAllowed(address: allowed, scope: .tailscaleOnly), "\(allowed)")
        }
        for blocked in ["192.168.1.20", "10.0.0.5", "8.8.8.8", "100.128.0.1", "fe80::1%en0", "2001:db8::1"] {
            #expect(!FleetAuth.isAllowed(address: blocked, scope: .tailscaleOnly), "\(blocked)")
        }
        #expect(FleetAuth.isAllowed(address: "192.168.1.20", scope: .tailscaleAndLAN))
        #expect(FleetAuth.isAllowed(address: "fe80::1%en0", scope: .tailscaleAndLAN))
        #expect(!FleetAuth.isAllowed(address: "8.8.8.8", scope: .tailscaleAndLAN))
    }

    @Test("Pairing codes lock after 5 wrong tries and expire")
    func pairingSession() {
        let session = PairingSession()
        let now = Date()
        session.open(now: now, code: "111111")
        #expect(session.currentCode(now: now) == "111111")
        #expect(session.currentCode(now: now + PairingSession.lifetime + 1) == nil)
        for _ in 0..<5 { session.recordFailure() }
        #expect(session.currentCode(now: now) == nil)
    }
}

// MARK: - HTTP

@Suite("Fleet HTTP")
struct FleetHTTPTests {
    @Test("Parses a request once headers and body have arrived")
    func parse() {
        let raw = "POST /v1/actions/unload-model?x=1 HTTP/1.1\r\nHost: a\r\nContent-Length: 4\r\n\r\nbody"
        #expect(HTTPRequest.parse(Data(raw.utf8).prefix(20)) == .incomplete)
        #expect(HTTPRequest.parse(Data(raw.dropLast(2).utf8)) == .incomplete)
        guard case .complete(let request) = HTTPRequest.parse(Data(raw.utf8)) else {
            Issue.record("expected a complete request"); return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/v1/actions/unload-model")
        #expect(request.target == "/v1/actions/unload-model?x=1")
        #expect(request.query["x"] == "1")
        #expect(request.body == Data("body".utf8))
        #expect(HTTPRequest.parse(Data("garbage\r\n\r\n".utf8)) == .invalid)
    }
}

// MARK: - Router

@Suite("Fleet router")
struct FleetRouterTests {
    let mini = machine("MINI", name: "Mac mini")
    let laptop = machine("MBP", name: "MacBook Pro", chip: "Apple M4 Max", cores: 16)

    /// Pairs `laptop` (client side, by hand) with `mini` (router) and returns both stores and the router.
    func paired() async throws -> (FleetStore, FleetStore, FleetRouter, Locked<[String]>) {
        let miniStore = tempStore(), laptopStore = tempStore()
        let pairing = PairingSession()
        let code = pairing.open(code: "424242")
        let restarted = Locked<[String]>([])
        let candidate = SystemReport.RestartCandidate(name: "Comet", pid: 99, bundlePath: "/Applications/Comet.app",
                                                      memoryMB: 65_000, memory: "63 GB", processCount: 170,
                                                      uptime: "10d", uptimeSeconds: 864_000)
        let router = FleetRouter(environment: environment(mini, report: report(machine: mini, restart: [candidate]), restarted: restarted),
                                 store: miniStore, pairing: pairing)

        let key = Curve25519.KeyAgreement.PrivateKey()
        let body = try JSONEncoder.fleet.encode(FleetPairRequest(
            machine: laptop, port: 47474, publicKey: key.publicKey.rawRepresentation,
            proof: FleetAuth.pairingProof(code: code, publicKey: key.publicKey.rawRepresentation, otherMachineID: mini.id)))
        let response = await router.handle(HTTPRequest(method: "POST", target: "/v1/pair", headers: [:], body: body),
                                           remoteAddress: "100.77.74.100")
        #expect(response.status == 200)
        let reply = try JSONDecoder.fleet.decode(FleetPairResponse.self, from: response.body)
        #expect(FleetAuth.verifyPairingProof(reply.proof, code: code, publicKey: reply.publicKey, otherMachineID: laptop.id))
        let shared = try FleetAuth.sharedKey(privateKey: key, peerPublicKey: reply.publicKey, machineIDs: (laptop.id, mini.id), code: code)
        laptopStore.upsert(FleetPeer(machine: mini, address: "127.0.0.1", port: 47474, pairedAt: Date()), key: shared)
        #expect(miniStore.key(for: laptop.id) == shared, "Both sides hold the same key")
        #expect(miniStore.peer(id: laptop.id)?.address == "100.77.74.100")
        #expect(pairing.currentCode() == nil, "A code works for one Mac")
        return (miniStore, laptopStore, router, restarted)
    }

    func signedRequest(_ store: FleetStore, _ method: String, _ target: String, body: Data = Data()) -> HTTPRequest {
        let key = store.key(for: mini.id)!
        let headers = FleetAuth.signedHeaders(machineID: laptop.id, key: key, method: method, path: target, body: body)
        return HTTPRequest(method: method, target: target, headers: headers, body: body)
    }

    @Test("Pair, then fetch the report with a signed request")
    func pairAndReport() async throws {
        let (_, laptopStore, router, _) = try await paired()
        let response = await router.handle(signedRequest(laptopStore, "GET", "/v1/report"), remoteAddress: "100.77.74.100")
        #expect(response.status == 200)
        let decoded = try JSONDecoder.fleet.decode(SystemReport.self, from: response.body)
        #expect(decoded.machine?.name == "Mac mini")
    }

    @Test("Unsigned requests and wrong codes are refused")
    func refusals() async throws {
        let router = FleetRouter(environment: environment(mini, report: report()), store: tempStore(), pairing: PairingSession())
        let unsigned = await router.handle(HTTPRequest(method: "GET", target: "/v1/report", headers: [:], body: Data()), remoteAddress: "100.1.1.1")
        #expect(unsigned.status == 401)

        let closed = await router.handle(HTTPRequest(method: "POST", target: "/v1/pair", headers: [:], body: Data("{}".utf8)), remoteAddress: "100.1.1.1")
        #expect(closed.status == 409, "No code showing, no pairing")

        let pairing = PairingSession()
        pairing.open(code: "000001")
        let open = FleetRouter(environment: environment(mini, report: report()), store: tempStore(), pairing: pairing)
        let key = Curve25519.KeyAgreement.PrivateKey()
        let body = try JSONEncoder.fleet.encode(FleetPairRequest(
            machine: laptop, port: 47474, publicKey: key.publicKey.rawRepresentation,
            proof: FleetAuth.pairingProof(code: "999999", publicKey: key.publicKey.rawRepresentation, otherMachineID: mini.id)))
        let wrong = await open.handle(HTTPRequest(method: "POST", target: "/v1/pair", headers: [:], body: body), remoteAddress: "100.1.1.1")
        #expect(wrong.status == 401)
    }

    @Test("Remote restarts need permission and only work on Worth a Restart apps")
    func actionPermissions() async throws {
        let (miniStore, laptopStore, router, restarted) = try await paired()
        let body = try JSONEncoder.fleet.encode(FleetActionRequest(target: "Comet"))
        let denied = await router.handle(signedRequest(laptopStore, "POST", "/v1/actions/restart-app", body: body), remoteAddress: "100.77.74.100")
        #expect(denied.status == 403)
        #expect(restarted.get().isEmpty)

        miniStore.update(laptop.id) { $0.allowRestartApps = true }
        let notListed = try JSONEncoder.fleet.encode(FleetActionRequest(target: "Finder"))
        let missing = await router.handle(signedRequest(laptopStore, "POST", "/v1/actions/restart-app", body: notListed), remoteAddress: "100.77.74.100")
        #expect(missing.status == 404)

        let allowed = await router.handle(signedRequest(laptopStore, "POST", "/v1/actions/restart-app", body: body), remoteAddress: "100.77.74.100")
        #expect(allowed.status == 200)
        #expect(restarted.get() == ["/Applications/Comet.app"])
    }
}

// MARK: - Real sockets

@Suite("Fleet over loopback")
struct FleetLoopbackTests {
    @Test("Pairs and fetches a report through the real listener and client")
    func endToEnd() async throws {
        let mini = machine("MINI-\(UUID().uuidString)", name: "Mac mini")
        let laptop = machine("MBP-\(UUID().uuidString)", name: "MacBook Pro")
        let miniStore = tempStore(), laptopStore = tempStore()
        let pairing = PairingSession()
        let code = pairing.open()
        let port = Int.random(in: 49152...60000)
        let server = FleetServer(router: FleetRouter(environment: environment(mini, report: report(load: 3.3, machine: mini)),
                                                     store: miniStore, pairing: pairing),
                                 port: port, scope: { .tailscaleOnly })
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(200))

        let client = FleetClient(store: laptopStore, me: laptop)
        let hello = try await client.hello(address: "127.0.0.1", port: port)
        #expect(hello.machine.id == mini.id)
        #expect(hello.pairingOpen)

        let peer = try await client.pair(address: "127.0.0.1", port: port, code: code, myPort: 47474)
        #expect(peer.name == "Mac mini")
        let fetched = try await client.report(peer)
        #expect(fetched.loadAverage == 3.3)
        #expect(miniStore.peer(id: laptop.id) != nil)
    }
}

// MARK: - Discovery and ranking

@Suite("Fleet discovery and ranking")
struct FleetRankingTests {
    @Test("Parses tailscale status: online macOS peers, IPv4 first")
    func tailscale() {
        let json = """
            {"Self":{"HostName":"minis-mac-mini"},"Peer":{
              "a":{"HostName":"rockbook-pro","DNSName":"rockbook-pro.tail842cbe.ts.net.","OS":"macOS","Online":true,"TailscaleIPs":["100.77.74.100","fd7a:115c:a1e0::1"]},
              "b":{"HostName":"iphone171","OS":"iOS","Online":true,"TailscaleIPs":["100.69.95.43"]},
              "c":{"HostName":"rocks-macbook-pro","OS":"macOS","Online":false,"TailscaleIPs":["100.87.73.40"]}}}
            """
        let peers = TailscalePeers.parse(Data(json.utf8))
        #expect(peers.map(\.hostName) == ["rockbook-pro", "rocks-macbook-pro"])
        #expect(peers[0].address == "100.77.74.100")
        #expect(peers[0].dnsName == "rockbook-pro.tail842cbe.ts.net")
        #expect(!peers[1].online)
    }

    @Test("Least loaded Mac wins, with memory pressure as a penalty")
    func ranking() {
        let here = FleetMember(report: report(load: 40, cores: 16, machine: machine("A", name: "MacBook Pro")), address: nil, isThisMac: true)
        let idle = FleetMember(report: report(load: 1.2, cores: 12, machine: machine("B", name: "Mac mini")), address: "100.1.1.1", isThisMac: false)
        let squeezed = FleetMember(report: report(load: 1, cores: 10, pressure: .critical, machine: machine("C", name: "M1 Max")),
                                   address: "100.1.1.2", isThisMac: false)
        #expect(FleetRanking.ranked([here, idle, squeezed]).map(\.name) == ["Mac mini", "M1 Max", "MacBook Pro"])
        let text = FleetRanking.recommendation([here, idle, squeezed])
        #expect(text.hasPrefix("Least loaded: Mac mini at 100.1.1.1"))
        #expect(text.contains("consider running heavy builds"))
        #expect(FleetRanking.idlePeerHint([here, idle, squeezed]) == "Mac mini is idle (load 1.2 on 12 cores)")
    }

    @Test("The brief mentions an idle Mac only when this one is struggling")
    func brief() {
        var busy = report(load: 46, cores: 16)
        busy = SystemReport(timestamp: busy.timestamp, pressure: .critical, loadAverage: 46, cpuCores: 16, memoryUsedGB: 40,
                            memoryTotalGB: 64, totalProcesses: 900, cpuHogs: [], worthARestart: [], trackedApps: [],
                            agents: [], memoryPressure: .normal, localModels: [])
        let brief = busy.agentBrief(idlePeerHint: "Mac mini is idle (load 1.2 on 12 cores)")
        #expect(brief?.contains("Mac mini is idle") == true)
        #expect(report(load: 1).agentBrief(idlePeerHint: "x") == nil)
    }

    @Test("Reports round-trip over the wire, including agent session IDs")
    func wireRoundTrip() throws {
        let agent = SystemReport.Agent(sessionID: "abc-123", source: "paseo", provider: "claude", title: "Fix it",
                                       project: "cracked", cwd: "/x", status: "needsInput", message: nil,
                                       terminal: nil, updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                       paseoURL: "paseo://agent/1")
        let original = report(machine: machine("A"), agents: [agent])
        let decoded = try JSONDecoder.fleet.decode(SystemReport.self, from: JSONEncoder.fleet.encode(original))
        #expect(decoded.agents.first?.sessionID == "abc-123")
        #expect(decoded.agents.first?.paseoURL == "paseo://agent/1")
        #expect(decoded.machine == original.machine)
    }
}

// MARK: - Identity, stats, score

@Suite("Machine identity and public stats")
struct PublicStatsTests {
    @Test("Chip class and form factor")
    func identity() {
        #expect(MachineIdentity.chipClass(from: "Apple M4 Pro") == "M4 Pro")
        #expect(MachineIdentity.chipClass(from: "Apple M1 Max") == "M1 Max")
        #expect(MachineIdentity.formFactor(model: "Mac16,11", hasBattery: false) == .mini)
        #expect(MachineIdentity.formFactor(model: "Mac16,7", hasBattery: true) == .laptop)
        #expect(MachineIdentity.formFactor(model: "MacBookPro18,2", hasBattery: false) == .laptop)
        #expect(MachineIdentity.formFactor(model: "Mac13,1", hasBattery: false) == .studio)
        let current = MachineIdentity.current()
        #expect(current.cpuCores > 0 && current.memoryGB > 0)
        #expect(MachineIdentity.current().id == current.id, "The id is stable")
    }

    @Test("Period stats from snapshots: p95, pressure share, zombie")
    func periodStats() {
        let rows = (0..<100).map { i in
            SnapshotRecord(id: nil, timestamp: Double(i), loadAvg: i == 99 ? 96 : 12, totalProcesses: 800,
                           memoryUsedMB: 30_000, memoryTotalMB: 49_152, cpuCores: 12,
                           memoryPressure: i < 25 ? 1 : 0, activeAgents: i % 7, localModelMB: 20_480,
                           zombieScore: i == 50 ? 650 : 10, zombieApp: i == 50 ? "Comet" : "Slack",
                           zombieDays: i == 50 ? 10 : 1, zombieGB: i == 50 ? 65 : 10)
        }
        let stats = PeriodStats.from(snapshots: rows, start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 100),
                                     defaultCores: 12, trackedPeak: ("Comet", 161))
        #expect(stats.peakLoadPerCore == 8)
        #expect(stats.p95LoadPerCore == 1, "One spike doesn't move the 95th percentile")
        #expect(stats.pressureFraction == 0.25)
        #expect(stats.peakAgents == 6)
        #expect(stats.peakLocalModelGB == 20)
        #expect(stats.zombieApp == "Comet")
        #expect(stats.peakTabs == 161)
        let score = CrackedScore.compute(stats)
        #expect((0...1000).contains(score))
        #expect(score > CrackedScore.compute(PeriodStats.from(snapshots: [], start: .now, end: .now, defaultCores: 12, trackedPeak: nil)))
    }

    @Test("Public stats only carry allowlisted app names")
    func sanitization() {
        var stats = PeriodStats.from(snapshots: [], start: .now, end: .now, defaultCores: 12, trackedPeak: ("Comet", 161))
        stats.zombieApp = "Secret Client Portal"
        stats.zombieDays = 12
        stats.zombieGB = 8
        let publicStats = PublicStats(stats: stats, machine: machine("A"), period: .now)
        #expect(publicStats.peakTabsApp == "Comet")
        #expect(publicStats.zombie?.app == "An app")
        #expect(publicStats.chipClass == "M4 Pro")
        let json = String(data: try! JSONEncoder().encode(publicStats), encoding: .utf8)!
        #expect(!json.contains("Secret"))
        #expect(!json.contains("Test Mac"), "Machine names never go public")
    }

    @Test("v3 snapshots save and summarize from the database")
    func database() throws {
        let db = try DatabaseManager(inMemory: true)
        let snapshot = SystemSnapshot(timestamp: Date(), loadAverage: 24, totalProcesses: 900,
                                      memoryUsedMB: 40_000, memoryTotalMB: 49_152, processes: [])
        try db.saveSnapshot(snapshot, extras: SnapshotExtras(cpuCores: 12, memoryPressure: .warning, activeAgents: 4,
                                                             localModelMB: 10_240,
                                                             zombie: .init(app: "Comet", days: 10, gb: 65)))
        try db.saveTrackedAppCounts([("Comet", 161, "tabs")])
        let stats = try db.periodStats(from: Date().addingTimeInterval(-60), to: Date().addingTimeInterval(60), defaultCores: 8)
        #expect(stats.samples == 1)
        #expect(stats.peakLoadPerCore == 2)
        #expect(stats.pressureFraction == 1)
        #expect(stats.peakAgents == 4)
        #expect(stats.zombieApp == "Comet")
        #expect(stats.peakTabs == 161)
    }

    @Test("Extended records: load per core, agents, models, one zombie row")
    func records() throws {
        let db = try DatabaseManager(inMemory: true)
        let tracker = RecordTracker(db: db)
        var beaten = try tracker.checkExtendedRecords(loadPerCore: 2.5, activeAgents: 5, localModelGB: 30,
                                                      zombie: .init(app: "Comet", days: 10, gb: 65))
        #expect(Set(beaten) == ["peak_load_per_core", "peak_concurrent_agents", "peak_local_model_gb", "zombie_score"])
        beaten = try tracker.checkExtendedRecords(loadPerCore: 1, activeAgents: 1, localModelGB: 0,
                                                  zombie: .init(app: "Arc", days: 20, gb: 40))
        #expect(beaten == ["zombie_score"])
        let zombies = try db.allRecords().filter { $0.recordType == "zombie_score" }
        #expect(zombies.count == 1)
        #expect(zombies.first?.details?.hasPrefix("Arc") == true)
    }
}
