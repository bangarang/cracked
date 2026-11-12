import Foundation
import Testing
@testable import Cracked

@Suite("Rex")
struct RexTests {
    func processes(child: Int32?, foreground: Int32?) -> Rex.BlockProcesses {
        let json = """
            {"child": \(child.map { "{\"pid\": \($0), \"name\": \"login\"}" } ?? "null"),
             "foreground": \(foreground.map { "{\"pid\": \($0), \"name\": \"zsh\"}" } ?? "null"),
             "last_exit": null}
            """
        return try! JSONDecoder().decode(Rex.BlockProcesses.self, from: Data(json.utf8))
    }

    @Test("Recognises Rex Server, which hosts Rex's terminals")
    func server() {
        #expect(Rex.isServer(path: "/Users/me/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"))
        #expect(!Rex.isServer(path: "/Applications/Rex Beta.app/Contents/MacOS/Rex"))
        #expect(!Rex.isServer(path: nil))
    }

    @Test("Finds the block whose terminal runs the agent")
    func block() {
        // claude 500 → zsh 400 → login 300 → Rex Server 200
        let lineage: Set<Int32> = [500, 400, 300, 200]
        let blocks = [
            (id: "block:a", processes: processes(child: 111, foreground: 112)),
            (id: "block:b", processes: processes(child: 300, foreground: 500)),
        ]
        #expect(Rex.block(containing: lineage, in: blocks) == "block:b")
        #expect(Rex.block(containing: [999], in: blocks) == nil)
        #expect(Rex.block(containing: lineage, in: [(id: "block:c", processes: processes(child: nil, foreground: 400))]) == "block:c",
                "The foreground process alone is enough")
    }

    @Test("Shows a session by its ID, matching AppleScript's host-prefixed IDs")
    func showScript() {
        let script = Rex.showScript(session: "session:01a1a85b-4bca-7249-b87e-fda05122e4bf")
        #expect(script?.contains(#"show (first session whose id ends with "/session:01a1a85b-4bca-7249-b87e-fda05122e4bf")"#) == true)
        #expect(script?.contains(#"application id "com.superlogical.rex""#) == true)
        #expect(Rex.showScript(session: #"x" & do shell script "evil"#) == nil, "Never builds a script from odd input")
        #expect(Rex.showScript(session: "") == nil)
    }

    @Test("The CLI sits next to the server's executable")
    func cli() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cli = dir.appendingPathComponent("rex")
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        #expect(Rex.cliPath(serverPath: dir.appendingPathComponent("Rex Server").path) == cli.path)
        #expect(Rex.cliPath(serverPath: "/nonexistent/rex") == nil)
    }
}
