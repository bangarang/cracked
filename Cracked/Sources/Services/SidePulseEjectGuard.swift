import Foundation
import DiskArbitration

/// Keeps a SidePulse Pro mounted in the MacBook's SD card reader.
///
/// When a disk appears while the screen is locked (the SD slot re-enumerates after a
/// hibernate wake, for example), macOS's loginwindow refuses to mount it and ejects
/// it, and the Pro goes dark until it's reseated. Ejects go through Disk Arbitration's
/// approval step, so Cracked dissents for the Pro and keeps retrying the mount, which
/// succeeds once the Mac is unlocked. Same approach as SidePulse's "Eject Prevention"
/// helper, but limited to SidePulse cards and switchable in Settings.
@MainActor
final class SidePulseEjectGuard {
    static let enabledKey = "sidePulseKeepMounted"
    /// Volume UUIDs of SidePulse Pro cards seen mounted, to recognise one that macOS has
    /// already unmounted (it then has no volume path to look into).
    static let knownVolumesKey = "sidePulseKnownVolumeUUIDs"
    static let mountRetryInterval: TimeInterval = 5
    static let dissentMessage = "Cracked is keeping your SidePulse Pro mounted. To eject it, turn off Settings → SidePulse → Keep SidePulse Pro mounted."

    /// A disk the main-run-loop timer remounts. Only ever touched on the main thread.
    private struct Card: @unchecked Sendable { let disk: DADisk }

    private var session: DASession?
    private var diskArbitrationPID: Int32 = 0
    private var retries: [String: Timer] = [:]
    private var pidTimer: Timer?

    var isEnabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    static var knownVolumeUUIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: knownVolumesKey) ?? [])
    }

    /// Records a SidePulse Pro's volume UUID.
    static func remember(volumeUUID: String) {
        var known = knownVolumeUUIDs
        guard known.insert(volumeUUID.uppercased()).inserted else { return }
        UserDefaults.standard.set(Array(known).sorted(), forKey: knownVolumesKey)
    }

    // MARK: - Which disks

    /// Whether a disk is a card in the built-in SD reader.
    nonisolated static func isBuiltInSD(protocolName: String?, model: String?) -> Bool {
        (protocolName?.contains("Secure Digital") ?? false) || (model?.contains("SDXC") ?? false)
    }

    /// Whether an eject should be refused: a SidePulse card in the built-in SD reader,
    /// known by its volume name or a volume UUID seen before.
    nonisolated static func shouldPrevent(protocolName: String?, model: String?, volumeName: String?,
                                          volumeUUID: String?, known: Set<String>) -> Bool {
        guard isBuiltInSD(protocolName: protocolName, model: model) else { return false }
        if let uuid = volumeUUID, known.contains(uuid.uppercased()) { return true }
        let name = (volumeName ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
        return name.contains("sidepulse")
    }

    nonisolated static func shouldPrevent(_ disk: DADisk, known: Set<String>) -> Bool {
        guard let description = DADiskCopyDescription(disk) as? [CFString: Any] else { return false }
        var uuid: String?
        if let raw = description[kDADiskDescriptionVolumeUUIDKey], CFGetTypeID(raw as CFTypeRef) == CFUUIDGetTypeID() {
            uuid = CFUUIDCreateString(nil, (raw as! CFUUID)) as String
        }
        return shouldPrevent(protocolName: description[kDADiskDescriptionDeviceProtocolKey] as? String,
                             model: description[kDADiskDescriptionDeviceModelKey] as? String,
                             volumeName: description[kDADiskDescriptionVolumeNameKey] as? String,
                             volumeUUID: uuid, known: known)
    }

    nonisolated static func isMounted(_ disk: DADisk) -> Bool {
        guard let description = DADiskCopyDescription(disk) as? [CFString: Any] else { return false }
        return description[kDADiskDescriptionVolumePathKey] != nil
    }

    // MARK: - Running

    /// Starts or stops the guard to match the setting. Safe to call often.
    func update() {
        if isEnabled, session == nil {
            start()
        } else if !isEnabled, session != nil {
            stop()
        }
    }

    private func start() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        diskArbitrationPID = Self.currentDiskArbitrationPID()
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskEjectApprovalCallback(session, nil, { disk, context in
            guard let context else { return nil }
            let guardian = Unmanaged<SidePulseEjectGuard>.fromOpaque(context).takeUnretainedValue()
            // Disk Arbitration calls back on the run loop it's scheduled on: the main one.
            let prevent = MainActor.assumeIsolated { guardian.shouldRefuseEject(disk) }
            guard prevent else { return nil }
            return Unmanaged.passRetained(DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnNotPermitted),
                                                            SidePulseEjectGuard.dissentMessage as CFString))
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { disk, context in
            guard let context, let name = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }
            let guardian = Unmanaged<SidePulseEjectGuard>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { guardian.stopRetrying(name) }
        }, context)
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        // If diskarbitrationd restarts, this session is left registered with the old one.
        pidTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDiskArbitration() }
        }
    }

    private func stop() {
        pidTimer?.invalidate()
        pidTimer = nil
        retries.values.forEach { $0.invalidate() }
        retries = [:]
        if let session { DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) }
        session = nil
    }

    /// Whether to refuse this eject; if so, starts remounting the card.
    private func shouldRefuseEject(_ disk: DADisk) -> Bool {
        guard isEnabled, Self.shouldPrevent(disk, known: Self.knownVolumeUUIDs) else { return false }
        startRetrying(disk)
        return true
    }

    /// Retries the mount until it works (it's refused while the screen is locked) or the
    /// card is pulled out.
    private func startRetrying(_ disk: DADisk) {
        guard let name = DADiskGetBSDName(disk).map({ String(cString: $0) }), retries[name] == nil else { return }
        let card = Card(disk: disk)
        retries[name] = Timer.scheduledTimer(withTimeInterval: Self.mountRetryInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if Self.isMounted(card.disk) {
                    self?.stopRetrying(name)
                } else {
                    DADiskMount(card.disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), nil, nil)
                }
            }
        }
    }

    private func stopRetrying(_ name: String) {
        retries.removeValue(forKey: name)?.invalidate()
    }

    private func checkDiskArbitration() {
        let pid = Self.currentDiskArbitrationPID()
        guard pid > 0, diskArbitrationPID > 0, pid != diskArbitrationPID else {
            if diskArbitrationPID == 0 { diskArbitrationPID = pid }
            return
        }
        stop()
        start()
    }

    nonisolated static func currentDiskArbitrationPID() -> Int32 {
        guard let text = try? String(contentsOfFile: "/var/run/diskarbitrationd.pid", encoding: .utf8) else { return 0 }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}
