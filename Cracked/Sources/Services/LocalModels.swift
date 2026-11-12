import Foundation
import Darwin

/// A model Ollama currently has loaded in memory.
struct LocalModel: Codable, Identifiable, Equatable, Sendable {
    let name: String
    /// Total memory the loaded model takes, including its context (KV cache).
    let sizeBytes: Int64
    /// How much of that is GPU memory. On Apple Silicon that's still unified RAM,
    /// wired so macOS can't page it out, and process stats largely miss it.
    let vramBytes: Int64
    let contextLength: Int?
    /// When Ollama will unload it if it isn't used again.
    let expiresAt: Date?
    /// "llamacpp", "mlx"…
    let runner: String?

    var id: String { name }
    var sizeGB: Double { Double(sizeBytes) / 1_073_741_824 }
}

/// macOS's own memory pressure, the signal that the Mac is about to swap hard.
enum MemoryPressure: String, Codable, Sendable {
    case normal, warning, critical

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    static func from(level: Int32) -> MemoryPressure {
        switch level {
        case 4...: .critical
        case 2...: .warning
        default: .normal
        }
    }

    static func current() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return from(level: level)
    }
}

/// Reads and unloads Ollama's loaded models through its local API (`/api/ps`).
/// Only ever talks to the Ollama server on this Mac.
enum Ollama {
    /// `$OLLAMA_HOST` if set (as Ollama itself reads it), else http://127.0.0.1:11434.
    static func baseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let fallback = URL(string: "http://127.0.0.1:11434")!
        guard var host = environment["OLLAMA_HOST"]?.trimmingCharacters(in: .whitespaces), !host.isEmpty else {
            return fallback
        }
        if !host.contains("://") { host = "http://" + host }
        guard var components = URLComponents(string: host), components.host != nil else { return fallback }
        // Ollama listens on all interfaces for 0.0.0.0, but that isn't an address to connect to.
        if components.host == "0.0.0.0" { components.host = "127.0.0.1" }
        if components.port == nil { components.port = 11434 }
        return components.url ?? fallback
    }

    /// Whether an Ollama server is running, so Cracked doesn't poll a port nobody listens on.
    static func isRunning(processes: [ProcessSnapshot]) -> Bool {
        processes.contains { p in
            let name = (p.name as NSString).lastPathComponent
            return name == "ollama" || name == "Ollama"
        }
    }

    static func parsePS(_ data: Data) -> [LocalModel]? {
        struct Response: Decodable {
            struct Model: Decodable {
                let name: String?
                let model: String?
                let size: Int64?
                let size_vram: Int64?
                let context_length: Int?
                let expires_at: String?
                let runner: String?
            }
            let models: [Model]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return (response.models ?? []).compactMap { m in
            guard let name = m.name ?? m.model else { return nil }
            return LocalModel(
                name: name, sizeBytes: m.size ?? 0, vramBytes: m.size_vram ?? 0,
                contextLength: m.context_length, expiresAt: m.expires_at.flatMap(parseDate), runner: m.runner
            )
        }
        .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Ollama writes Go timestamps: fractional seconds (up to nanoseconds) and a UTC offset.
    static func parseDate(_ string: String) -> Date? {
        var trimmed = string
        // Keep at most milliseconds, which ISO8601FormatStyle understands.
        if let dot = trimmed.firstIndex(of: "."),
           let zone = trimmed[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let fraction = trimmed[trimmed.index(after: dot)..<zone]
            trimmed = String(trimmed[..<dot]) + "." + fraction.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0)
                + trimmed[zone...]
        }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(trimmed))
            ?? (try? Date.ISO8601FormatStyle().parse(trimmed))
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 5
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    /// Loaded models, or nil when Ollama isn't reachable.
    static func loadedModels(baseURL: URL = baseURL()) async -> [LocalModel]? {
        guard let (data, response) = try? await session.data(from: baseURL.appendingPathComponent("api/ps")),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parsePS(data)
    }

    /// Blocking version for the CLI and the hook, which aren't async.
    static func loadedModelsSync(baseURL: URL = baseURL(), timeout: TimeInterval = 1.5) -> [LocalModel]? {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.models = await loadedModels(baseURL: baseURL)
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.models
    }

    private final class ResultBox: @unchecked Sendable {
        var models: [LocalModel]?
    }

    /// The request that tells Ollama to drop a model from memory now (what `ollama stop` sends).
    static func unloadRequest(model: String, endpoint: String = "api/generate", baseURL: URL = baseURL()) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": 0])
        return request
    }

    /// Unloads a model. Embedding-only models can refuse /api/generate, so /api/embed is tried next.
    @discardableResult
    static func unload(model: String, baseURL: URL = baseURL()) async -> Bool {
        for endpoint in ["api/generate", "api/embed"] {
            let request = unloadRequest(model: model, endpoint: endpoint, baseURL: baseURL)
            if let (_, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return true
            }
        }
        return false
    }
}
