import Foundation
import Testing
@testable import Cracked

@Suite("SidePulse")
struct SidePulseTests {
    let now = Date(timeIntervalSince1970: 1_794_500_000)

    func agent(_ status: AgentSession.Status, ago: TimeInterval = 10) -> AgentSession {
        AgentSession(sessionID: UUID().uuidString, cwd: "/tmp", status: status, message: nil,
                     startedAt: now.addingTimeInterval(-3600), updatedAt: now.addingTimeInterval(-ago))
    }

    @Test("Reads STATUS.TXT and tells a Pro from a Dot")
    func devices() throws {
        let pro = SidePulse.parseStatus("release_version 1.1.0\nfirmware_version 1.1.0\nserial SPP-001397\n")
        let proDevice = try #require(SidePulse.device(root: URL(fileURLWithPath: "/Volumes/SidePulse"), status: pro))
        #expect(proDevice.model == .pro)
        #expect(proDevice.ledCount == 8)
        #expect(proDevice.serial == "SPP-001397")
        #expect(proDevice.version == "1.1.0")

        let dot = SidePulse.parseStatus("app_version 1.2.3\r\nserial\tSPD-000012\0")
        let dotDevice = try #require(SidePulse.device(root: URL(fileURLWithPath: "/Volumes/PulseDot"), status: dot))
        #expect(dotDevice.model == .dot)
        #expect(dotDevice.ledCount == 2)
        #expect(dotDevice.serial == "SPD-000012")

        #expect(SidePulse.device(root: URL(fileURLWithPath: "/Volumes/PulseDot"), status: [:])?.model == .dot, "Name alone")
        #expect(SidePulse.device(root: URL(fileURLWithPath: "/Volumes/USB Stick"), status: [:]) == nil)
        #expect(SidePulse.isCandidate(volumeName: "SidePulse Pro", hasProgram: false, hasStatus: false))
        #expect(!SidePulse.isCandidate(volumeName: "Backup", hasProgram: false, hasStatus: false))
    }

    @Test("Finds mounted devices by their files")
    func discover() throws {
        let volumes = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: volumes) }
        let pro = volumes.appendingPathComponent("SidePulse")
        let other = volumes.appendingPathComponent("Backup")
        for dir in [pro, other] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data("release_version 1.1.0\nserial SPP-1\n".utf8).write(to: pro.appendingPathComponent("STATUS.TXT"))
        try Data().write(to: pro.appendingPathComponent("LEDS.LED"))
        let found = SidePulse.discover(volumes: volumes)
        #expect(found.map(\.serial) == ["SPP-1"])

        // A Dot's STATUS.TXT is about 1 KB of counters, with its serial and version past byte 512.
        let dot = volumes.appendingPathComponent("PulseDot")
        try FileManager.default.createDirectory(at: dot, withIntermediateDirectories: true)
        let counters = (0..<40).map { "counter\($0) 00000000" }.joined(separator: "\n")
        try Data("\(counters)\nserial SPD-000550\napp_version 1.1.14\n".utf8).write(to: dot.appendingPathComponent("STATUS.TXT"))
        let dotDevice = try #require(SidePulse.discover(volumes: volumes).first { $0.model == .dot })
        #expect(dotDevice.serial == "SPD-000550")
        #expect(dotDevice.version == "1.1.14")
    }

    @Test("The most actionable agent decides the lights")
    func lightState() {
        let seen = now.addingTimeInterval(-3600)
        func state(_ sessions: [AgentSession], seenSince: Date? = nil) -> SidePulse.LightState {
            SidePulse.lightState(for: sessions, seenSince: seenSince ?? seen, now: now)
        }
        #expect(state([]) == .idle)
        #expect(state([agent(.ready), agent(.running)]) == .idle)
        #expect(state([agent(.working), agent(.done)]) == .working)
        #expect(state([agent(.working), agent(.needsInput)]) == .attention)
        #expect(state([agent(.error)]) == .attention)
        #expect(state([agent(.done)]) == .completed)
        #expect(state([agent(.done, ago: 30)], seenSince: now.addingTimeInterval(-5)) == .idle, "Seen in Cracked's menu")
        #expect(state([agent(.done, ago: SidePulse.completedVisible + 1)]) == .idle, "Finished long ago")
    }

    @Test("Programs fit the device and the firmware's limits")
    func programs() {
        for state in [SidePulse.LightState.idle, .working, .attention, .completed] {
            for leds in [2, 8] {
                let program = SidePulse.animation(for: state, ledCount: leds)
                #expect(SidePulse.isValidProgram(program), "\(state) on \(leds) LEDs")
                #expect(SidePulse.isValidProgram(SidePulse.applyBrightness(program, brightness: 40)))
            }
        }
        for leds in [2, 8] { #expect(SidePulse.isValidProgram(SidePulse.sleepAnimation(ledCount: leds))) }
        #expect(SidePulse.animation(for: .working, ledCount: 8).contains("7:#00E5FF 760ms pulse 665ms"))
        #expect(!SidePulse.animation(for: .working, ledCount: 2).contains("2:#"))
        #expect(!SidePulse.isValidProgram(""))
        #expect(!SidePulse.isValidProgram(String(repeating: "x", count: 513)))
    }

    @Test("Brightness scales a program like SidePulse does")
    func brightness() {
        #expect(SidePulse.applyBrightness("#FF0000", brightness: 255) == "#FF0000")
        #expect(SidePulse.applyBrightness("#FF0000", brightness: 128) == "brightness 128\n#FF0000")
        #expect(SidePulse.applyBrightness("brightness 200\n#FF0000", brightness: 128) == "brightness 100\n#FF0000")
        #expect(SidePulse.applyBrightness("#FF0000", brightness: 0) == "brightness 1\n#FF0000", "Never fully dark")
    }

    @Test("Writes a program in place")
    func write() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).LED")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(SidePulse.write("#00E5FF 320ms cosine", to: url))
        #expect(SidePulse.write("off", to: url))
        #expect(try String(contentsOf: url, encoding: .utf8) == "off", "Replaces, doesn't append")
        #expect(!SidePulse.write("", to: url), "Never writes an invalid program")
        #expect(SidePulse.readUncached(url) == Data("off".utf8))
    }

    @Test("The eject guard only protects SidePulse cards in the built-in SD reader")
    func ejectGuard() {
        func prevent(_ proto: String?, model: String? = nil, name: String?, uuid: String? = nil,
                     known: Set<String> = []) -> Bool {
            SidePulseEjectGuard.shouldPrevent(protocolName: proto, model: model, volumeName: name,
                                              volumeUUID: uuid, known: known)
        }
        #expect(prevent("Secure Digital", name: "SidePulse"))
        #expect(prevent(nil, model: "Built In SDXC Reader", name: "SidePulse Pro"))
        #expect(prevent("Secure Digital", name: nil, uuid: "b293bb91-193c", known: ["B293BB91-193C"]),
                "Unmounted, so no name, but its volume was seen before")
        #expect(!prevent("Secure Digital", name: "EOS_DIGITAL"), "Someone else's SD card ejects normally")
        #expect(!prevent("USB", name: "PulseDot"), "Only the SD reader has the locked-screen problem")
        #expect(!prevent("USB", name: "SidePulse", uuid: "X", known: ["X"]))
    }

    @Test("SidePulse's service counts as running only if its socket answers")
    func service() {
        #expect(!SidePulse.isServiceRunning(socket: URL(fileURLWithPath: "/tmp/no-such-\(UUID().uuidString).sock")))
    }
}
