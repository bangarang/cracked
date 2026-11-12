import Foundation
import Testing
@testable import Cracked

/// Trimmed from a real `GET /api/ps` on a 48 GB Mac.
private let psResponse = """
    {"models":[
      {"name":"qwen3-embedding:0.6b","model":"qwen3-embedding:0.6b","size":4763083079,"digest":"ac6d",
       "details":{"format":"gguf","family":"qwen3","parameter_size":"595.78M","quantization_level":"Q8_0"},
       "expires_at":"2026-11-10T17:20:33.277813-07:00","size_vram":4763083079,"context_length":32768,"runner":"llamacpp"},
      {"name":"gemma4:26b","model":"gemma4:26b","size":23951063244,"digest":"48eb",
       "details":{"format":"safetensors"},
       "expires_at":"2026-11-10T17:34:15.865035123-07:00","size_vram":23951063244,"context_length":32768,"runner":"mlx"},
      {"name":"forever:7b","model":"forever:7b","size":1073741824,"expires_at":"2318-02-18T17:20:33.277813-07:00"}
    ]}
    """

@Suite("Local models")
struct LocalModelsTests {
    @Test("Parses Ollama's /api/ps, biggest model first")
    func parses() throws {
        let models = try #require(Ollama.parsePS(Data(psResponse.utf8)))
        #expect(models.map(\.name) == ["gemma4:26b", "qwen3-embedding:0.6b", "forever:7b"])
        let gemma = models[0]
        #expect(abs(gemma.sizeGB - 22.3) < 0.05)
        #expect(gemma.runner == "mlx")
        #expect(gemma.contextLength == 32768)
        let expected = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-11-11T00:34:15.865Z")
        #expect(abs(try #require(gemma.expiresAt).timeIntervalSince(expected)) < 0.01, "Nanoseconds and UTC offsets parse")
        #expect(Ollama.parsePS(Data(#"{"models":[]}"#.utf8)) == [])
        #expect(Ollama.parsePS(Data("not json".utf8)) == nil)
    }

    @Test("Shows when a model will unload")
    func unloadText() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        #expect(LocalModelRowView.unloadText(expiresAt: now + 12 * 60, now: now) == "unloads in 12m")
        #expect(LocalModelRowView.unloadText(expiresAt: now + 20, now: now) == "unloads in <1m")
        #expect(LocalModelRowView.unloadText(expiresAt: now + 300 * 365 * 86400, now: now) == "stays loaded")
        #expect(LocalModelRowView.unloadText(expiresAt: now - 5, now: now) == "unloading")
        #expect(LocalModelRowView.unloadText(expiresAt: nil, now: now) == "loaded")
    }

    @Test("Finds the Ollama server the way Ollama does, from OLLAMA_HOST")
    func baseURL() {
        #expect(Ollama.baseURL(environment: [:]).absoluteString == "http://127.0.0.1:11434")
        #expect(Ollama.baseURL(environment: ["OLLAMA_HOST": "0.0.0.0"]).absoluteString == "http://127.0.0.1:11434")
        #expect(Ollama.baseURL(environment: ["OLLAMA_HOST": "127.0.0.1:8080"]).absoluteString == "http://127.0.0.1:8080")
        #expect(Ollama.baseURL(environment: ["OLLAMA_HOST": "https://ollama.local"]).absoluteString == "https://ollama.local:11434")
    }

    @Test("Unloading asks Ollama to drop the model now, like `ollama stop`")
    func unloadRequest() throws {
        let request = Ollama.unloadRequest(model: "gemma4:26b", baseURL: URL(string: "http://127.0.0.1:11434")!)
        #expect(request.url?.absoluteString == "http://127.0.0.1:11434/api/generate")
        #expect(request.httpMethod == "POST")
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "gemma4:26b")
        #expect(body["keep_alive"] as? Int == 0)
        #expect(body["prompt"] == nil, "No prompt, so nothing is generated")
    }

    @Test("Only polls when an Ollama server is running")
    func running() {
        func proc(_ name: String) -> ProcessSnapshot {
            ProcessSnapshot(id: 1, pid: 1, ppid: 1, uid: 501, name: name, cpuPercent: 0, memoryMB: 1, uptimeSeconds: 1)
        }
        #expect(Ollama.isRunning(processes: [proc("/Applications/Ollama.app/Contents/Resources/ollama")]))
        #expect(Ollama.isRunning(processes: [proc("/opt/homebrew/bin/ollama")]))
        #expect(!Ollama.isRunning(processes: [proc("/opt/homebrew/bin/opencode"), proc("ollama-helper")]))
    }

    @Test("macOS memory pressure raises the pressure level")
    func memoryPressure() {
        #expect(MemoryPressure.from(level: 1) == .normal)
        #expect(MemoryPressure.from(level: 2) == .warning)
        #expect(MemoryPressure.from(level: 4) == .critical)
        #expect(PressureLevel.from(cpuHogs: [], loadAverage: 2, memoryPressure: .normal) == .normal)
        #expect(PressureLevel.from(cpuHogs: [], loadAverage: 2, memoryPressure: .warning) == .warning)
        #expect(PressureLevel.from(cpuHogs: [], loadAverage: 2, memoryPressure: .critical) == .critical)
    }

    @Test("Loaded models show up in status and in the warning new sessions get")
    func report() throws {
        let models = try #require(Ollama.parsePS(Data(psResponse.utf8))).prefix(2)
        let snapshot = SystemSnapshot(timestamp: Date(), loadAverage: 2, totalProcesses: 500,
                                      memoryUsedMB: 44 * 1024, memoryTotalMB: 48 * 1024, processes: [])
        func build(_ pressure: MemoryPressure) -> SystemReport {
            SystemReport.build(snapshot: snapshot, settings: CrackedSettings(), launchedAppPIDs: [],
                               ignoredBundlePaths: [], agents: [], cpuCores: 12,
                               memoryPressure: pressure, localModels: Array(models))
        }
        let calm = build(.normal)
        #expect(calm.localModelsSummary == "gemma4:26b 22.3 GB, qwen3-embedding:0.6b 4.4 GB (26.7 GB, 56% of RAM)")
        #expect(calm.summary.contains("Local models: gemma4:26b 22.3 GB"))
        #expect(calm.json.contains(#""local_models""#))

        let strained = build(.warning)
        #expect(strained.pressure == .warning)
        let brief = try #require(strained.agentBrief)
        #expect(brief.contains("memory pressure warning"))
        #expect(brief.contains("Ollama models loaded: gemma4:26b 22.3 GB"))
        #expect(brief.hasSuffix("or loading more local models."))
    }
}
