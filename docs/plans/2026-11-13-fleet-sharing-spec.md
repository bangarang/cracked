# Cracked: Fleet, Sharing, Leaderboard and llama.cpp — Spec

**Date:** 2026-11-13
**Status:** Draft
**Builds on:** `agent-integration` (agent inbox, MCP server, Paseo/terminal agents, Ollama)

## Goals

1. **Share cards:** turn records and moments into images people actually want to post.
2. **Fleet:** the Mac mini, MacBook Pro (M4 Max) and MacBook Pro (M1 Max) see each other's state, agents and records, and agents can pick the least-loaded Mac.
3. **Public leaderboard:** opt-in, aggregates only, fair divisions by hardware.
4. **More local-model runtimes:** llama.cpp (`llama-server`) next to Ollama.

## Non-goals

- Cloud sync of history. Each Mac keeps its own SQLite; peers read each other on demand.
- Controlling another Mac's terminals (we can tell you *where* an agent is, not type into it).
- Anti-cheat beyond "honest people stay honest".
- Linux/Windows.

## Principles

- **Local by default.** Fleet and leaderboard are both off until turned on in Settings. With both off, Cracked makes no network calls except to model runtimes on `127.0.0.1`.
- **Two tiers of data.** *Private* (your own Macs): everything in `SystemReport`, including agent titles, cwd, app names. *Public* (cards, leaderboard): numbers, chip class and a fixed allowlist of app names. Nothing else ever leaves a Mac. This split lives in code as two separate types, not a filter on one.
- **No new dependencies** unless they clearly pay for themselves (Sparkle is the one exception).

---

## Phase 0 — Groundwork

### 0.1 Machine identity

New `MachineIdentity` (Models/MachineIdentity.swift):

| Field | Source |
| --- | --- |
| `id` | Random UUID generated on first launch, stored in UserDefaults. Not the hardware UUID, so it can't be used to fingerprint the Mac. |
| `name` | `SCDynamicStoreCopyComputerName` ("Alex's Mac mini"), user-overridable in Settings |
| `model` | `hw.model` (e.g. `Mac16,11`) |
| `chip` | `machdep.cpu.brand_string` ("Apple M4 Pro") |
| `cpuCores`, `perfCores` | `hw.ncpu`, `hw.perflevel0.physicalcpu` |
| `memoryGB` | `hw.memsize` |
| `chipClass` | Derived division: `M1`, `M1 Pro/Max/Ultra`, `M4 Pro`, `M4 Max`, … |
| `symbol` | SF Symbol for the form factor (`macmini`, `laptopcomputer`, `macstudio`) |

### 0.2 Schema migration `v3`

- Add `machineId TEXT` to `records`, `snapshots`, `tracked_app_snapshots`; backfill with the local id.
- Add new record types (see 1.3) alongside `peak_cpu`, `process_count`, `total_processes`.

### 0.3 Versioned report

- `SystemReport` gets `schemaVersion: Int` and `machine: MachineIdentity`.
- Decoding is tolerant: unknown fields ignored, new fields optional. Peers with a higher major version show as "update Cracked".

### 0.4 Releases

- Developer ID signing + notarization in a `scripts/release.sh` (xcodebuild archive → notarytool → staple → zip/dmg).
- Sparkle 2 for updates, appcast on GitHub Releases. Needed so three Macs (and leaderboard users) stay on compatible versions.

---

## Phase 1 — Share cards

### 1.1 Card types

| Card | Trigger | Headline example |
| --- | --- | --- |
| **PR card** | New record, or Share on any record in Records & Stats | "161 tabs · new PR" |
| **Right now** | "Brag" button in the menu footer | Gauge in current mood, load/core, RAM, top tracked counts |
| **Wrapped** | Weekly (Monday), and on demand | Week's peaks, worst offender, agent-hours, cracked score |
| **Fleet** (Phase 2) | Fleet section | All Macs side by side, "most cracked Mac this week" |

### 1.2 Rendering

- SwiftUI `CardView`s rendered with `ImageRenderer` at 2x, 1200×630 (OG/Twitter) and 1080×1350 (Instagram portrait).
- Visual system: dark background, the app-icon gauge as hero, monospaced numbers, mood colour (chill white / warning yellow / cracked red), a small "cracked" wordmark and date. Cracked-state cards get a shattered-glass overlay.
- Output: copy to clipboard, Save…, or `NSSharingServicePicker`.
- Notification for a new PR gets a **Share** action (`UNNotificationAction`).

### 1.3 New records (feed cards and leaderboard)

| Type | Value | Notes |
| --- | --- | --- |
| `peak_load_per_core` | load / cpuCores | Fair across machines |
| `peak_agents` | concurrent agent sessions (working+needsInput) | |
| `peak_local_model_gb` | GB of local models loaded at once | Ollama + llama.cpp |
| `zombie_score` | max(uptime days × GB) of a Worth a Restart app | "65 GB of Comet, 10 days" |
| `peak_tabs` etc. | already tracked via tracked apps | keep |

### 1.4 Cracked score

One number per machine per day/week, 0–1000, used on cards and the leaderboard. First cut:

```
score = 300·clamp(p95 load/core, 0, 3)/3
      + 200·fraction of samples with memory pressure ≥ warning
      + 200·log10(1 + peak tabs)/log10(1 + 500)
      + 200·min(peak agents, 20)/20
      + 100·min(zombie_score, 500)/500
```

Tunable; versioned (`scoreVersion`) so the leaderboard can reset when it changes.

### 1.5 Public payload type

```swift
struct PublicStats: Codable {
    let scoreVersion: Int
    let chipClass: String          // "M4 Max"
    let memoryGB: Int
    let cpuCores: Int
    let period: Period             // .now, .week(start), .allTime
    let crackedScore: Int
    let peakLoadPerCore: Double
    let peakTabs: Int?
    let peakAgents: Int?
    let peakLocalModelGB: Double?
    let zombie: Zombie?            // app name from allowlist only, days, GB
}
```

The allowlist: tracked apps (Comet, Arc, Chrome, Cursor, Warp, Paseo, Claude Code) plus a curated list of well-known apps by bundle id (Xcode, Slack, Docker, …). Anything else becomes "an app".

### 1.6 Acceptance

- [ ] Share from a record card, the footer and a PR notification.
- [ ] Card images contain nothing that isn't in `PublicStats` (unit test renders from `PublicStats` only; `CardView` can't take a `SystemReport`).
- [ ] Wrapped generated from the database for any past week.

---

## Phase 2 — Fleet

### 2.1 Transport

- **Listener:** `NWListener` (Network.framework) serving HTTP/1.1 + JSON. Port **47474** (configurable).
- **Bind:** Tailscale interface (100.64.0.0/10 and fd7a:115c:a1e0::/48) by default; optionally LAN too.
- **Discovery:**
  1. Tailscale: `tailscale status --json` (CLI at `/usr/local/bin/tailscale` or inside `Tailscale.app`), probe online macOS peers on 47474.
  2. Bonjour: advertise and browse `_cracked._tcp` on the LAN.
  3. Manual: add `host:port` in Settings.
- **Pairing:** first contact shows a 6-digit code on both Macs ("Pair MacBook Pro M4 Max?"). Confirming exchanges a 256-bit shared token per peer, stored in the Keychain. All requests carry `Authorization: Bearer <token>`. Unpaired requests get 401, except `GET /v1/hello`.
- **Freshness:** poll `/v1/report` every 10 s while the menu is open, every 60 s otherwise; `/v1/events` stays open for push.

### 2.2 API (v1)

| Method | Path | Returns |
| --- | --- | --- |
| GET | `/v1/hello` | `{machine, schemaVersion, appVersion, paired}` — no auth |
| POST | `/v1/pair` | Pairing handshake |
| GET | `/v1/report` | `SystemReport` |
| GET | `/v1/events` | Server-sent events: `agent` (status change), `record` (new PR), `pressure` (level change) |
| GET | `/v1/history?range=24h\|7d\|30d&series=load,memory` | Downsampled trend points |
| GET | `/v1/records` | Records with machine id |
| POST | `/v1/actions/unload-model` | `{runtime, model}` |
| POST | `/v1/actions/restart-app` | `{bundlePath}` — only apps currently in Worth a Restart |
| POST | `/v1/actions/snooze-app` | `{bundlePath, days}` |

Actions are off by default per peer ("Allow MacBook Pro to: unload models / restart apps").

### 2.3 Menu bar

- New **Fleet** section (only when ≥1 peer): one row per Mac with form-factor symbol, name, mood dot, load/core, RAM, and "last seen 3m" when stale. Click expands an inline mini report (hogs, models, agents).
- **Needs You** merges remote agents, labelled with the machine ("on MacBook Pro"). Clicking a remote Paseo agent opens it in Paseo (`paseo://` with the host); a remote terminal agent shows "Waiting on MacBook Pro · Ghostty".
- Menu bar badge counts waiting agents across the fleet. Setting: icon mood = this Mac only (default) or worst in fleet.
- Notifications for remote agents, deduplicated so only the Mac you're active on alerts (the peer reports `lastUserActivity` via `CGEventSourceSecondsSinceLastEventType`; the most recently active Mac claims the notification).

### 2.4 MCP and load warnings

- New tools: `fleet_status` (compact report per machine) and `least_loaded_machine` (ranked by load/core, memory pressure, then free RAM; includes the Paseo host name when known).
- SessionStart load warning adds a hint when this Mac is struggling and a peer is idle: *"load 46 on 16 cores · the Mac mini is idle (load 1.2 on 12)."*
- `Cracked status --fleet` in the CLI.

### 2.5 Fleet records

- Records window gets a machine picker (This Mac / each peer / All). "All" fetches `/v1/records` from each peer and merges.
- Fleet card (1.1) and a weekly "most cracked Mac" in Wrapped.

### 2.6 Acceptance

- [ ] Pair Mini ↔ M4 Max over Tailscale; each shows the other in Fleet within 10 s.
- [ ] A Claude Code session blocked on the M4 Max shows in Needs You on the Mini, with a notification on whichever Mac was used last.
- [ ] Unload an Ollama model on the M4 Max from the Mini (after allowing it).
- [ ] An agent on a loaded Mac gets a `least_loaded_machine` answer naming an idle peer.
- [ ] A peer going offline shows "last seen" and never blocks the menu (all peer calls are async with 2 s timeouts).

---

## Phase 3 — Public leaderboard

### 3.1 Backend

- Cloudflare Worker + D1, plus R2 for card images. Static site on Pages.
- `POST /api/submit` with `PublicStats`, signed by a per-install Ed25519 key (CryptoKit `Curve25519.Signing`); the public key is the install's identity. First submit claims a handle.
- `GET /api/board?division=M4%20Max&metric=crackedScore&season=2026-W46`
- `GET /u/<handle>`: profile with cards; OG image for link previews.

### 3.2 Rules

- Weekly seasons (ISO week) plus all-time.
- Divisions by `chipClass`; an "Open" division ranks everyone by load/core and score.
- Fleet category: sum or best of a user's linked installs (link by signing a "same owner" message from each install).
- Sanity bounds (e.g. load/core ≤ 20, tabs ≤ 5000), rate limit 1 submit/hour/install, handle profanity filter, report button.

### 3.3 Client

- Settings → Leaderboard: off by default; preview exactly what will be sent (the literal JSON); handle; auto-submit weekly or manual only.
- Privacy copy in README updated: "No network calls unless you turn on Fleet or the Leaderboard."

### 3.4 Acceptance

- [ ] With Leaderboard off, no request to the leaderboard host (test with a URLProtocol stub).
- [ ] Submitted body equals the preview byte-for-byte.
- [ ] Board renders per division and season; profile has a working OG card.

---

## Track L — llama.cpp support

### L.1 How llama.cpp differs from Ollama (for Cracked)

| | Ollama | llama.cpp `llama-server` |
| --- | --- | --- |
| Shape | One daemon, one port (11434) | Any number of processes, each on its own port (default **9931** in current builds; 8080 in older ones and most tutorials) |
| Discover | Fixed URL | Scan processes for `llama-server`, parse `--host`/`--port` (or `LLAMA_ARG_PORT`) from argv |
| List loaded | `GET /api/ps`: name, size, size_vram, expires_at | **Router mode** (no `-m`): `GET /models` → `data[].id`, `status.value` (`loaded`/`loading`/`sleeping`/`unloaded`/`downloading`), `memory.effective.devices[]` bytes. **Single-model mode**: `GET /props` → `model_path`, `is_sleeping`; `GET /slots` → `n_ctx`, `is_processing` |
| Memory | Reported by API | Router: `memory.effective` (model + context + compute per device). Single: process footprint (`proc_pid_rusage` `ri_phys_footprint`, which includes Metal allocations) |
| Busy? | Not exposed | `/slots` `is_processing`; `/metrics` (needs `--metrics`) gives tokens/s |
| Unload | `keep_alive: 0` | Router: `POST /models/unload {"model": id}`. Single: no API; only **Stop** (SIGTERM the process), behind a confirm |
| Idle unload | `expires_at` | `--sleep-idle-seconds` → `sleeping` status (weights freed) |
| Auth | None | Optional `--api-key`; `/health` is always open. With a key, Cracked shows the process and its footprint but no model details (it never reads keys out of argv) |

**Bottom line:** worth adding. Ollama is easier because it's one well-known daemon; llama.cpp is more work because instances are ad hoc, but people running it are exactly the "Mac is cooking" audience, and router mode now gives Cracked nearly everything Ollama does, plus live tokens/s.

### L.2 Design

- Generalise `LocalModels.swift` into a `ModelRuntime` protocol:

  ```swift
  protocol ModelRuntime: Sendable {
      static var id: String { get }                     // "ollama", "llama.cpp"
      static func instances(processes: [ProcessSnapshot]) -> [RuntimeInstance]
      static func loadedModels(_ instance: RuntimeInstance) async -> [LocalModel]?
      static func unload(_ model: LocalModel, on instance: RuntimeInstance) async -> UnloadResult
  }
  ```

- `LocalModel` gains `runtime`, `instancePort`, `status` (`loaded`/`loading`/`sleeping`), `isProcessing`, `tokensPerSecond?`, `pid?`, and `unloadKind` (`.unload` or `.stopProcess`).
- `LlamaCpp` runtime:
  1. Find `llama-server` processes; parse host/port; skip ones with `--api-key`/`--api-key-file` for detail calls.
  2. `GET /models`; if 200 with `data`, it's a router: list entries whose status isn't `unloaded`.
  3. Otherwise single-model: `/props` + `/slots`; model name = filename of `model_path`; size = process footprint.
  4. Poll with the same 2 s timeouts as Ollama; only while a process exists.
- UI: the Local Models row shows a small runtime tag (`ollama`, `llama.cpp :9931`), a spinner for `loading`, a moon for `sleeping`, and a flame when `is_processing`. Single-model rows show **Stop** instead of **Unload**.
- MCP/status/session brief include runtime and port.
- Later, same protocol: LM Studio (`lms ps` / its REST API), `mlx_lm.server`.

### L.3 Acceptance

- [ ] Router-mode server with two loaded models: both listed with effective memory; Unload frees one.
- [ ] Single-model `llama-server -m x.gguf --port 8080`: listed with footprint; Stop terminates it after confirm.
- [ ] Sleeping models show as sleeping and don't count toward "GB held".
- [ ] Parser tests from recorded JSON fixtures (like `LocalModelsTests`).

---

## Sequencing

1. Phase 0.1–0.3 (identity, migration, report version)
2. Track L (self-contained, small, useful now)
3. Phase 1 (cards, new records, score)
4. Phase 0.4 (signed releases + Sparkle) — before installing on the laptops for real
5. Phase 2 (fleet), in the order of 2.6's checklist
6. Phase 3 (leaderboard)

## Open questions

1. Tailscale-only for fleet by default, with LAN as opt-in? (Proposed: yes.)
2. Leaderboard identity: anonymous key + handle (proposed), or GitHub sign-in?
3. Domain for the leaderboard site.
4. Should the menu bar icon reflect the worst Mac in the fleet, or this Mac only? (Proposed: this Mac, setting for fleet.)
5. Confirm `rockbook-pro` = M4 Max and `rocks-macbook-pro` = M1 Max; the latter hasn't been on Tailscale for 25 days.
