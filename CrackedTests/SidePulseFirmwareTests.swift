import Foundation
import Testing
@testable import Cracked

@Suite("SidePulse firmware")
struct SidePulseFirmwareTests {
    typealias V = SidePulseFirmware.Version

    @Test("Versions compare as numbers")
    func versions() {
        #expect(V("1.1.14")! > V("1.1.9")!)
        #expect(V("v1.2")! == V("1.2.0")!)
        #expect(V("1.1.0")! < V("1.10.0")!)
        #expect(V("unknown") == nil)
        #expect(V("1") == nil)
        #expect(V("1.2.3.4") == nil)
        #expect(V("1.1.14")!.description == "1.1.14")
    }

    @Test("Release folders come from GitHub's listing, newest first")
    func listing() {
        let json = """
            [{"name":"README.md","type":"file"},{"name":"v1.1.0","type":"dir"},
             {"name":"v1.1.14","type":"dir"},{"name":"vNext","type":"dir"},{"name":"v1.2","type":"dir"}]
            """
        #expect(SidePulseFirmware.versions(fromListing: Data(json.utf8)).map(\.description) == ["1.1.14", "1.1.0"])
        #expect(SidePulseFirmware.versions(fromListing: Data("nope".utf8)).isEmpty)
    }

    @Test("SHA256SUMS.txt is strict")
    func checksums() {
        let hash = String(repeating: "a", count: 64)
        #expect(SidePulseFirmware.checksums("\(hash)  sidepulse-dot-1.1.14-ota.zip\n") == ["sidepulse-dot-1.1.14-ota.zip": hash])
        #expect(SidePulseFirmware.checksums("\(hash) one-space.zip") == nil)
        #expect(SidePulseFirmware.checksums("\(hash)  a.zip\n\(hash)  a.zip") == nil, "Repeated names")
        #expect(SidePulseFirmware.checksums("\(hash)  ../evil") == nil)
    }

    /// Builds a package the way SidePulse publishes them.
    func package(model: SidePulseDevice.Model = .dot, version: String = "1.1.14", readme: String? = nil,
                 extra: Bool = false, tamper: Bool = false, folder: Bool = true) throws -> (Data, SidePulseFirmware.Release) {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: work) }
        let name = "sidepulse-\(model == .pro ? "pro" : "dot")-\(version)-ota"
        let root = folder ? work.appendingPathComponent(name) : work.appendingPathComponent("flat")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let files: [String: Data] = [
            "FIRMWARE.BIN": Data("UF2\nencrypted".utf8),
            "README.txt": Data((readme ?? "\(model.rawValue) firmware update - version \(version)\nCopy FIRMWARE.BIN").utf8),
            "RELEASE_NOTES.txt": Data("notes".utf8),
        ]
        var sums = ""
        for (file, data) in files {
            try data.write(to: root.appendingPathComponent(file))
            sums += "\(SidePulseFirmware.sha256(data))  \(file)\n"
        }
        try Data(sums.utf8).write(to: root.appendingPathComponent("SHA256SUMS.txt"))
        if tamper { try Data("UF2\nchanged".utf8).write(to: root.appendingPathComponent("FIRMWARE.BIN")) }
        if extra { try Data("x".utf8).write(to: root.appendingPathComponent("EXTRA.txt")) }
        let zipURL = work.appendingPathComponent("\(name).zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = folder ? work : root
        zip.arguments = ["-q", "-r", zipURL.path, folder ? name : "."]
        try zip.run()
        zip.waitUntilExit()
        let data = try Data(contentsOf: zipURL)
        let release = SidePulseFirmware.Release(model: model, version: V(version)!, fileName: "\(name).zip",
                                                sha256: SidePulseFirmware.sha256(data))
        return (data, release)
    }

    @Test("A good package gives up its FIRMWARE.BIN, in a folder or not")
    func goodPackage() throws {
        let (zip, release) = try package()
        #expect(try SidePulseFirmware.firmware(fromPackage: zip, for: release) == Data("UF2\nencrypted".utf8))
        let (flat, flatRelease) = try package(folder: false)
        #expect(try SidePulseFirmware.firmware(fromPackage: flat, for: flatRelease).isEmpty == false)
    }

    @Test("The image is written whole, replacing any earlier copy")
    func writeImage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).BIN")
        defer { try? FileManager.default.removeItem(at: url) }
        try SidePulseFirmware.write(Data(repeating: 1, count: 4096), to: url)
        try SidePulseFirmware.write(Data(repeating: 2, count: 100), to: url)
        #expect(try Data(contentsOf: url) == Data(repeating: 2, count: 100))
        #expect(throws: SidePulseFirmware.FirmwareError.self) {
            try SidePulseFirmware.write(Data([1]), to: URL(fileURLWithPath: "/nonexistent/FIRMWARE.BIN"))
        }
    }

    @Test("Anything off about a package refuses it")
    func badPackages() throws {
        func refused(_ make: () throws -> (Data, SidePulseFirmware.Release),
                     changing: (SidePulseFirmware.Release) -> SidePulseFirmware.Release = { $0 }) -> Bool {
            guard let (zip, release) = try? make() else { return false }
            return (try? SidePulseFirmware.firmware(fromPackage: zip, for: changing(release))) == nil
        }
        #expect(refused({ try package() }, changing: {
            .init(model: $0.model, version: $0.version, fileName: $0.fileName, sha256: String(repeating: "0", count: 64))
        }), "Outer checksum")
        #expect(refused({ try package(tamper: true) }), "Inner checksum")
        #expect(refused({ try package(extra: true) }), "Unexpected file")
        #expect(refused({ try package(readme: "SidePulse Pro firmware update - version 1.1.14") }), "Other model")
        #expect(refused({ try package(readme: "SidePulse Dot firmware update - version 9.9.9") }), "Other version")
    }
}

@Suite("SidePulse USB")
struct SidePulseUSBTests {
    @Test("Reads the Dot's program and storage status replies")
    func replies() throws {
        // Captured from a Dot (firmware 1.1.14) right after a USB write.
        let bytes: [UInt8] = [0x53, 0x50, 0x43, 0x32, 0x3e, 0xf5, 3, 0, 78, 0, 78, 0, 1, 0, 9, 0]
        let status = try #require(SidePulseUSB.Status(bytes))
        #expect(status.id == 0xf53e)
        #expect(status.state == .applied)
        let before = try #require(SidePulseUSB.Status([0x53, 0x50, 0x43, 0x32, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
        #expect(status.confirms(id: 0xf53e, length: 78, after: before))
        #expect(!status.confirms(id: 0xf53e, length: 77, after: before), "Not all of it")
        #expect(!status.confirms(id: 1, length: 78, after: before), "Someone else's write")
        #expect(!status.confirms(id: 0xf53e, length: 78, after: status), "Applied counter didn't move")
        #expect(SidePulseUSB.Status(Array("NOPE".utf8) + [UInt8](repeating: 0, count: 12)) == nil)

        let storage = try #require(SidePulseUSB.StorageStatus([0x53, 0x50, 0x53, 0x31, 1, 0, 0, 0]))
        #expect(storage.saved && !storage.active && storage.state == .ready)
    }
}
