import Foundation
import IOKit
import IOUSBHost

/// A SidePulse Dot driven over USB, for when its USB storage is off and it doesn't mount
/// as a drive. The Dot takes the same LED programs through vendor control requests on
/// its default endpoint ("SPC2", from SidePulse's open-source tools). Nothing claims an
/// interface, so this also works next to the Dot's own drive.
enum SidePulseUSB {
    static let vendorID = 0x1a86
    static let productID = 0xfe10
    static let index: UInt16 = 0x5350
    static let timeout: TimeInterval = 1

    enum Request: UInt8 {
        case write = 0x50
        case status = 0x51
        case setStorage = 0x52
        case storageStatus = 0x53
        case info = 0x54
        case reconnect = 0x55
    }

    /// The Dot's program receiver, from the 16-byte status reply: `SPC2`, then
    /// little-endian id, state, reserved, length, received, applied, polls.
    struct Status: Equatable, Sendable {
        enum State: UInt8, Sendable { case idle, receiving, busy, applied, invalid, aborted }

        let id: UInt16
        let state: State?
        let length: UInt16
        let received: UInt16
        let applied: UInt16

        init?(_ bytes: [UInt8]) {
            guard bytes.count >= 16, bytes.prefix(4).elementsEqual("SPC2".utf8) else { return nil }
            func u16(_ i: Int) -> UInt16 { UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 }
            id = u16(4)
            state = State(rawValue: bytes[6])
            length = u16(8)
            received = u16(10)
            applied = u16(12)
        }

        /// Whether this status confirms program `id` of `length` bytes, sent after `before`.
        func confirms(id: UInt16, length: Int, after before: Status) -> Bool {
            self.id == id && state == .applied && Int(self.length) == length && Int(received) == length
                && applied == before.applied &+ 1
        }
    }

    /// One Dot on USB, by its IORegistry entry (stable while it stays plugged in).
    struct Device: Equatable, Sendable {
        let registryID: UInt64
    }

    // MARK: - Finding Dots

    static func devices() -> [Device] {
        let match = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        match["idVendor"] = vendorID
        match["idProduct"] = productID
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [Device] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS { result.append(Device(registryID: id)) }
            IOObjectRelease(service)
        }
        return result
    }

    /// Dots on USB that aren't also mounted as one of `mounted`: those with their USB
    /// storage off, which only USB can reach.
    static func unmountedDots(mounted: [SidePulseDevice]) -> [Device] {
        let all = devices()
        guard !all.isEmpty else { return [] }
        let mountedIDs = Set(mounted.filter { $0.model == .dot }.compactMap { usbDeviceID(forVolume: $0.root) })
        return all.filter { !mountedIDs.contains($0.registryID) }
    }

    /// The registry ID of the USB device behind a mounted volume, so a Dot that's also
    /// mounted is recognised and written only once.
    static func usbDeviceID(forVolume url: URL) -> UInt64? {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { return nil }
        let bsd = withUnsafeBytes(of: fs.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            .replacingOccurrences(of: "/dev/", with: "")
        guard !bsd.isEmpty else { return nil }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd))
        while entry != 0 {
            if IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 {
                var id: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(entry, &id)
                IOObjectRelease(entry)
                return id
            }
            var parent: io_registry_entry_t = 0
            let found = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS
            IOObjectRelease(entry)
            entry = found ? parent : 0
        }
        return nil
    }

    // MARK: - Talking to one

    private static func open(_ device: Device) -> IOUSBHostDevice? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(device.registryID))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return try? IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil)
    }

    private static func request(_ request: Request, value: UInt16 = 0, length: Int, out: Data? = nil) -> IOUSBDeviceRequest {
        var setup = IOUSBDeviceRequest()
        setup.bmRequestType = out == nil && length > 0 ? 0xc0 : 0x40
        setup.bRequest = request.rawValue
        setup.wValue = value
        setup.wIndex = index
        setup.wLength = UInt16(length)
        return setup
    }

    private static func read(_ host: IOUSBHostDevice, _ kind: Request, length: Int) -> [UInt8]? {
        let data = NSMutableData(length: length)!
        var count = 0
        do {
            try host.__send(request(kind, length: length), data: data, bytesTransferred: &count, completionTimeout: timeout)
        } catch {
            return nil
        }
        return Array((data as Data).prefix(count))
    }

    static func status(_ device: Device) -> Status? {
        guard let host = open(device) else { return nil }
        defer { host.destroy() }
        return read(host, .status, length: 16).flatMap(Status.init)
    }

    enum WriteResult: Equatable, Sendable {
        case applied
        /// Refused before sending (busy, unreachable, invalid program): safe to try again.
        case failed
        /// Sent, but not confirmed. Never resent automatically, as SidePulse does: the
        /// Dot may already be showing it.
        case uncertain
    }

    /// Sends a program and waits up to 2 s for the Dot to confirm it applied it.
    static func write(_ program: String, to device: Device) -> WriteResult {
        let payload = Data(program.utf8)
        guard SidePulse.isValidProgram(program), let host = open(device) else { return .failed }
        defer { host.destroy() }
        guard let before = read(host, .status, length: 16).flatMap(Status.init), before.state != .busy else { return .failed }
        var id = UInt16.random(in: 1...UInt16.max)
        if id == before.id { id = id &+ 1 == 0 ? 1 : id &+ 1 }
        var sent = 0
        do {
            try host.__send(request(.write, value: id, length: payload.count, out: payload),
                            data: NSMutableData(data: payload), bytesTransferred: &sent, completionTimeout: timeout)
        } catch {
            return .uncertain
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let now = read(host, .status, length: 16).flatMap(Status.init) {
                if now.confirms(id: id, length: payload.count, after: before) { return .applied }
                if now.id == id, now.state == .invalid || now.state == .aborted { return .failed }
            }
            usleep(5_000)
        }
        return .uncertain
    }

    // MARK: - USB storage

    /// The Dot's USB storage setting, from the 8-byte `SPS1` reply: saved, active, state.
    struct StorageStatus: Equatable, Sendable {
        enum State: UInt8, Sendable { case ready, busy, failed }
        let saved: Bool
        let active: Bool
        let state: State?

        init?(_ bytes: [UInt8]) {
            guard bytes.count >= 7, bytes.prefix(4).elementsEqual("SPS1".utf8) else { return nil }
            saved = bytes[4] != 0
            active = bytes[5] != 0
            state = State(rawValue: bytes[6])
        }
    }

    static func storageStatus(_ device: Device) -> StorageStatus? {
        guard let host = open(device) else { return nil }
        defer { host.destroy() }
        return read(host, .storageStatus, length: 8).flatMap(StorageStatus.init)
    }

    /// Turns the Dot's USB storage on or off (the Dot saves the setting) and reconnects it,
    /// so it comes back as a drive or as USB only. Blocking: up to about 6 s. Eject the
    /// Dot's drive before turning storage off.
    @discardableResult
    static func setStorage(_ on: Bool, device: Device) -> Bool {
        guard let host = open(device) else { return false }
        defer { host.destroy() }
        var sent = 0
        do {
            try host.__send(request(.setStorage, value: on ? 1 : 0, length: 0), data: nil,
                            bytesTransferred: &sent, completionTimeout: timeout)
        } catch {
            return false
        }
        // Wait for the setting to be saved. Firmware that doesn't report it just gets a moment.
        let deadline = Date().addingTimeInterval(5)
        var reported = false
        while Date() < deadline {
            guard let status = read(host, .storageStatus, length: 8).flatMap(StorageStatus.init) else { break }
            reported = true
            if status.state == .failed { return false }
            if status.state == .ready, status.saved == on { break }
            usleep(50_000)
        }
        if !reported { usleep(1_000_000) }
        // The Dot detaches to reconnect, so this request may not get an answer.
        try? host.__send(request(.reconnect, length: 0), data: nil, bytesTransferred: &sent, completionTimeout: timeout)
        return true
    }
}
