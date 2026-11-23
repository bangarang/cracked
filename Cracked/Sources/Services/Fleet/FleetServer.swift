import Foundation
import Network

/// Serves the fleet API to paired Macs: one HTTP request per connection, JSON responses.
/// Connections from outside Tailscale (and the LAN, if allowed) are dropped unread.
final class FleetServer: @unchecked Sendable {
    private let router: FleetRouter
    private let scope: @Sendable () -> FleetAuth.NetworkScope
    private let queue = DispatchQueue(label: "cracked.fleet.server")
    private var listener: NWListener?
    private(set) var port: Int
    private var stopped = true
    private var retryDelay: TimeInterval = 1
    /// Whether the listener is accepting connections right now.
    private(set) var isReady = false

    /// Set when the listener fails (e.g. the port is taken), for Settings to show.
    var onStateChange: (@Sendable (String?) -> Void)?

    init(router: FleetRouter, port: Int, scope: @escaping @Sendable () -> FleetAuth.NetworkScope) {
        self.router = router
        self.port = port
        self.scope = scope
    }

    /// Starts listening, and keeps listening: if the listener fails (port briefly taken
    /// after a restart, network change, sleep and wake), it's recreated with backoff.
    func start() throws {
        guard NWEndpoint.Port(rawValue: UInt16(port)) != nil else { throw FleetError(error: "Bad port \(port)") }
        queue.sync {
            stopped = false
            retryDelay = 1
            makeListener()
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            isReady = false
            listener?.cancel()
            listener = nil
        }
    }

    /// Drops the current listener and makes a new one (after waking from sleep).
    func restart() {
        queue.async { [self] in
            guard !stopped else { return }
            listener?.cancel()
            listener = nil
            isReady = false
            retryDelay = 1
            scheduleRetry()
        }
    }

    private func makeListener() {
        guard !stopped, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters, on: nwPort) else {
            onStateChange?("Couldn't listen on port \(port). Retrying…")
            scheduleRetry()
            return
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, listener === self.listener else { return }
            switch state {
            case .ready:
                self.isReady = true
                self.retryDelay = 1
                self.onStateChange?(nil)
            case .failed(let error):
                self.isReady = false
                self.onStateChange?("Port \(self.port) unavailable (\(error.localizedDescription)). Retrying…")
                listener.cancel()
                self.listener = nil
                self.scheduleRetry()
            case .cancelled:
                self.isReady = false
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func scheduleRetry() {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, self.listener == nil else { return }
            self.makeListener()
        }
    }

    static func address(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }

    private func accept(_ connection: NWConnection) {
        guard let address = Self.address(of: connection.endpoint),
              FleetAuth.isAllowed(address: address, scope: scope()) else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        // Drop connections that never finish sending a request.
        queue.asyncAfter(deadline: .now() + 15) { [weak connection] in connection?.cancel() }
        receive(on: connection, buffer: Data(), from: address)
    }

    private func receive(on connection: NWConnection, buffer: Data, from address: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .complete(let request):
                let router = self.router
                Task {
                    let response = await router.handle(request, remoteAddress: address)
                    connection.send(content: response.serialized, completion: .contentProcessed { _ in connection.cancel() })
                }
            case .invalid:
                connection.send(content: HTTPResponse.error(400, "Bad request").serialized,
                                completion: .contentProcessed { _ in connection.cancel() })
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer, from: address)
                }
            }
        }
    }
}
