import Foundation
import GRDB
import Testing
@testable import Cracked

@Suite("T3 Code")
struct T3CodeTests {
    @Test("Recognises every T3 Code build")
    func bundleIDs() {
        #expect(T3Code.isT3Code(bundleID: "com.t3tools.t3code"))
        #expect(T3Code.isT3Code(bundleID: "com.t3tools.t3code.nightly"))
        #expect(!T3Code.isT3Code(bundleID: "com.mitchellh.ghostty"))
        #expect(!T3Code.isT3Code(bundleID: nil))
    }

    @Test("Thread links use T3 Code's threads route")
    func link() {
        #expect(T3Code.threadLink(environmentID: "dfa6d079", threadID: "1060a4da")?.absoluteString
                == "t3code://threads/dfa6d079/1060a4da")
        #expect(T3Code.threadLink(environmentID: "a/b", threadID: "c")?.absoluteString == "t3code://threads/a%2Fb/c")
        #expect(T3Code.threadLink(environmentID: "", threadID: "c") == nil)
    }

    @Test("Finds the thread running a Claude Code or OpenCode session")
    func threadLookup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("env-1\n".utf8).write(to: dir.appendingPathComponent("environment-id"))
        let db = try DatabaseQueue(path: dir.appendingPathComponent("statev2.sqlite").path)
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE orchestration_v2_projection_provider_threads (
                  provider_thread_id TEXT PRIMARY KEY, thread_id TEXT, provider TEXT NOT NULL,
                  status TEXT NOT NULL, updated_at TEXT NOT NULL, payload_json TEXT NOT NULL)
                """)
            func insert(_ id: String, thread: String?, native: String, updated: String) throws {
                try db.execute(sql: """
                    INSERT INTO orchestration_v2_projection_provider_threads VALUES (?, ?, 'claudeAgent', 'active', ?, ?)
                    """, arguments: [id, thread, updated, #"{"nativeThreadRef":{"nativeId":"\#(native)"}}"#])
            }
            try insert("p1", thread: "thread-old", native: "8725e0e0", updated: "2026-11-01T00:00:00Z")
            try insert("p2", thread: "thread-new", native: "8725e0e0", updated: "2026-11-12T00:00:00Z")
            try insert("p3", thread: "thread-oc", native: "ses_abc", updated: "2026-11-12T00:00:00Z")
            try insert("p4", thread: nil, native: "orphan", updated: "2026-11-12T00:00:00Z")
        }
        try db.close()

        #expect(T3Code.environmentID(userData: dir) == "env-1")
        #expect(T3Code.threadID(providerSessionID: "8725e0e0", userData: dir) == "thread-new", "The latest thread wins")
        #expect(T3Code.threadID(providerSessionID: "ses_abc", userData: dir) == "thread-oc")
        #expect(T3Code.threadID(providerSessionID: "orphan", userData: dir) == nil)
        #expect(T3Code.threadID(providerSessionID: "unknown", userData: dir) == nil)
        #expect(T3Code.threadID(providerSessionID: "x", userData: dir.appendingPathComponent("missing")) == nil)
    }
}
