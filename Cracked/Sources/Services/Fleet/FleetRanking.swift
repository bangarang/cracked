import Foundation

/// A Mac in the fleet, as seen from this one.
struct FleetMember: Sendable {
    let report: SystemReport
    /// How to reach it (Tailscale IP or name); nil for this Mac.
    let address: String?
    let isThisMac: Bool

    var name: String { report.machine?.name ?? (isThisMac ? "This Mac" : address ?? "Unknown Mac") }

    /// This Mac plus paired Macs seen in the last 3 minutes, from the app's cache.
    static func current(thisMac: SystemReport, cache: FleetCache? = FleetCache.load(),
                        enabled: Bool = FleetStore.shared.isEnabled, now: Date = Date()) -> [FleetMember] {
        var members = [FleetMember(report: thisMac, address: nil, isThisMac: true)]
        guard enabled, let cache else { return members }
        for entry in cache.entries {
            guard let report = entry.report, let seen = entry.lastSeen, now.timeIntervalSince(seen) < 180 else { continue }
            members.append(FleetMember(report: report, address: entry.peer.address, isThisMac: false))
        }
        return members
    }
}

/// Which Mac has the most headroom for heavy work.
enum FleetRanking {
    /// Lower is better: load per core, plus penalties for memory pressure and a full RAM.
    static func busyness(_ report: SystemReport) -> Double {
        let pressure: Double = switch report.memoryPressure {
        case .normal: 0
        case .warning: 0.5
        case .critical: 2
        }
        let memory = report.memoryTotalGB > 0 ? report.memoryUsedGB / report.memoryTotalGB : 0
        return report.loadPerCore + pressure + memory * 0.5
    }

    static func ranked(_ members: [FleetMember]) -> [FleetMember] {
        members.sorted { busyness($0.report) < busyness($1.report) }
    }

    /// Idle enough to take a build: under half its cores busy and no memory pressure.
    static func isIdle(_ report: SystemReport) -> Bool {
        report.loadPerCore < 0.5 && report.memoryPressure == .normal
    }

    /// "Mac mini (M4 Pro, 12 cores): load 1.2 (0.10/core) · RAM 20/48 GB · 2 agents working"
    static func line(_ member: FleetMember) -> String {
        let r = member.report
        var parts = [String(format: "load %.1f (%.2f/core)", r.loadAverage, r.loadPerCore),
                     String(format: "RAM %.0f/%.0f GB", r.memoryUsedGB, r.memoryTotalGB)]
        if r.memoryPressure != .normal { parts.append("memory pressure \(r.memoryPressure.rawValue)") }
        let working = r.agents.filter { $0.status == "working" }.count
        if working > 0 { parts.append("\(working) agent\(working == 1 ? "" : "s") working") }
        if !r.localModels.isEmpty { parts.append(String(format: "%.0f GB of local models", r.localModelsGB)) }
        let hardware = r.machine.map { "\($0.chipClass), \($0.cpuCores) cores" } ?? "\(r.cpuCores) cores"
        let label = member.isThisMac ? "\(member.name) (this Mac)" : member.name
        return "\(label) [\(hardware)]: " + parts.joined(separator: " · ")
    }

    /// Text for the least_loaded_machine tool.
    static func recommendation(_ members: [FleetMember]) -> String {
        let ranked = ranked(members)
        guard let best = ranked.first else { return "No Macs to compare." }
        guard members.count > 1 else {
            return "Only this Mac is in the fleet (pair others in Cracked Settings → Fleet).\n" + line(best)
        }
        var lines = ["Least loaded: \(best.name)\(best.isThisMac ? " (this Mac)" : "")" +
                     (best.address.map { " at \($0)" } ?? "")]
        if !best.isThisMac, let here = members.first(where: \.isThisMac), isIdle(best.report), !isIdle(here.report) {
            lines.append("This Mac is busier; consider running heavy builds or tests on \(best.name).")
        }
        lines.append("")
        lines.append("All Macs, least loaded first:")
        lines += ranked.enumerated().map { "\($0.offset + 1). " + line($0.element) }
        return lines.joined(separator: "\n")
    }

    /// Added to the load warning a new session gets: "the Mac mini is idle (load 1.2 on 12)".
    static func idlePeerHint(_ members: [FleetMember]) -> String? {
        guard let idle = ranked(members.filter { !$0.isThisMac }).first(where: { isIdle($0.report) }) else { return nil }
        return String(format: "%@ is idle (load %.1f on %d cores)", idle.name, idle.report.loadAverage, idle.report.cpuCores)
    }
}
