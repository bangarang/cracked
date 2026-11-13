import Foundation

/// Connects Cracked to OpenCode (v2): a plugin in OpenCode's plugins folder reports
/// permission prompts and adds load warnings to new sessions, and an entry under
/// `mcp.servers` in `opencode.json` lets agents query Cracked.
///
/// Session titles and working / done / error states need no setup: they're read from
/// OpenCode's own database (see `OpenCodeAgents`).
enum OpenCodeSetup {
    static let mcpServerName = ClaudeCodeSetup.mcpServerName
    static let pluginFileName = "cracked.js"
    /// Marks a plugin file as Cracked's, so it's never mistaken for (or overwrites) someone else's.
    static let pluginMarker = "// cracked-opencode-plugin"

    static var executablePath: String { ClaudeCodeSetup.executablePath }

    /// `$XDG_CONFIG_HOME/opencode`, or `~/.config/opencode`.
    static func configDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        OpenCodeAgents.xdgDirectory("XDG_CONFIG_HOME", fallback: ".config", environment: environment)
    }

    /// Whether OpenCode looks installed: it has a config folder or a database.
    static var isDetected: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: configDirectory().path) || fm.fileExists(atPath: OpenCodeAgents.databaseURL.path)
    }

    // MARK: - MCP server (opencode.json)

    /// The config file to edit: `opencode.json`, or `opencode.jsonc` when that's the only one.
    static var configURL: URL {
        let dir = configDirectory()
        let json = dir.appendingPathComponent("opencode.json")
        let jsonc = dir.appendingPathComponent("opencode.jsonc")
        let fm = FileManager.default
        if !fm.fileExists(atPath: json.path), fm.fileExists(atPath: jsonc.path) { return jsonc }
        return json
    }

    static func mcpEntry(executable: String = executablePath) -> [String: Any] {
        ["type": "local", "command": [executable, "mcp"]]
    }

    /// Returns `config` with Cracked's MCP server under `mcp.servers` (other servers untouched).
    static func installingMCP(into config: [String: Any], executable: String = executablePath) -> [String: Any] {
        var config = config
        var mcp = (config["mcp"] as? [String: Any]) ?? [:]
        var servers = (mcp["servers"] as? [String: Any]) ?? [:]
        servers[mcpServerName] = mcpEntry(executable: executable)
        mcp["servers"] = servers
        config["mcp"] = mcp
        return config
    }

    static func removingMCP(from config: [String: Any]) -> [String: Any] {
        var config = config
        guard var mcp = config["mcp"] as? [String: Any] else { return config }
        if var servers = mcp["servers"] as? [String: Any] {
            servers[mcpServerName] = nil
            mcp["servers"] = servers.isEmpty ? nil : servers
        }
        config["mcp"] = mcp.isEmpty ? nil : mcp
        return config
    }

    static func hasMCP(in config: [String: Any]) -> Bool {
        ((config["mcp"] as? [String: Any])?["servers"] as? [String: Any])?[mcpServerName] != nil
    }

    static func readConfig() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: configURL), !data.isEmpty else { return [:] }
        // JSONC with comments isn't plain JSON; leave it alone rather than drop the comments.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SetupError.unreadableConfig(configURL.lastPathComponent)
        }
        return object
    }

    static func writeConfig(_ config: [String: Any]) throws {
        let fm = FileManager.default
        let url = configURL
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep the backup of the file as it was before Cracked first touched it.
        let backup = url.appendingPathExtension("cracked-backup")
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    static var isMCPInstalled: Bool {
        (try? hasMCP(in: readConfig())) ?? false
    }

    static func installMCP() throws {
        try writeConfig(installingMCP(into: readConfig()))
    }

    static func uninstallMCP() throws {
        let config = try readConfig()
        guard hasMCP(in: config) else { return }
        try writeConfig(removingMCP(from: config))
    }

    // MARK: - Plugin

    static var pluginURL: URL {
        configDirectory().appendingPathComponent("plugins", isDirectory: true).appendingPathComponent(pluginFileName)
    }

    static var isPluginInstalled: Bool {
        guard let source = try? String(contentsOf: pluginURL, encoding: .utf8) else { return false }
        return source.contains(pluginMarker) && source.contains(jsString(executablePath))
    }

    static func installPlugin() throws {
        let fm = FileManager.default
        if let existing = try? String(contentsOf: pluginURL, encoding: .utf8), !existing.contains(pluginMarker) {
            throw SetupError.foreignPlugin(pluginURL.path)
        }
        try fm.createDirectory(at: pluginURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pluginSource().write(to: pluginURL, atomically: true, encoding: .utf8)
    }

    static func uninstallPlugin() throws {
        guard let existing = try? String(contentsOf: pluginURL, encoding: .utf8),
              existing.contains(pluginMarker) else { return }
        try FileManager.default.removeItem(at: pluginURL)
        try? FileManager.default.removeItem(at: OpenCodeAgents.permissionsDirectory)
    }

    /// A JavaScript string literal.
    static func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    /// The plugin, a dependency-free ES module (OpenCode v2's `{ id, setup }` plugin shape).
    static func pluginSource(executable: String = executablePath,
                             pendingDirectory: URL = OpenCodeAgents.permissionsDirectory) -> String {
        """
        \(pluginMarker)
        // Cracked for OpenCode. Installed by Cracked (Settings → OpenCode, or `Cracked setup`);
        // `Cracked uninstall` removes it. Changes here are overwritten when Cracked reinstalls it.
        //
        // - Tells Cracked when a session is waiting for you (a permission decision, or a
        //   question the agent asked), so it shows up under Needs You. OpenCode keeps pending
        //   prompts in memory only.
        // - Tells Cracked which OpenCode server runs each session, so a session run by an app's
        //   own server (e.g. T3 Code) is shown with, and opens, that app.
        // - When this Mac is under heavy load, adds a short warning to each new session's
        //   system prompt ("load 46 on 16 cores · Xcode 140%"), decided once per session so
        //   the prompt stays the same (and cacheable) for the rest of it.

        import { execFile } from "node:child_process";
        import { mkdir, readdir, rm, writeFile } from "node:fs/promises";
        import { join } from "node:path";

        const CRACKED = \(jsString(executable));
        const PENDING_DIR = \(jsString(pendingDirectory.path));

        const SERVERS_DIR = join(PENDING_DIR, "servers");
        const safe = (id) => String(id).replace(/[^A-Za-z0-9_-]/g, "");
        // One file per prompt (<session>~<request>.json): a session can wait on several at once.
        const pendingFile = (sessionID, requestID) =>
          join(PENDING_DIR, safe(sessionID) + "~" + safe(requestID ?? "prompt") + ".json");
        const reported = new Set();

        async function running(sessionID) {
          if (!sessionID || reported.has(sessionID)) return;
          await mkdir(SERVERS_DIR, { recursive: true });
          await writeFile(join(SERVERS_DIR, safe(sessionID) + ".json"),
            JSON.stringify({ sessionID, pid: process.pid }));
          reported.add(sessionID);
        }

        export function permissionMessage(data) {
          if (data.message) return String(data.message).slice(0, 200);
          const what = [data.action, ...(data.resources ?? []).filter((r) => r && r !== "*")]
            .filter(Boolean).join(" ");
          return ("Waiting for permission" + (what ? ": " + what : "")).slice(0, 200);
        }

        async function waiting(sessionID, requestID, message) {
          if (!sessionID) return;
          await running(sessionID);
          await mkdir(PENDING_DIR, { recursive: true });
          await writeFile(pendingFile(sessionID, requestID), JSON.stringify({
            sessionID, requestID, message, askedAt: Date.now(), pid: process.pid,
          }));
        }

        export function formMessage(form) {
          const title = String(form.title ?? "").trim();
          return (title ? "Asks: " + title : "Waiting for your answer").slice(0, 200);
        }

        async function removeWhere(match) {
          const names = await readdir(PENDING_DIR).catch(() => []);
          await Promise.all(names.filter(match).map((name) => rm(join(PENDING_DIR, name), { force: true })));
        }
        /** One prompt answered. */
        const answered = (requestID) =>
          requestID ? removeWhere((name) => name.endsWith("~" + safe(requestID) + ".json")) : undefined;
        /** The turn ended: nothing in this session is waiting any more. */
        const cleared = (sessionID) =>
          sessionID ? removeWhere((name) => name.startsWith(safe(sessionID) + "~")) : undefined;

        // `Cracked status --brief` takes about 0.3 s; never hold up a session for long.
        const brief = () => new Promise((resolve) => {
          execFile(CRACKED, ["status", "--brief"], { timeout: 2000 }, (error, stdout) =>
            resolve(error ? "" : String(stdout).trim()));
        });

        export default {
          id: "cracked",
          setup: async (ctx) => {
            const briefs = new Map();
            await ctx.session.hook("context", async (input) => {
              try {
                let text = briefs.get(input.sessionID);
                if (text === undefined) {
                  text = brief();
                  briefs.set(input.sessionID, text);
                  if (briefs.size > 500) briefs.delete(briefs.keys().next().value);
                }
                const warning = await text;
                if (warning && Array.isArray(input.system)) input.system.push({ type: "text", text: warning });
              } catch {
                // Never get in the way of a session.
              }
            });

            const controller = new AbortController();
            (async () => {
              for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
                const data = event.data ?? {};
                try {
                  switch (event.type) {
                    case "session.execution.started": await running(data.sessionID); break;
                    case "permission.asked":
                      await waiting(data.sessionID, data.id, permissionMessage(data));
                      break;
                    case "form.created": {
                      const form = data.form ?? data;
                      await waiting(form.sessionID, form.id, formMessage(form));
                      break;
                    }
                    case "form.replied":
                    case "form.cancelled":
                      await answered(data.id ?? data.form?.id);
                      break;
                    case "permission.replied":
                      await (data.requestID ? answered(data.requestID) : cleared(data.sessionID));
                      break;
                    case "session.idle":
                    case "session.deleted":
                    case "session.execution.succeeded":
                    case "session.execution.failed":
                    case "session.execution.interrupted":
                      if (data.sessionID) await cleared(data.sessionID);
                      break;
                  }
                } catch {
                  // Cracked is a bystander: never get in OpenCode's way.
                }
              }
            })().catch(() => {});
            return () => controller.abort();
          },
        };

        """
    }

    enum SetupError: LocalizedError {
        case unreadableConfig(String)
        case foreignPlugin(String)

        var errorDescription: String? {
            switch self {
            case .unreadableConfig(let name):
                "OpenCode's \(name) isn't plain JSON (it may have comments), so Cracked left it alone. Add \"\(OpenCodeSetup.mcpServerName)\" under mcp.servers by hand: { \"type\": \"local\", \"command\": [\"\(OpenCodeSetup.executablePath)\", \"mcp\"] }"
            case .foreignPlugin(let path):
                "\(path) already exists and isn't Cracked's, so Cracked left it alone."
            }
        }
    }
}
