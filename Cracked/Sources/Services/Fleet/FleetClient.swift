import Foundation
import CryptoKit
import Network

/// Talks to other Macs' Cracked. Every call times out fast (2 s by default) so an
/// offline laptop never holds up the menu, the CLI or an agent's MCP call.
struct FleetClient: Sendable {
    let store: FleetStore
    let me: MachineIdentity
    var timeout: TimeInterval = 2

    enum ClientError: LocalizedError {
        case badAddress
        case unreachable(String)
        case server(Int, String)
        case decoding
        case pairing(String)

        var errorDescription: String? {
            switch self {
            case .badAddress: "That address doesn't look right."
            case .unreachable(let reason): "Couldn't reach it: \(reason)"
            case .server(_, let message): message
            case .decoding: "It answered with something Cracked didn't understand. Are both Macs on the same Cracked version?"
            case .pairing(let message): message
            }
        }
    }

    // MARK: - Unauthenticated

    func hello(address: String, port: Int) async throws -> FleetHello {
        let peer = FleetPeer(machine: me, address: address, port: port, pairedAt: Date())
        guard let base = peer.baseURL else { throw ClientError.badAddress }
        var request = URLRequest(url: base.appendingPathComponent("v1/hello"))
        request.setValue(me.id, forHTTPHeaderField: FleetAuth.machineHeader)
        return try await send(request)
    }

    /// Pairs with the Mac at `address` using the code it shows. Stores the peer and key on success.
    func pair(address: String, port: Int, code: String, myPort: Int) async throws -> FleetPeer {
        let code = code.filter(\.isNumber)
        guard code.count == 6 else { throw ClientError.pairing("The code is 6 digits.") }
        let hello = try await hello(address: address, port: port)
        guard hello.machine.id != me.id else { throw ClientError.pairing("That's this Mac.") }
        guard hello.pairingOpen else {
            throw ClientError.pairing("\(hello.machine.name) isn't showing a pairing code. Open Settings → Fleet on it and click Pair.")
        }

        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation
        let body = try JSONEncoder.fleet.encode(FleetPairRequest(
            machine: me, port: myPort, publicKey: publicKey,
            proof: FleetAuth.pairingProof(code: code, publicKey: publicKey, otherMachineID: hello.machine.id)))
        let target = FleetPeer(machine: hello.machine, address: address, port: port, pairedAt: Date())
        guard let base = target.baseURL else { throw ClientError.badAddress }
        var request = URLRequest(url: base.appendingPathComponent("v1/pair"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let response: FleetPairResponse
        do {
            response = try await send(request)
        } catch ClientError.server(401, _) {
            throw ClientError.pairing("Wrong code. After 5 wrong tries the code stops working; click Pair again on \(hello.machine.name) for a new one.")
        }
        guard response.machine.id == hello.machine.id,
              FleetAuth.verifyPairingProof(response.proof, code: code, publicKey: response.publicKey, otherMachineID: me.id) else {
            throw ClientError.pairing("\(hello.machine.name) couldn't prove it knows the code. Not pairing.")
        }
        let key = try FleetAuth.sharedKey(privateKey: privateKey, peerPublicKey: response.publicKey,
                                          machineIDs: (me.id, response.machine.id), code: code)
        let peer = FleetPeer(machine: response.machine, address: address, port: port, pairedAt: Date())
        store.upsert(peer, key: key)
        return peer
    }

    // MARK: - Signed

    func report(_ peer: FleetPeer) async throws -> SystemReport {
        try await signed(peer, "GET", "/v1/report")
    }

    func records(_ peer: FleetPeer) async throws -> [FleetRecord] {
        try await signed(peer, "GET", "/v1/records")
    }

    func history(_ peer: FleetPeer, hours: Int) async throws -> FleetHistory {
        try await signed(peer, "GET", "/v1/history?hours=\(hours)")
    }

    func stats(_ peer: FleetPeer, from start: Date, to end: Date) async throws -> PeriodStats {
        try await signed(peer, "GET", "/v1/stats?start=\(Int(start.timeIntervalSince1970))&end=\(Int(end.timeIntervalSince1970))")
    }

    func action(_ peer: FleetPeer, _ name: String, target: String, days: Int? = nil) async throws -> FleetActionResponse {
        try await signed(peer, "POST", "/v1/actions/\(name)", body: FleetActionRequest(target: target, days: days))
    }

    /// Tells the peer to forget this Mac too. Best effort.
    func unpair(_ peer: FleetPeer) async {
        let _: FleetActionResponse? = try? await signed(peer, "POST", "/v1/unpair")
    }

    private func signed<T: Decodable>(_ peer: FleetPeer, _ method: String, _ target: String) async throws -> T {
        try await signed(peer, method, target, body: Optional<FleetActionRequest>.none)
    }

    private func signed<T: Decodable, B: Encodable>(_ peer: FleetPeer, _ method: String, _ target: String,
                                                    body: B?) async throws -> T {
        guard let base = peer.baseURL, let url = URL(string: base.absoluteString + target) else { throw ClientError.badAddress }
        guard let key = store.key(for: peer.id) else { throw ClientError.pairing("Not paired with \(peer.name).") }
        let data = try body.map { try JSONEncoder.fleet.encode($0) } ?? Data()
        var request = URLRequest(url: url)
        request.httpMethod = method
        if !data.isEmpty {
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in FleetAuth.signedHeaders(machineID: me.id, key: key, method: method, path: target, body: data) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return try await send(request)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (status, data): (Int, Data)
        do {
            (status, data) = try await FleetHTTP.send(request, timeout: timeout)
        } catch {
            throw ClientError.unreachable(error.localizedDescription)
        }
        guard status == 200 else {
            let message = (try? JSONDecoder.fleet.decode(FleetError.self, from: data))?.error ?? "HTTP \(status)"
            throw ClientError.server(status, message)
        }
        guard let value = try? JSONDecoder.fleet.decode(T.self, from: data) else { throw ClientError.decoding }
        return value
    }
}

/// One plain-HTTP request over Network.framework.
///
/// Not URLSession: App Transport Security blocks plain HTTP to anything it doesn't
/// consider local, and Tailscale addresses (100.64.0.0/10) aren't. Fleet traffic is
/// authenticated by request signatures and, by default, encrypted by Tailscale.
enum FleetHTTP {
    struct HTTPError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func send(_ request: URLRequest, timeout: TimeInterval) async throws -> (Int, Data) {
        guard let url = request.url, let host = url.host, let port = url.port,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw HTTPError(message: "Bad address") }
        let target = url.path.isEmpty ? "/" : url.path + (url.query.map { "?\($0)" } ?? "")
        let body = request.httpBody ?? Data()
        var head = "\(request.httpMethod ?? "GET") \(target) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\n"
        for (name, value) in request.allHTTPHeaderFields ?? [:] { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)

        let exchange = Exchange(connection: NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp),
                                payload: payload)
        let raw: Data = try await withCheckedThrowingContinuation { continuation in
            exchange.run(timeout: timeout * 2) { continuation.resume(with: $0) }
        }
        return try parseResponse(raw)
    }

    /// One connection: send the request, read until the server closes, finish exactly once.
    private final class Exchange: @unchecked Sendable {
        private let connection: NWConnection
        private let payload: Data
        private let queue = DispatchQueue(label: "cracked.fleet.client")
        private var buffer = Data()
        private var completion: ((Result<Data, Error>) -> Void)?

        init(connection: NWConnection, payload: Data) {
            self.connection = connection
            self.payload = payload
        }

        func run(timeout: TimeInterval, completion: @escaping (Result<Data, Error>) -> Void) {
            queue.async { [self] in
                self.completion = completion
                queue.asyncAfter(deadline: .now() + timeout) { [self] in finish(.failure(HTTPError(message: "Timed out"))) }
                connection.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready:
                        connection.send(content: payload, completion: .contentProcessed { [self] error in
                            if let error { finish(.failure(error)) }
                        })
                        receive()
                    case .failed(let error), .waiting(let error):
                        // .waiting means no route (peer asleep or off Tailscale): fail fast.
                        finish(.failure(error))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, isComplete, error in
                if let data { buffer.append(data) }
                if isComplete || error != nil {
                    if buffer.isEmpty, let error { finish(.failure(error)) } else { finish(.success(buffer)) }
                } else if buffer.count > HTTPRequest.maxSize * 8 {
                    finish(.failure(HTTPError(message: "Response too large")))
                } else {
                    receive()
                }
            }
        }

        /// Always called on `queue`.
        private func finish(_ result: Result<Data, Error>) {
            guard let completion else { return }
            self.completion = nil
            connection.cancel()
            completion(result)
        }
    }

    static func parseResponse(_ raw: Data) throws -> (Int, Data) {
        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: raw[raw.startIndex..<headerEnd.lowerBound], encoding: .utf8),
              let statusLine = head.components(separatedBy: "\r\n").first else {
            throw HTTPError(message: "Not an HTTP response. Is something else using that port?")
        }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]) else {
            throw HTTPError(message: "Not an HTTP response")
        }
        var body = Data(raw[headerEnd.upperBound...])
        let length = head.components(separatedBy: "\r\n").dropFirst().compactMap { line -> Int? in
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { return nil }
            return Int(pair[1].trimmingCharacters(in: .whitespaces))
        }.first
        if let length, body.count > length { body = body.prefix(length) }
        return (status, body)
    }
}

/// Runs async work from synchronous code (the CLI and the MCP server's stdio loop).
private final class AwaitBox<T>: @unchecked Sendable { var value: T? }

func blockingAwait<T: Sendable>(timeout: TimeInterval, _ work: @escaping @Sendable () async -> T) -> T? {
    let box = AwaitBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        box.value = await work()
        done.signal()
    }
    guard done.wait(timeout: .now() + timeout) == .success else { return nil }
    return box.value
}

// MARK: - Tailscale discovery

/// Macs on your tailnet, from `tailscale status --json`.
enum TailscalePeers {
    struct Candidate: Identifiable, Equatable, Sendable {
        let hostName: String
        let dnsName: String?
        let address: String
        let online: Bool
        var id: String { address }
    }

    static let cliPaths = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    static var cliPath: String? {
        cliPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Online macOS peers (not this Mac). Empty when Tailscale isn't installed or running.
    static func discover() -> [Candidate] {
        guard let path = cliPath else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["status", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        // Never hang on a Tailscale that doesn't answer.
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return parse(data)
    }

    static func parse(_ data: Data) -> [Candidate] {
        struct Status: Decodable {
            struct Node: Decodable {
                let HostName: String?
                let DNSName: String?
                let OS: String?
                let Online: Bool?
                let TailscaleIPs: [String]?
            }
            let Peer: [String: Node]?
        }
        guard let status = try? JSONDecoder().decode(Status.self, from: data) else { return [] }
        return (status.Peer ?? [:]).values.compactMap { node in
            guard node.OS?.lowercased() == "macos",
                  let ip = node.TailscaleIPs?.first(where: { $0.contains(".") }) ?? node.TailscaleIPs?.first else { return nil }
            let dns = node.DNSName.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
            return Candidate(hostName: node.HostName ?? dns ?? ip, dnsName: dns, address: ip, online: node.Online ?? false)
        }
        .sorted { ($0.online ? 0 : 1, $0.hostName.lowercased()) < ($1.online ? 0 : 1, $1.hostName.lowercased()) }
    }
}
