import Foundation

@MainActor
final class ProcessMonitor: ObservableObject {
    @Published var latestSnapshot: SystemSnapshot?

    private var timer: Timer?
    private let pollInterval: TimeInterval

    init(pollInterval: TimeInterval = 5.0) {
        self.pollInterval = pollInterval
    }

    func start() {
        pollAsync()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollAsync()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func pollAsync() {
        let queue = DispatchQueue.global(qos: .utility)
        queue.async { [weak self] in
            let processes = ProcessMonitor.fetchProcesses()
            let loadAvg = ProcessMonitor.fetchLoadAverage()
            let (usedMB, totalMB) = ProcessMonitor.fetchMemory()

            let snapshot = SystemSnapshot(
                timestamp: Date(),
                loadAverage: loadAvg,
                totalProcesses: processes.count,
                memoryUsedMB: usedMB,
                memoryTotalMB: totalMB,
                processes: processes
            )

            DispatchQueue.main.async {
                self?.latestSnapshot = snapshot
            }
        }
    }

    // MARK: - Process list

    nonisolated static func fetchProcesses() -> [ProcessSnapshot] {
        let output = shell("ps", "-axo", "uid,pid,pcpu,rss,etime,comm")
        return parsePsOutput(output)
    }

    nonisolated static func parsePsOutput(_ output: String) -> [ProcessSnapshot] {
        var results: [ProcessSnapshot] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("UID") { continue }

            // Split into at most 6 components: uid, pid, cpu, rss, etime, comm (may contain spaces)
            let parts = trimmed.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard parts.count >= 6 else { continue }

            guard let uid = Int(parts[0]),
                  let pid = Int32(parts[1]),
                  let cpu = Double(parts[2]),
                  let rssKB = Int(parts[3]) else { continue }

            let etime = String(parts[4])
            let comm = String(parts[5])
            let uptimeSeconds = parseEtime(etime)
            let memoryMB = rssKB / 1024

            results.append(ProcessSnapshot(
                id: pid,
                pid: pid,
                uid: uid,
                name: comm,
                cpuPercent: cpu,
                memoryMB: memoryMB,
                uptimeSeconds: uptimeSeconds
            ))
        }
        return results
    }

    // MARK: - Elapsed time parsing

    /// Parses ps etime format: [[dd-]HH:]MM:SS
    nonisolated static func parseEtime(_ etime: String) -> Int {
        var days = 0
        var remainder = etime

        // Check for dd- prefix
        if let dashIndex = remainder.firstIndex(of: "-") {
            days = Int(remainder[remainder.startIndex..<dashIndex]) ?? 0
            remainder = String(remainder[remainder.index(after: dashIndex)...])
        }

        let components = remainder.split(separator: ":").compactMap { Int($0) }

        switch components.count {
        case 3: // HH:MM:SS
            return days * 86400 + components[0] * 3600 + components[1] * 60 + components[2]
        case 2: // MM:SS
            return days * 86400 + components[0] * 60 + components[1]
        case 1: // SS
            return days * 86400 + components[0]
        default:
            return 0
        }
    }

    // MARK: - Load average

    nonisolated static func fetchLoadAverage() -> Double {
        let output = shell("sysctl", "-n", "vm.loadavg")
        return parseLoadAverage(output)
    }

    nonisolated static func parseLoadAverage(_ output: String) -> Double {
        // Format: "{ 1.23 2.34 3.45 }"
        let cleaned = output.replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .trimmingCharacters(in: .whitespaces)
        let parts = cleaned.split(separator: " ")
        return Double(parts.first ?? "0") ?? 0
    }

    // MARK: - Memory

    nonisolated static func fetchMemory() -> (usedMB: Int, totalMB: Int) {
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let totalMB = Int(totalBytes / 1_048_576)

        // Parse vm_stat for pages free/inactive/speculative
        let output = shell("vm_stat")
        let pageSize = 16384 // macOS Apple Silicon default
        var pagesUsed = 0

        for line in output.components(separatedBy: "\n") {
            if line.contains("Pages active") || line.contains("Pages wired") || line.contains("Pages occupied by compressor") {
                let parts = line.components(separatedBy: ":")
                if let valueStr = parts.last?.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "."))),
                   let value = Int(valueStr) {
                    pagesUsed += value
                }
            }
        }
        let usedMB = (pagesUsed * pageSize) / 1_048_576
        return (usedMB, totalMB)
    }

    // MARK: - Shell helper

    nonisolated private static func shell(_ args: String...) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        // Read pipe BEFORE waitUntilExit to avoid deadlock when output exceeds pipe buffer
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
