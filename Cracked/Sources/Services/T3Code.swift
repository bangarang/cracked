import Foundation
import AppKit
import GRDB

/// T3 Code, a desktop app that runs coding agents (Claude Code, OpenCode, Codex…) in
/// threads. Clicking one of its agents opens that thread with a `t3code://threads/…`
/// link, rather than just bringing T3 Code to the front.
enum T3Code {
    /// Release, Nightly and other builds all start with this.
    static let bundleIDPrefix = "com.t3tools.t3code"

    static func isT3Code(bundleID: String?) -> Bool {
        bundleID?.hasPrefix(bundleIDPrefix) ?? false
    }

    /// `~/.t3/userdata`, where T3 Code keeps its state.
    static var userDataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/userdata", isDirectory: true)
    }

    /// `t3code://threads/<environment>/<thread>` opens a thread in T3 Code.
    static func threadLink(environmentID: String, threadID: String) -> URL? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        guard let environment = environmentID.addingPercentEncoding(withAllowedCharacters: allowed),
              let thread = threadID.addingPercentEncoding(withAllowedCharacters: allowed),
              !environment.isEmpty, !thread.isEmpty else { return nil }
        return URL(string: "t3code://threads/\(environment)/\(thread)")
    }

    /// This Mac's T3 Code environment ID.
    static func environmentID(userData: URL = userDataDirectory) -> String? {
        guard let raw = try? String(contentsOf: userData.appendingPathComponent("environment-id"), encoding: .utf8)
        else { return nil }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// The T3 thread running a provider session: T3 Code records each provider's own
    /// session ID (Claude Code's session ID, OpenCode's `ses_…`) as the thread's native ID.
    static func threadID(providerSessionID: String, userData: URL = userDataDirectory) -> String? {
        let path = userData.appendingPathComponent("statev2.sqlite").path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(0.5)
        return try? DatabaseQueue(path: path, configuration: config).read { db in
            try String.fetchOne(db, sql: """
                SELECT thread_id FROM orchestration_v2_projection_provider_threads
                WHERE json_extract(payload_json, '$.nativeThreadRef.nativeId') = ? AND thread_id IS NOT NULL
                ORDER BY updated_at DESC LIMIT 1
                """, arguments: [providerSessionID])
        }
    }

    /// Opens the session's thread in the T3 Code build hosting it. Returns false when the
    /// thread can't be found, so the caller can fall back to bringing the app forward.
    @discardableResult
    static func open(sessionID: String, appBundlePath: String) -> Bool {
        guard let environment = environmentID(),
              let thread = threadID(providerSessionID: sessionID),
              let url = threadLink(environmentID: environment, threadID: thread) else { return false }
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: appBundlePath),
                                configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}
