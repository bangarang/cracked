import Foundation
import IOKit.ps

/// Who this Mac is, for the fleet, share cards and the leaderboard.
///
/// `id` is a random UUID made on first launch, not the hardware UUID, so it can't
/// be used to fingerprint the Mac outside Cracked.
struct MachineIdentity: Codable, Equatable, Hashable, Sendable, Identifiable {
    enum FormFactor: String, Codable, Sendable {
        case laptop, mini, studio, desktop

        var symbol: String {
            switch self {
            case .laptop: "laptopcomputer"
            case .mini: "macmini"
            case .studio: "macstudio"
            case .desktop: "desktopcomputer"
            }
        }
    }

    let id: String
    var name: String
    /// `hw.model`, e.g. "Mac16,11".
    let model: String
    /// "Apple M4 Pro".
    let chip: String
    let cpuCores: Int
    let performanceCores: Int
    let memoryGB: Int
    let formFactor: FormFactor

    /// The leaderboard division: "M4 Pro", "M1 Max"… (the chip without "Apple ").
    var chipClass: String { Self.chipClass(from: chip) }

    /// "Mac mini · M4 Pro · 48 GB"
    var hardwareSummary: String {
        let kind = switch formFactor {
        case .laptop: "MacBook"
        case .mini: "Mac mini"
        case .studio: "Mac Studio"
        case .desktop: "Mac"
        }
        return "\(kind) · \(chipClass) · \(memoryGB) GB"
    }

    // MARK: - This Mac

    static let idKey = "machineID"
    static let nameKey = "machineName"

    static func current(defaults: UserDefaults = .standard) -> MachineIdentity {
        let id: String
        if let existing = defaults.string(forKey: idKey), !existing.isEmpty {
            id = existing
        } else {
            id = UUID().uuidString
            defaults.set(id, forKey: idKey)
        }
        let customName = defaults.string(forKey: nameKey)?.trimmingCharacters(in: .whitespaces)
        let model = sysctlString("hw.model") ?? "Mac"
        return MachineIdentity(
            id: id,
            name: (customName?.isEmpty == false ? customName : nil) ?? defaultName,
            model: model,
            chip: sysctlString("machdep.cpu.brand_string") ?? "Apple silicon",
            cpuCores: ProcessInfo.processInfo.activeProcessorCount,
            performanceCores: sysctlInt("hw.perflevel0.physicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount,
            memoryGB: Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()),
            formFactor: formFactor(model: model, hasBattery: hasInternalBattery())
        )
    }

    /// The computer name from Sharing settings ("Alex's Mac mini").
    static var defaultName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    // MARK: - Derivations (pure, tested)

    static func chipClass(from brand: String) -> String {
        var chip = brand.trimmingCharacters(in: .whitespaces)
        if chip.hasPrefix("Apple ") { chip.removeFirst("Apple ".count) }
        return chip.isEmpty ? "Apple silicon" : chip
    }

    /// Model identifiers of Apple silicon Mac minis and Mac Studios. Anything with a
    /// battery is a laptop; any other desktop is an iMac or Mac Pro.
    private static let minis: Set<String> = ["Macmini9,1", "Mac14,3", "Mac14,12", "Mac16,10", "Mac16,11"]
    private static let studios: Set<String> = ["Mac13,1", "Mac13,2", "Mac14,13", "Mac14,14", "Mac15,14", "Mac16,9"]

    static func formFactor(model: String, hasBattery: Bool) -> FormFactor {
        if hasBattery || model.hasPrefix("MacBook") { return .laptop }
        if minis.contains(model) || model.hasPrefix("Macmini") { return .mini }
        if studios.contains(model) { return .studio }
        return .desktop
    }

    // MARK: - sysctl

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func hasInternalBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }
}
