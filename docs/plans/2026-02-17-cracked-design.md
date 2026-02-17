# Cracked - macOS System Monitor Menu Bar App

## Overview

A lightweight macOS menu bar app that proactively monitors system resources, alerts about runaway processes and stale apps, and tracks humorous personal records for absurd system behavior.

**Name:** Cracked (cycling: blowing up on a climb; drums: snare crack; slang: absurdly impressive)

**Stack:** Swift, SwiftUI, MenuBarExtra, SQLite (GRDB.swift), UserNotifications, Swift Charts

**Target:** macOS 13+ (Ventura). Local-first, App Store eventually.

**Future:** Monitor layer is separated so it could be extracted into a Swift package or replaced with a Rust core for cross-platform (Linux) support via Tauri.

## Architecture

Single-process SwiftUI app with three layers:

```
┌─────────────────────────────────────────────┐
│  UI Layer (SwiftUI)                         │
│  ├ MenuBarExtra (icon + dropdown)           │
│  ├ Settings window                          │
│  └ Stats/Records window (Swift Charts)      │
├─────────────────────────────────────────────┤
│  Monitor Layer                              │
│  ├ ProcessMonitor (polls every 5-10s)       │
│  ├ AlertEngine (threshold checks)           │
│  └ RecordTracker (detects new "records")    │
├─────────────────────────────────────────────┤
│  Data Layer                                 │
│  ├ SQLite via GRDB.swift                    │
│  └ UserDefaults (settings/thresholds)       │
└─────────────────────────────────────────────┘
```

## Menu Bar Behavior

- **Default state:** Minimal monochrome icon (small gauge/meter shape). No color, no text.
- **Warning state (yellow):** Any process sustained >80% CPU for 30+ seconds, or system load average >8.
- **Critical state (red):** Any process sustained >100% CPU for 2+ minutes, load average >20, or memory pressure critical.
- Click to open dropdown.

## Dropdown View

```
┌──────────────────────────────────────────┐
│  🔴 Cracked                              │
├──────────────────────────────────────────┤
│  CPU Hogs                                │
│  ├ Comet Renderer      114%  ⏱ 12h [Kill]│
│  ├ Comet Renderer       63%       [Kill] │
│  └ Warp                 23%  ⏱ 22d [Kill]│
│                                          │
│  Stale Apps                              │
│  ├ Warp              22 days    [Restart] │
│  └ Spotify           22 days    [Restart] │
│                                          │
│  Load: 46.99 │ RAM: 125/128 GB           │
├──────────────────────────────────────────┤
│  🏆 New Record! 262 Comet processes      │
├──────────────────────────────────────────┤
│  Records & Stats...                      │
│  Settings...                             │
│  Quit                                    │
└──────────────────────────────────────────┘
```

## Notifications

- **High CPU alert:** "Comet Renderer is using 114% CPU for 5 minutes" with buttons: [Kill] [Dismiss]
- **Stale app alert:** "Warp has been running for 22 days" with buttons: [Restart] [Dismiss]
- **New record:** "New record! 262 Comet processes at once" with button: [View Stats]
- Configurable cooldown per-process (default: don't re-alert for same process within 15 min).

## Settings Window

- **Global defaults:** CPU threshold (default 80%), staleness threshold (default 7 days), poll interval (default 5s)
- **Per-app overrides:** Table where you set custom thresholds per app (e.g., Comet: 3 days staleness, auto-kill at 150% CPU)
- **Auto-kill whitelist:** Apps opted into auto-killing above their threshold
- **Launch at login** toggle

## Records & Stats Window

- **All-time records:** Most processes from one app, highest CPU spike, most RAM used by one app, longest app uptime
- **Trend charts (Swift Charts):** Daily peak CPU, daily peak RAM, daily process count -- rolling 30-day view
- **Hall of Shame:** Top 5 worst offenders by cumulative CPU time

## Data Model (SQLite)

```sql
snapshots (
    id              INTEGER PRIMARY KEY,
    timestamp       REAL NOT NULL,
    load_avg        REAL NOT NULL,
    total_processes INTEGER NOT NULL,
    memory_used_mb  INTEGER NOT NULL,
    memory_total_mb INTEGER NOT NULL
)

process_snaps (
    id              INTEGER PRIMARY KEY,
    snapshot_id     INTEGER NOT NULL REFERENCES snapshots(id),
    pid             INTEGER NOT NULL,
    app_name        TEXT NOT NULL,
    cpu_percent     REAL NOT NULL,
    memory_mb       INTEGER NOT NULL,
    uptime_seconds  INTEGER NOT NULL
)

records (
    id              INTEGER PRIMARY KEY,
    record_type     TEXT NOT NULL,
    value           REAL NOT NULL,
    app_name        TEXT,
    achieved_at     REAL NOT NULL,
    details         TEXT
)

app_configs (
    app_name        TEXT PRIMARY KEY,
    cpu_threshold   REAL,
    staleness_days  INTEGER,
    auto_kill       INTEGER NOT NULL DEFAULT 0
)
```

Snapshots are downsampled for long-term storage: per-minute for 24h, per-hour for 30 days, daily after that.
