import Foundation
import CryptoKit

/// Firmware updates for SidePulse devices, the way SidePulse's own tools do them:
/// releases are published as `firmware/v<version>/` folders in the inteliwear/sidepulse
/// GitHub repository, each with a `SHA256SUMS.txt` and one OTA ZIP per model. An update
/// is installed by copying the package's `FIRMWARE.BIN` to the device's drive; the
/// device checks and applies it (images are encrypted for the device), then restarts.
///
/// Cracked only goes online for this when you ask it to check.
enum SidePulseFirmware {
    static let listingURL = URL(string: "https://api.github.com/repos/inteliwear/sidepulse/contents/firmware?ref=main")!
    static let downloadRoot = URL(string: "https://raw.githubusercontent.com/inteliwear/sidepulse/main/firmware")!
    static let maxPackageBytes = 4 * 1024 * 1024
    /// The device needs this long to apply an update and restart.
    static let applySeconds: TimeInterval = 10

    struct Version: Comparable, CustomStringConvertible, Sendable, Hashable {
        let parts: [Int]

        init?(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let body = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
            let numbers = body.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard (2...3).contains(numbers.count), numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
            parts = numbers.map { $0! } + (numbers.count == 2 ? [0] : [])
        }

        static func < (lhs: Version, rhs: Version) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
        var description: String { parts.map(String.init).joined(separator: ".") }
    }

    /// A model's package in a release.
    struct Release: Equatable, Sendable {
        let model: SidePulseDevice.Model
        let version: Version
        let fileName: String
        let sha256: String

        var url: URL { downloadRoot.appendingPathComponent("v\(version)").appendingPathComponent(fileName) }
    }

    static func modelSlug(_ model: SidePulseDevice.Model) -> String { model == .pro ? "pro" : "dot" }

    static func packageName(_ model: SidePulseDevice.Model, _ version: Version) -> String {
        "sidepulse-\(modelSlug(model))-\(version)-ota.zip"
    }

    // MARK: - Parsing

    /// Release versions from the GitHub contents listing of `firmware/`, newest first.
    static func versions(fromListing data: Data) -> [Version] {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry -> Version? in
            guard entry["type"] as? String == "dir", let name = entry["name"] as? String,
                  name.range(of: #"^v\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else { return nil }
            return Version(name)
        }
        .sorted(by: >)
    }

    /// `SHA256SUMS.txt`: `<64 hex>  <name>` per line. Nil if any line is malformed or repeated.
    static func checksums(_ text: String) -> [String: String]? {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let match = line.wholeMatch(of: /([0-9a-fA-F]{64})  ([A-Za-z0-9_.-]+)/) else { return nil }
            let name = String(match.2)
            guard result[name] == nil else { return nil }
            result[name] = match.1.lowercased()
        }
        return result
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Checking

    enum FirmwareError: LocalizedError, Equatable {
        case unavailable(String)
        case badPackage(String)
        case wrongDevice(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let why): "Couldn't check for firmware: \(why)"
            case .badPackage(let why): "The firmware package didn't verify: \(why)"
            case .wrongDevice(let why): why
            case .writeFailed(let why): "Couldn't copy the firmware to the device: \(why). Leave it connected for 10 seconds, reconnect it and check its version before trying again."
            }
        }
    }

    private static func fetch(_ url: URL, limit: Int) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Cracked", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw FirmwareError.unavailable("\(url.lastPathComponent) answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard data.count <= limit else { throw FirmwareError.unavailable("\(url.lastPathComponent) is too large") }
        return data
    }

    /// The newest published release for each model.
    static func latest() async throws -> [SidePulseDevice.Model: Release] {
        let listing: Data
        do { listing = try await fetch(listingURL, limit: 1 << 20) } catch let error as FirmwareError { throw error } catch {
            throw FirmwareError.unavailable(error.localizedDescription)
        }
        var found: [SidePulseDevice.Model: Release] = [:]
        for version in versions(fromListing: listing) {
            let url = downloadRoot.appendingPathComponent("v\(version)").appendingPathComponent("SHA256SUMS.txt")
            guard let data = try? await fetch(url, limit: 64 * 1024),
                  let sums = checksums(String(decoding: data, as: UTF8.self)) else { continue }
            for model in [SidePulseDevice.Model.pro, .dot] where found[model] == nil {
                let name = packageName(model, version)
                if let hash = sums[name] { found[model] = Release(model: model, version: version, fileName: name, sha256: hash) }
            }
            if found.count == 2 { break }
        }
        guard !found.isEmpty else { throw FirmwareError.unavailable("no firmware releases found") }
        return found
    }

    // MARK: - Verifying a package

    static let packageFiles: Set<String> = ["FIRMWARE.BIN", "README.txt", "RELEASE_NOTES.txt", "SHA256SUMS.txt"]

    /// Checks a downloaded package against its release and returns `FIRMWARE.BIN`:
    /// the ZIP's SHA-256, exactly the expected files, their inner checksums, and a
    /// README naming this model and version.
    static func firmware(fromPackage zip: Data, for release: Release) throws -> Data {
        guard sha256(zip) == release.sha256 else { throw FirmwareError.badPackage("checksum mismatch") }
        let files = try unzip(zip)
        // Files may sit at the top level or in one folder named after the package.
        let folder = String(release.fileName.dropLast(4)) + "/"
        let flat = Dictionary(uniqueKeysWithValues: files.map { name, data in
            (name.hasPrefix(folder) ? String(name.dropFirst(folder.count)) : name, data)
        })
        guard Set(flat.keys) == packageFiles else {
            throw FirmwareError.badPackage("unexpected files: \(flat.keys.sorted().joined(separator: ", "))")
        }
        guard let sums = checksums(String(decoding: flat["SHA256SUMS.txt"]!, as: UTF8.self)),
              Set(sums.keys) == packageFiles.subtracting(["SHA256SUMS.txt"]) else {
            throw FirmwareError.badPackage("bad SHA256SUMS.txt")
        }
        for (name, hash) in sums where sha256(flat[name]!) != hash {
            throw FirmwareError.badPackage("\(name) checksum mismatch")
        }
        let title = String(decoding: flat["README.txt"]!, as: UTF8.self).split(whereSeparator: \.isNewline).first ?? ""
        guard title.trimmingCharacters(in: .whitespaces) == "\(release.model.rawValue) firmware update - version \(release.version)" else {
            throw FirmwareError.badPackage("it's not \(release.model.rawValue) \(release.version)")
        }
        let firmware = flat["FIRMWARE.BIN"]!
        guard !firmware.isEmpty else { throw FirmwareError.badPackage("FIRMWARE.BIN is empty") }
        return firmware
    }

    /// Extracts a ZIP with the system's `ditto` into a private temporary folder.
    static func unzip(_ zip: Data) throws -> [String: Data] {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("cracked-firmware-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let archive = work.appendingPathComponent("package.zip")
        let out = work.appendingPathComponent("out", isDirectory: true)
        try zip.write(to: archive)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, out.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw FirmwareError.badPackage("couldn't open the ZIP") }
        var files: [String: Data] = [:]
        var total = 0
        let enumerator = fm.enumerator(at: out, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw FirmwareError.badPackage("it contains a link") }
            guard values.isRegularFile == true else { continue }
            let name = String(url.standardizedFileURL.path.dropFirst(out.standardizedFileURL.path.count + 1))
            if name.hasPrefix("__MACOSX/") || (name as NSString).lastPathComponent == ".DS_Store" { continue }
            let data = try Data(contentsOf: url)
            total += data.count
            guard total <= maxPackageBytes else { throw FirmwareError.badPackage("it's too large") }
            files[name] = data
        }
        return files
    }

    // MARK: - Installing

    /// Downloads, verifies and copies an update to a mounted device. Throws without
    /// touching the device unless everything checks out, including that the device is
    /// still the same model, serial and an older version.
    static func install(_ release: Release, on device: SidePulseDevice) async throws {
        guard release.model == device.model else { throw FirmwareError.wrongDevice("That firmware is for a \(release.model.rawValue).") }
        let zip: Data
        do { zip = try await fetch(release.url, limit: maxPackageBytes) } catch let error as FirmwareError { throw error } catch {
            throw FirmwareError.unavailable(error.localizedDescription)
        }
        let firmware = try self.firmware(fromPackage: zip, for: release)

        // The same device as when the update was offered, and still older.
        let now = SidePulse.readUncached(device.statusURL, limit: 64 * 1024)
            .map { SidePulse.parseStatus(String(decoding: $0, as: UTF8.self)) }
            .flatMap { SidePulse.device(root: device.root, status: $0) }
        guard let now, now.model == device.model, now.serial == device.serial else {
            throw FirmwareError.wrongDevice("The \(device.model.rawValue) changed or was disconnected. Check it and try again.")
        }
        if let installed = now.version.flatMap(Version.init), installed >= release.version {
            throw FirmwareError.wrongDevice("The \(device.model.rawValue) is already on firmware \(installed).")
        }

        let target = device.root.appendingPathComponent("FIRMWARE.BIN")
        if (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            throw FirmwareError.writeFailed("FIRMWARE.BIN on the device is a link")
        }
        try write(firmware, to: target)
    }

    /// Writes the whole image and syncs it and its folder, so the device sees all of it.
    static func write(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw FirmwareError.writeFailed(String(cString: strerror(errno))) }
        defer { close(fd) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        guard written == data.count else { throw FirmwareError.writeFailed(String(cString: strerror(errno))) }
        guard fsync(fd) == 0 else { throw FirmwareError.writeFailed(String(cString: strerror(errno))) }
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY)
        if directory >= 0 {
            fsync(directory)
            close(directory)
        }
    }
}
