import Foundation
import CryptoKit

/// Pairing and request signing between Cracked instances.
///
/// Pairing: the Mac being added shows a 6-digit code. The other Mac sends its
/// Curve25519 public key with an HMAC of it keyed by the code; the reply does the
/// same. Both sides derive one shared key with ECDH + HKDF, so the key itself never
/// crosses the network. (A 6-digit code can be brute-forced offline by someone who
/// records the exchange; that's why the listener only accepts Tailscale by default,
/// whose traffic is already encrypted, and why codes expire and lock after 5 misses.)
///
/// Requests: each carries the sender's machine id, a timestamp and an HMAC-SHA256
/// over method, path, timestamp and body hash. Requests older than 2 minutes fail.
enum FleetAuth {
    static let machineHeader = "X-Cracked-Machine"
    static let timestampHeader = "X-Cracked-Timestamp"
    static let signatureHeader = "X-Cracked-Signature"
    static let maxClockSkew: TimeInterval = 120

    // MARK: - Pairing

    static func newPairingCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    /// Proof that the sender knows the code, bound to its public key and the other Mac's id.
    static func pairingProof(code: String, publicKey: Data, otherMachineID: String) -> Data {
        let key = SymmetricKey(data: Data("cracked-pair-v1:\(code)".utf8))
        var message = publicKey
        message.append(Data(otherMachineID.utf8))
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    static func verifyPairingProof(_ proof: Data, code: String, publicKey: Data, otherMachineID: String) -> Bool {
        let key = SymmetricKey(data: Data("cracked-pair-v1:\(code)".utf8))
        var message = publicKey
        message.append(Data(otherMachineID.utf8))
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: message, using: key)
    }

    /// The pair's shared key. Both sides get the same bytes regardless of who started.
    static func sharedKey(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublicKey: Data,
                          machineIDs: (String, String), code: String) throws -> Data {
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        let ids = [machineIDs.0, machineIDs.1].sorted().joined(separator: "|")
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("cracked-pair-v1:\(code)".utf8),
                                                 sharedInfo: Data(ids.utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    // MARK: - Request signing

    static func canonical(method: String, path: String, timestamp: String, body: Data) -> Data {
        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return Data("\(method.uppercased())\n\(path)\n\(timestamp)\n\(bodyHash)".utf8)
    }

    static func signature(key: Data, method: String, path: String, timestamp: String, body: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: canonical(method: method, path: path, timestamp: timestamp, body: body),
            using: SymmetricKey(data: key))
        return Data(mac).base64EncodedString()
    }

    /// Headers for a signed request from `machineID`.
    static func signedHeaders(machineID: String, key: Data, method: String, path: String,
                              body: Data, now: Date = Date()) -> [String: String] {
        let timestamp = String(Int(now.timeIntervalSince1970))
        return [
            machineHeader: machineID,
            timestampHeader: timestamp,
            signatureHeader: signature(key: key, method: method, path: path, timestamp: timestamp, body: body),
        ]
    }

    enum VerifyResult: Equatable {
        case ok(machineID: String)
        case unauthorized(String)
    }

    /// Checks a request's signature. `keyFor` looks up the shared key of a paired machine.
    static func verify(method: String, path: String, headers: [String: String], body: Data,
                       now: Date = Date(), keyFor: (String) -> Data?) -> VerifyResult {
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        guard let machine = header(machineHeader), let timestamp = header(timestampHeader),
              let signature = header(signatureHeader), let signatureData = Data(base64Encoded: signature) else {
            return .unauthorized("Missing signature")
        }
        guard let seconds = Double(timestamp), abs(now.timeIntervalSince1970 - seconds) <= maxClockSkew else {
            return .unauthorized("Request too old (check both Macs' clocks)")
        }
        guard let key = keyFor(machine) else { return .unauthorized("Not paired") }
        let valid = HMAC<SHA256>.isValidAuthenticationCode(
            signatureData,
            authenticating: canonical(method: method, path: path, timestamp: timestamp, body: body),
            using: SymmetricKey(data: key))
        return valid ? .ok(machineID: machine) : .unauthorized("Bad signature")
    }

    // MARK: - Who may connect

    enum NetworkScope: Sendable { case tailscaleOnly, tailscaleAndLAN }

    /// Tailscale (100.64.0.0/10, fd7a:115c:a1e0::/48) and loopback always; private LAN ranges if allowed.
    static func isAllowed(address rawAddress: String, scope: NetworkScope) -> Bool {
        var address = rawAddress.lowercased()
        if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
        if address.hasPrefix("::ffff:") { address.removeFirst("::ffff:".count) }

        if address == "::1" { return true }
        if address.hasPrefix("fd7a:115c:a1e0:") { return true }

        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            if octets[0] == 127 { return true }
            if octets[0] == 100, (64...127).contains(octets[1]) { return true }
            guard scope == .tailscaleAndLAN else { return false }
            if octets[0] == 10 { return true }
            if octets[0] == 172, (16...31).contains(octets[1]) { return true }
            if octets[0] == 192, octets[1] == 168 { return true }
            if octets[0] == 169, octets[1] == 254 { return true }
            return false
        }
        guard scope == .tailscaleAndLAN else { return false }
        return address.hasPrefix("fe80:") || address.hasPrefix("fc") || address.hasPrefix("fd")
    }
}
