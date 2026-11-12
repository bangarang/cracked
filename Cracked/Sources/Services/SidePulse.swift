import Foundation
import AppKit
import Darwin

/// A SidePulse LED device (sidepulse.io) mounted as a drive: SidePulse Pro (SD card,
/// eight LEDs) or SidePulse Dot (USB-C, two LEDs, with its USB storage turned on).
/// Both show whatever LED program is written to `LEDS.LED`.
struct SidePulseDevice: Equatable, Sendable, Identifiable {
    enum Model: String, Sendable {
        case pro = "SidePulse Pro"
        case dot = "SidePulse Dot"
    }

    let model: Model
    let serial: String
    let version: String?
    let root: URL

    var id: String { root.path }
    var ledCount: Int { model == .pro ? 8 : 2 }
    var programURL: URL { root.appendingPathComponent("LEDS.LED") }
    var statusURL: URL { root.appendingPathComponent("STATUS.TXT") }
}

/// Cracked drives SidePulse lights from its own agent list, instead of SidePulse's
/// background service. Device detection, the LED program format and the default
/// animations follow SidePulse's open-source tools (github.com/inteliwear/sidepulse).
///
/// The animations below are SidePulse's, MIT License, Copyright (c) 2026 Peter Kuhar;
/// the full notice is in THIRD_PARTY_NOTICES.md, which ships inside the app.
enum SidePulse {
    /// Firmware limits for one program.
    static let maxProgramBytes = 512
    static let maxProgramLines = 20
    /// A finished agent lights the device this long, unless you look at it first.
    static let completedVisible: TimeInterval = 20 * 60
    /// The MacBook SD reader can power an idle card off after about three minutes,
    /// so the Pro gets a real read this often.
    static let keepaliveInterval: TimeInterval = 60

    // MARK: - Discovery

    /// `key value` per line, split at the first run of whitespace (NULs dropped).
    static func parseStatus(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.replacingOccurrences(of: "\0", with: "").split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard let key = parts.first else { continue }
            result[String(key)] = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        }
        return result
    }

    /// Letters and digits only, lowercased: "SidePulse Pro" → "sidepulsepro".
    private static func normalized(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Whether a volume looks like a SidePulse device.
    static func isCandidate(volumeName: String, hasProgram: Bool, hasStatus: Bool) -> Bool {
        if hasProgram || hasStatus { return true }
        let name = normalized(volumeName)
        return ["sidepulsepro", "sidepulsedot", "pulsedot"].contains { name.contains($0) }
    }

    /// Which device a volume is, from its `STATUS.TXT` (a Dot reports `app_version`, a
    /// Pro `release_version`) or, failing that, its name.
    static func device(root: URL, status: [String: String]) -> SidePulseDevice? {
        let name = normalized(root.lastPathComponent)
        let model: SidePulseDevice.Model
        let version: String?
        if status["app_version"] != nil || name.contains("pulsedot") {
            model = .dot
            version = status["app_version"]
        } else if status["release_version"] != nil || name.contains("sidepulse") {
            model = .pro
            version = status["release_version"] ?? status["firmware_version"]
        } else {
            return nil
        }
        return SidePulseDevice(model: model, serial: status["serial"] ?? "unassigned", version: version, root: root)
    }

    /// SidePulse devices mounted under `/Volumes`.
    static func discover(volumes: URL = URL(fileURLWithPath: "/Volumes")) -> [SidePulseDevice] {
        let fm = FileManager.default
        guard let roots = try? fm.contentsOfDirectory(at: volumes, includingPropertiesForKeys: nil) else { return [] }
        return roots.compactMap { root in
            let name = root.lastPathComponent
            guard !name.hasPrefix("."), name != "Macintosh HD" else { return nil }
            let hasProgram = fm.fileExists(atPath: root.appendingPathComponent("LEDS.LED").path)
            let statusURL = root.appendingPathComponent("STATUS.TXT")
            let hasStatus = fm.fileExists(atPath: statusURL.path)
            guard isCandidate(volumeName: name, hasProgram: hasProgram, hasStatus: hasStatus) else { return nil }
            let status = readUncached(statusURL).map { parseStatus(String(decoding: $0, as: UTF8.self)) } ?? [:]
            return device(root: root, status: status)
        }
        .sorted { $0.root.path < $1.root.path }
    }

    /// Reads a small file from the device itself, not macOS's cache (a Dot's `STATUS.TXT`
    /// is about 1 KB, its serial and version past the first 512 bytes): the device rewrites
    /// `STATUS.TXT` behind the file system's back, and a real read also keeps the SD
    /// reader from powering the card off.
    static func readUncached(_ url: URL, limit: Int = 4096) -> Data? {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        _ = fcntl(fd, F_RDAHEAD, 0)
        // Drop any pages already cached for the file.
        var info = stat()
        if fstat(fd, &info) == 0, info.st_size > 0,
           let map = mmap(nil, Int(info.st_size), PROT_READ, MAP_SHARED, fd, 0), map != MAP_FAILED {
            msync(map, Int(info.st_size), MS_INVALIDATE)
            munmap(map, Int(info.st_size))
        }
        var buffer = [UInt8](repeating: 0, count: limit)
        let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, limit, 0) }
        return count >= 0 ? Data(buffer.prefix(count)) : nil
    }

    // MARK: - What to show

    /// The light state for all agents, most actionable first.
    enum LightState: Int, Comparable, Sendable {
        case idle, completed, working, attention

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Blocked or errored beats working, which beats a recent unseen finish, which beats
    /// idle. A finished session lights the device until you open Cracked's menu
    /// (`seenSince`) or `completedVisible` passes.
    static func lightState(for sessions: [AgentSession], seenSince: Date, now: Date) -> LightState {
        sessions.reduce(.idle) { state, session in
            let this: LightState
            switch session.status {
            case .needsInput, .error:
                this = .attention
            case .working:
                this = .working
            case .done where session.updatedAt > seenSince && now.timeIntervalSince(session.updatedAt) < completedVisible:
                this = .completed
            default:
                this = .idle
            }
            return max(state, this)
        }
    }

    /// SidePulse's default ("Cyan") animations. Patterns that depend on the layout come
    /// in two- and eight-LED versions.
    static func animation(for state: LightState, ledCount: Int) -> String {
        let eight = ledCount >= 8
        switch state {
        case .idle:
            return eight
                ? "off 2s\n2:#006060 3:#00E5FF 4:#00E5FF 5:#006060 2s ease\nrepeat"
                : "off 2s\n0:#006060 1:#006060 2s ease\nrepeat"
        case .working:
            if eight {
                let steps = (0..<8).map { "\($0):#00E5FF 760ms pulse \($0 * 95)ms" }.joined(separator: "; ")
                return "off 320ms cosine\n\(steps)\nrepeat"
            }
            return "off 320ms cosine\n0:#00E5FF 760ms pulse 0ms; 1:#00E5FF 760ms pulse 260ms\nrepeat"
        case .attention:
            return "off\n#FF3A00 1.6s pulse\nrepeat"
        case .completed:
            return "#00E5FF 320ms cosine"
        }
    }

    /// Fades to black, for when the Mac goes to sleep.
    static func sleepAnimation(ledCount: Int) -> String {
        ledCount >= 8
            ? "0:#000000 75ms ease; 7:#000000 75ms ease\n1:#000000 75ms ease; 6:#000000 75ms ease\n2:#000000 75ms ease; 5:#000000 75ms ease\n3:#000000 75ms ease; 4:#000000 75ms ease\n#000000 1s"
            : "0:#000000 300ms ease; 1:#000000 300ms ease\n#000000 1s"
    }

    /// Scales a program by the device brightness (1–255): existing `brightness N` lines
    /// are multiplied, otherwise one is added first. At 255 the program is unchanged.
    static func applyBrightness(_ program: String, brightness: Int) -> String {
        let level = min(255, max(1, brightness))
        guard level < 255 else { return program }
        var found = false
        let lines = program.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let parts = line.split(separator: " ")
            if parts.count == 2, parts[0] == "brightness", let value = Int(parts[1]) {
                found = true
                return "brightness \(Int((Double(value) * Double(level) / 255).rounded()))"
            }
            return String(line)
        }
        return found ? lines.joined(separator: "\n") : "brightness \(level)\n" + program
    }

    /// Whether the firmware will accept a program.
    static func isValidProgram(_ program: String) -> Bool {
        !program.isEmpty && program.utf8.count <= maxProgramBytes
            && program.split(separator: "\n").count <= maxProgramLines
    }

    // MARK: - SidePulse's own service

    static var serviceSocket: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/sidepulse/agent-monitor/program-status.sock")
    }

    /// Whether SidePulse's background service is running (it accepts connections on its
    /// status socket). While it is, it drives the lights and Cracked stays out of its way.
    static func isServiceRunning(socket: URL = serviceSocket) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socket.path.utf8CString
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    // MARK: - Writing

    /// Writes a program to `LEDS.LED` in place and syncs it, the way the device expects.
    @discardableResult
    static func write(_ program: String, to url: URL) -> Bool {
        guard isValidProgram(program) else { return false }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let bytes = Array(program.utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, bytes.count) }
        guard written == bytes.count else { return false }
        _ = fsync(fd)
        return true
    }
}

/// Keeps every connected SidePulse device showing the state of Cracked's agents. All
/// file-system work happens on a background queue; a slow or vanished card never
/// blocks the menu.
@MainActor
final class SidePulseLights {
    static let enabledKey = "sidePulseEnabled"
    static let brightnessKey = "sidePulseBrightness"

    private let queue = DispatchQueue(label: "com.bangarang.cracked.sidepulse")
    /// Read and written on `queue` only.
    private nonisolated(unsafe) var lastWritten: [String: String] = [:]
    private nonisolated(unsafe) var lastKeepalive: [String: Date] = [:]
    private var devices: [SidePulseDevice] = []
    private var lastScan = Date.distantPast
    private var serviceRunning = false
    private var asleep = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lastScan = .distantPast }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wake() }
        })
    }

    private var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
    private var brightness: Int {
        let value = UserDefaults.standard.integer(forKey: Self.brightnessKey)
        return value == 0 ? 255 : value
    }

    /// Called whenever Cracked refreshes its agents (about once a second).
    func update(sessions: [AgentSession], seenSince: Date, now: Date = Date()) {
        guard enabled, !asleep else { return }
        let state = SidePulse.lightState(for: sessions, seenSince: seenSince, now: now)
        rescanIfDue(now: now)
        guard !serviceRunning else { return }
        let brightness = brightness
        let targets = devices.map { device in
            (device, SidePulse.applyBrightness(SidePulse.animation(for: state, ledCount: device.ledCount),
                                               brightness: brightness))
        }
        queue.async { [self] in
            for (device, program) in targets where lastWritten[device.id] != program {
                if SidePulse.write(program, to: device.programURL) { lastWritten[device.id] = program }
            }
            keepAlive(targets.map(\.0), now: now)
        }
    }

    /// Devices come and go with mounts; the service check is cheap but needn't run every second.
    private func rescanIfDue(now: Date) {
        guard now.timeIntervalSince(lastScan) >= 10 else { return }
        lastScan = now
        serviceRunning = SidePulse.isServiceRunning()
        devices = SidePulse.discover()
        let live = Set(devices.map(\.id))
        queue.async { [self] in
            lastWritten = lastWritten.filter { live.contains($0.key) }
            lastKeepalive = lastKeepalive.filter { live.contains($0.key) }
        }
    }

    /// A real read of `STATUS.TXT` now and then keeps the Pro's SD reader from powering it off.
    private nonisolated func keepAlive(_ devices: [SidePulseDevice], now: Date) {
        for device in devices where device.model == .pro {
            if now.timeIntervalSince(lastKeepalive[device.id] ?? .distantPast) >= SidePulse.keepaliveInterval {
                _ = SidePulse.readUncached(device.statusURL)
                lastKeepalive[device.id] = now
            }
        }
    }

    private func sleep() {
        asleep = true
        guard enabled, !serviceRunning else { return }
        let targets = devices.map { ($0, SidePulse.sleepAnimation(ledCount: $0.ledCount)) }
        queue.sync { [self] in
            for (device, program) in targets where SidePulse.write(program, to: device.programURL) {
                lastWritten[device.id] = program
            }
        }
    }

    private func wake() {
        asleep = false
        lastScan = .distantPast
    }
}
