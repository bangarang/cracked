import Foundation
import CryptoKit

/// A parsed HTTP/1.1 request (just what the fleet API needs).
struct HTTPRequest: Sendable, Equatable {
    var method: String
    /// Path and query exactly as sent, which is what gets signed.
    var target: String
    var headers: [String: String]
    var body: Data

    var path: String { String(target.split(separator: "?", maxSplits: 1).first ?? "") }

    var query: [String: String] {
        guard let components = URLComponents(string: "http://x" + target) else { return [:] }
        return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    enum ParseResult: Equatable {
        case incomplete
        case invalid
        case complete(HTTPRequest)
    }

    static let maxSize = 1 << 20

    /// Parses a buffered request; `.incomplete` until headers and the whole body have arrived.
    static func parse(_ data: Data) -> ParseResult {
        guard data.count <= maxSize else { return .invalid }
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."), requestLine[1].hasPrefix("/") else {
            return .invalid
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).trimmingCharacters(in: .whitespaces)] =
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let length = headers.first { $0.key.lowercased() == "content-length" }.flatMap { Int($0.value) } ?? 0
        guard length >= 0, length <= maxSize else { return .invalid }
        let bodyStart = headerEnd.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        return .complete(HTTPRequest(method: String(requestLine[0]), target: String(requestLine[1]),
                                     headers: headers, body: Data(data[bodyStart..<(bodyStart + length)])))
    }
}

struct HTTPResponse: Sendable, Equatable {
    var status: Int
    var body: Data
    var contentType = "application/json"

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONEncoder.fleet.encode(value)) ?? Data("{}".utf8))
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(FleetError(error: message), status: status)
    }

    var serialized: Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                      409: "Conflict", 429: "Too Many Requests", 500: "Internal Server Error"][status] ?? "Status"
        var data = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        data.append(body)
        return data
    }
}

/// The code this Mac shows while it's waiting to be paired.
final class PairingSession: @unchecked Sendable {
    static let lifetime: TimeInterval = 600
    static let maxAttempts = 5

    private let lock = NSLock()
    private var code: String?
    private var expiresAt = Date.distantPast
    private var attempts = 0

    /// Opens pairing with a fresh code; returns it.
    @discardableResult
    func open(now: Date = Date(), code fixed: String? = nil) -> String {
        lock.withLock {
            let new = fixed ?? FleetAuth.newPairingCode()
            code = new
            expiresAt = now.addingTimeInterval(Self.lifetime)
            attempts = 0
            return new
        }
    }

    func close() {
        lock.withLock { code = nil }
    }

    /// The code, while pairing is open and not locked out.
    func currentCode(now: Date = Date()) -> String? {
        lock.withLock { code != nil && now < expiresAt && attempts < Self.maxAttempts ? code : nil }
    }

    var expiry: Date { lock.withLock { expiresAt } }

    /// Counts a wrong guess; after 5 the code stops working.
    func recordFailure() {
        lock.withLock {
            attempts += 1
            if attempts >= Self.maxAttempts { code = nil }
        }
    }
}

/// Answers fleet API requests. Pure logic over injected closures, so it's testable
/// without sockets; `FleetServer` feeds it requests from the network.
struct FleetRouter: Sendable {
    struct Environment: Sendable {
        var machine: @Sendable () -> MachineIdentity
        var report: @Sendable () -> SystemReport?
        var records: @Sendable () -> [RecordEntry]
        var history: @Sendable (_ hours: Int) -> [SnapshotRecord]
        var periodStats: @Sendable (_ start: Date, _ end: Date) -> PeriodStats?
        var unloadModel: @Sendable (_ name: String) async -> Bool
        var restartApp: @Sendable (_ pid: Int32, _ bundlePath: String) -> Bool
        var snoozeApp: @Sendable (_ bundlePath: String, _ until: Date) -> Void
        /// Called on the main actor after a Mac pairs with this one, or unpairs.
        var peersChanged: @Sendable () -> Void = {}
        var now: @Sendable () -> Date = { Date() }
    }

    let environment: Environment
    let store: FleetStore
    let pairing: PairingSession

    func handle(_ request: HTTPRequest, remoteAddress: String) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/v1/hello"):
            return hello(request)
        case ("POST", "/v1/pair"):
            return pair(request, remoteAddress: remoteAddress)
        default:
            break
        }

        // Everything else needs a paired, signed request.
        let verified = FleetAuth.verify(method: request.method, path: request.target, headers: request.headers,
                                        body: request.body, now: environment.now(), keyFor: store.key(for:))
        guard case .ok(let machineID) = verified, let peer = store.peer(id: machineID) else {
            if case .unauthorized(let reason) = verified { return .error(401, reason) }
            return .error(401, "Not paired")
        }
        // Follow a peer whose address changed (new Tailscale IP or network).
        if peer.address != remoteAddress, FleetAuth.isAllowed(address: remoteAddress, scope: .tailscaleOnly) {
            store.update(peer.id) { $0.address = remoteAddress }
        }

        switch (request.method, request.path) {
        case ("GET", "/v1/report"):
            guard let report = environment.report() else { return .error(500, "No reading yet") }
            return .json(report)
        case ("GET", "/v1/records"):
            return .json(environment.records().map(FleetRecord.init))
        case ("GET", "/v1/history"):
            let hours = min(max(Int(request.query["hours"] ?? "") ?? 24, 1), 24 * 30)
            let points = environment.history(hours).map {
                FleetHistory.Point(date: Date(timeIntervalSince1970: $0.timestamp), loadAverage: $0.loadAvg,
                                   memoryUsedGB: Double($0.memoryUsedMB) / 1024)
            }
            return .json(FleetHistory(points: points))
        case ("GET", "/v1/stats"):
            guard let start = request.query["start"].flatMap(Double.init),
                  let end = request.query["end"].flatMap(Double.init), end > start else {
                return .error(400, "start and end (unix seconds) are required")
            }
            guard let stats = environment.periodStats(Date(timeIntervalSince1970: start), Date(timeIntervalSince1970: end)) else {
                return .error(500, "No data")
            }
            return .json(stats)
        case ("POST", "/v1/unpair"):
            store.remove(peer.id)
            environment.peersChanged()
            return .json(FleetActionResponse(ok: true, message: "Unpaired"))
        case ("POST", let path) where path.hasPrefix("/v1/actions/"):
            return await action(String(path.dropFirst("/v1/actions/".count)), request: request, peer: peer)
        default:
            return .error(404, "Unknown endpoint \(request.method) \(request.path)")
        }
    }

    // MARK: - Hello & pairing

    private func hello(_ request: HTTPRequest) -> HTTPResponse {
        let caller = request.header(FleetAuth.machineHeader)
        return .json(FleetHello(
            machine: environment.machine(),
            schemaVersion: SystemReport.currentSchemaVersion,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            paired: caller.map { store.key(for: $0) != nil } ?? false,
            pairingOpen: pairing.currentCode(now: environment.now()) != nil))
    }

    private func pair(_ request: HTTPRequest, remoteAddress: String) -> HTTPResponse {
        guard let code = pairing.currentCode(now: environment.now()) else {
            return .error(409, "This Mac isn't showing a pairing code. Open Cracked Settings → Fleet → Pair on it first.")
        }
        guard let body = try? JSONDecoder.fleet.decode(FleetPairRequest.self, from: request.body) else {
            return .error(400, "Bad pairing request")
        }
        let me = environment.machine()
        guard body.machine.id != me.id else { return .error(400, "That's this Mac") }
        guard FleetAuth.verifyPairingProof(body.proof, code: code, publicKey: body.publicKey, otherMachineID: me.id) else {
            pairing.recordFailure()
            return .error(401, "Wrong code")
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let myPublic = privateKey.publicKey.rawRepresentation
        guard let key = try? FleetAuth.sharedKey(privateKey: privateKey, peerPublicKey: body.publicKey,
                                                 machineIDs: (me.id, body.machine.id), code: code) else {
            return .error(400, "Bad public key")
        }
        pairing.close()
        store.upsert(FleetPeer(machine: body.machine, address: remoteAddress, port: body.port,
                               pairedAt: environment.now()), key: key)
        environment.peersChanged()
        return .json(FleetPairResponse(
            machine: me, publicKey: myPublic,
            proof: FleetAuth.pairingProof(code: code, publicKey: myPublic, otherMachineID: body.machine.id)))
    }

    // MARK: - Actions

    private func action(_ name: String, request: HTTPRequest, peer: FleetPeer) async -> HTTPResponse {
        guard let body = try? JSONDecoder.fleet.decode(FleetActionRequest.self, from: request.body) else {
            return .error(400, "Bad action request")
        }
        let here = environment.machine().name
        switch name {
        case "unload-model":
            guard peer.allowUnloadModels else {
                return .error(403, "\(here) doesn't let \(peer.name) unload models. Allow it in Cracked Settings → Fleet on \(here).")
            }
            guard environment.report()?.localModels.contains(where: { $0.name == body.target }) == true else {
                return .error(404, "\(body.target) isn't loaded on \(here)")
            }
            let ok = await environment.unloadModel(body.target)
            return .json(FleetActionResponse(ok: ok, message: ok ? "Unloaded \(body.target) on \(here)" : "Ollama didn't unload \(body.target)"))
        case "restart-app", "snooze-app":
            guard peer.allowRestartApps else {
                return .error(403, "\(here) doesn't let \(peer.name) restart or snooze apps. Allow it in Cracked Settings → Fleet on \(here).")
            }
            // Same rule as the MCP server: only apps already on the Worth a Restart list.
            let candidates = environment.report()?.worthARestart ?? []
            guard let app = candidates.first(where: { $0.name.caseInsensitiveCompare(body.target) == .orderedSame }) else {
                return .error(404, "\(body.target) isn't on \(here)'s Worth a Restart list")
            }
            if name == "restart-app" {
                let ok = environment.restartApp(app.pid, app.bundlePath)
                return .json(FleetActionResponse(ok: ok, message: ok ? "Restarted \(app.name) on \(here)" : "Couldn't relaunch \(app.name)"))
            }
            let days = max(body.days ?? 7, 1)
            environment.snoozeApp(app.bundlePath, environment.now().addingTimeInterval(Double(days) * 86400))
            return .json(FleetActionResponse(ok: true, message: "Snoozed \(app.name) on \(here) for \(days) days"))
        default:
            return .error(404, "Unknown action \(name)")
        }
    }
}
