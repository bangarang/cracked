import Foundation

/// A Mac this one is paired with.
struct FleetPeer: Codable, Identifiable, Equatable, Hashable, Sendable {
    var machine: MachineIdentity
    /// Tailscale IP, MagicDNS name or LAN address.
    var address: String
    var port: Int
    var pairedAt: Date
    /// What this Mac lets that peer do here. Off by default.
    var allowUnloadModels: Bool = false
    var allowRestartApps: Bool = false

    var id: String { machine.id }
    var name: String { machine.name }

    var baseURL: URL? {
        let host = address.contains(":") && !address.hasPrefix("[") ? "[\(address)]" : address
        return URL(string: "http://\(host):\(port)")
    }
}

/// Fleet settings, paired Macs and their keys.
///
/// Peers live in UserDefaults (shared by the app, the CLI and the MCP server, which run
/// from the same bundle). Keys live in a 0600 file next to the database rather than the
/// Keychain: Keychain items are tied to the code signature, and ad-hoc builds from source
/// get a new one every build, which would prompt for the Keychain after every rebuild.
struct FleetStore: @unchecked Sendable {  // UserDefaults is thread-safe
    static let enabledKey = "fleetEnabled"
    static let portKey = "fleetPort"
    static let allowLANKey = "fleetAllowLAN"
    static let peersKey = "fleetPeers"
    static let defaultPort = 47474

    let defaults: UserDefaults
    let keysURL: URL

    nonisolated(unsafe) static let shared = FleetStore()

    init(defaults: UserDefaults = .standard, keysURL: URL? = nil) {
        self.defaults = defaults
        self.keysURL = keysURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cracked", isDirectory: true)
            .appendingPathComponent("fleet-keys.json")
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    var port: Int {
        let port = defaults.integer(forKey: Self.portKey)
        return (1024...65535).contains(port) ? port : Self.defaultPort
    }

    var scope: FleetAuth.NetworkScope {
        defaults.bool(forKey: Self.allowLANKey) ? .tailscaleAndLAN : .tailscaleOnly
    }

    // MARK: - Peers

    func peers() -> [FleetPeer] {
        guard let data = defaults.data(forKey: Self.peersKey),
              let peers = try? JSONDecoder.fleet.decode([FleetPeer].self, from: data) else { return [] }
        return peers
    }

    func peer(id: String) -> FleetPeer? { peers().first { $0.id == id } }

    func save(_ peers: [FleetPeer]) {
        defaults.set(try? JSONEncoder.fleet.encode(peers), forKey: Self.peersKey)
    }

    /// Adds or replaces a peer (by machine id) and stores its key.
    func upsert(_ peer: FleetPeer, key: Data? = nil) {
        var all = peers().filter { $0.id != peer.id }
        all.append(peer)
        save(all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        if let key { setKey(key, for: peer.id) }
    }

    func update(_ id: String, _ change: (inout FleetPeer) -> Void) {
        var all = peers()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[index])
        save(all)
    }

    func remove(_ id: String) {
        save(peers().filter { $0.id != id })
        var keys = loadKeys()
        keys[id] = nil
        writeKeys(keys)
    }

    // MARK: - Keys

    func key(for machineID: String) -> Data? {
        loadKeys()[machineID].flatMap { Data(base64Encoded: $0) }
    }

    func setKey(_ key: Data, for machineID: String) {
        var keys = loadKeys()
        keys[machineID] = key.base64EncodedString()
        writeKeys(keys)
    }

    private func loadKeys() -> [String: String] {
        guard let data = try? Data(contentsOf: keysURL),
              let keys = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return keys
    }

    private func writeKeys(_ keys: [String: String]) {
        let directory = keysURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(keys) else { return }
        // Create with 0600 before writing so the key is never world-readable, even briefly.
        if !FileManager.default.fileExists(atPath: keysURL.path) {
            FileManager.default.createFile(atPath: keysURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? data.write(to: keysURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keysURL.path)
    }
}

extension JSONEncoder {
    static var fleet: JSONEncoder { SystemReport.wireEncoder }
}

extension JSONDecoder {
    static var fleet: JSONDecoder { SystemReport.wireDecoder }
}

// MARK: - Wire types

/// `GET /v1/hello`: who's there, no auth needed.
struct FleetHello: Codable, Sendable, Equatable {
    let machine: MachineIdentity
    let schemaVersion: Int
    let appVersion: String?
    /// Whether the caller (by its X-Cracked-Machine header) is paired with this Mac.
    let paired: Bool
    /// Whether this Mac is currently showing a pairing code.
    let pairingOpen: Bool
}

struct FleetPairRequest: Codable, Sendable {
    let machine: MachineIdentity
    let port: Int
    let publicKey: Data
    let proof: Data
}

struct FleetPairResponse: Codable, Sendable {
    let machine: MachineIdentity
    let publicKey: Data
    let proof: Data
}

/// `GET /v1/history`: downsampled trend points.
struct FleetHistory: Codable, Sendable, Equatable {
    struct Point: Codable, Sendable, Equatable {
        let date: Date
        let loadAverage: Double
        let memoryUsedGB: Double
    }
    let points: [Point]
}

struct FleetRecord: Codable, Sendable, Equatable {
    let recordType: String
    let value: Double
    let appName: String?
    let achievedAt: Date
    let details: String?

    init(_ entry: RecordEntry) {
        recordType = entry.recordType
        value = entry.value
        appName = entry.appName
        achievedAt = Date(timeIntervalSince1970: entry.achievedAt)
        details = entry.details
    }

    var entry: RecordEntry {
        RecordEntry(id: nil, recordType: recordType, value: value, appName: appName,
                    achievedAt: achievedAt.timeIntervalSince1970, details: details)
    }
}

struct FleetActionRequest: Codable, Sendable {
    /// unload-model: the model name. restart-app / snooze-app: the app name.
    let target: String
    var days: Int?
}

struct FleetActionResponse: Codable, Sendable {
    let ok: Bool
    let message: String
}

struct FleetError: Codable, Sendable, Error {
    let error: String
}
