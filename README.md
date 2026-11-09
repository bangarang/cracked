<p align="center">
  <img src="docs/assets/icon.png" width="160" alt="Cracked app icon: a gauge pegged so far past redline the glass has shattered">
</p>

<h1 align="center">Cracked</h1>

<p align="center">
  <strong>A menu bar system monitor for Macs that are absolutely cooking.</strong><br>
  It catches runaway processes, calls out apps you forgot to quit three weeks ago,<br>
  and keeps a trophy cabinet of your most unhinged system stats.
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111?logo=apple&logoColor=white">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/UI-SwiftUI-0A84FF">
  <img alt="Local-first" src="https://img.shields.io/badge/data-100%25%20local-30D158">
</p>

---

> **cracked** /krakt/ *adj.*
> 1. *Cycling:* completely blown up halfway up a climb.
> 2. *Drums:* the snap of a perfectly hit snare.
> 3. *Slang:* absurdly, unreasonably impressive. As in *"262 browser renderer processes? That's cracked."*

Your Mac is probably all three. Cracked sits in the menu bar and lets you know.

## Why

Activity Monitor tells you what's happening **right now**. It won't tell you that a browser renderer has been pinned at 114% CPU since Tuesday, that Warp has been up for 22 days, or that you just set a personal best of 161 open tabs.

Cracked does, at a glance, from one icon.

## Features

### 🚦 A menu bar icon that has a mood
A gauge that stays calm until things get spicy:

| State | Trigger |
| --- | --- |
| ⚪️ **Chill** | Everything's fine. Probably. |
| 🟡 **Warning** | An app is over your CPU threshold, or load average is above 8 |
| 🔴 **Cracked** | An app is above 100% CPU, or load average is above 20 |

### 🔥 CPU hogs, one click from dead
Click the icon to see which apps are eating your cores right now, with their icons and clean names. Each row has a **Kill** button.

### 🧟 Stale apps
Apps you launched and then left running for days. Cracked only counts apps you actually opened: it ignores the widget extensions, Spotlight indexers and helper processes macOS starts at login. Each one gets a **Restart** button.

### 📊 Tracked apps, Strava-style
Cracked counts what you're actually juggling and logs every **PR**:

- **Browser tabs**: Comet, Arc, Chrome
- **Cursor windows**
- **Claude Code sessions**
- **Warp tabs**

Every app gets a history chart and a PR badge with the date you set it. Beat your record of 161 tabs and you have a new PR. We're not judging. (We're judging a little.)

### 🏆 All-Time Records & the Hall of Shame
The **Records & Stats** window brings it all together:

- **Live system stats**: load, memory, process count
- **24-hour trend charts** for load average and memory, drawn with Swift Charts
- **All-Time Records**: highest CPU spike, most processes from a single app, most processes system-wide, and peak tabs, windows and sessions
- **Hall of Shame**: the five worst offenders by sustained CPU

### ⚙️ Tune it to your chaos
Set the CPU alert threshold, the stale-app threshold in days, the poll interval and the alert cooldown, and turn on launch at login.

## Privacy

Cracked is **100% local**. No accounts, no analytics, no network calls. Snapshots live in a SQLite database on your Mac and are automatically downsampled: per-minute for 24 hours, then per-hour for 30 days, then daily. A year of history takes up almost nothing.

## Install

Cracked isn't on the App Store yet, so build it from source. It takes about a minute.

**Requirements:** macOS 14 Sonoma or later, Xcode 26+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
git clone https://github.com/bangarang/cracked.git
cd cracked
brew install xcodegen
xcodegen generate

xcodebuild -project Cracked.xcodeproj -scheme Cracked -configuration Release \
  -derivedDataPath build build

cp -R build/Build/Products/Release/Cracked.app /Applications/
open /Applications/Cracked.app
```

Look for the gauge in your menu bar. Cracked runs as a menu bar–only app, so it has no Dock icon.

> **Tip:** if `xcodebuild` complains about Command Line Tools, point it at Xcode with
> `sudo xcode-select -s /Applications/Xcode.app`.

## Under the hood

```
┌───────────────────────────────────────────────┐
│  UI          SwiftUI · MenuBarExtra · Charts  │
├───────────────────────────────────────────────┤
│  Monitor     ProcessMonitor → AlertEngine     │
│                            → RecordTracker    │
├───────────────────────────────────────────────┤
│  Data        SQLite via GRDB · UserDefaults   │
└───────────────────────────────────────────────┘
```

- **`ProcessMonitor`** polls `ps`, `sysctl` and `vm_stat` off the main thread every few seconds
- **`AlertEngine`** applies the CPU, staleness and load thresholds, with per-process cooldowns
- **`RecordTracker`** notices when you've done something legendary and writes it down
- **`DatabaseManager`** runs GRDB migrations, stores snapshots and handles downsampling

The project is generated from [`project.yml`](project.yml). Run the tests with:

```bash
xcodebuild test -project Cracked.xcodeproj -scheme Cracked
```

## Roadmap

- [ ] Per-app threshold overrides
- [ ] Opt-in auto-kill for repeat offenders
- [ ] Signed and notarized release builds
- [ ] App Store release

---

<p align="center"><sub>Built by <a href="https://github.com/bangarang">bangarang</a> for Macs with 161 tabs open.</sub></p>
