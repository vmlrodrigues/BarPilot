# BarPilot

![Platform](https://img.shields.io/badge/platform-macOS%2013.0%2B-brightgreen)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%2B-black?logo=apple&logoColor=white)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

[![Download for Mac](https://img.shields.io/badge/Download_for_Mac-007AFF?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/vmlrodrigues/BarPilot/releases/latest/download/BarPilot.dmg)

A macOS **menu-bar app** that shows your GitHub Copilot AIU credit **cost** at a
glance. Click the menu-bar item to open a compact current-cycle dashboard with
credits, USD and AUD values, budget progress, and an observed daily-usage chart.

Written in **Swift / SwiftUI**, fully self-contained with **no external
dependencies**. The primary dashboard stores GitHub’s account credit counter
locally; the deprecated detail view reads Copilot OTel telemetry directly from
disk. Network access is limited to GitHub authentication and credit totals,
optional private-gist sync, app updates, and the USD→AUD exchange-rate fetch.

## What it shows

- **Menu bar:** `$ <total cost>` for the current month, always visible. A warning
  glyph indicates that GitHub is disconnected, stale, or unavailable and the
  displayed figure may be the incomplete local fallback.
- **Detail window** (click the menu-bar item):
  - Current billing-cycle credits and their value in both USD and AUD.
  - A daily credit-usage bar chart built from persisted GitHub samples.
  - An observed daily-spend table. Opening usage and unsampled growth crossing a
    UTC day boundary remain separate rather than being assigned without evidence.
  - **Monthly budget bar:** set one USD budget from the menu-bar icon's
    right-click menu → **Set Monthly Budget…**. The bar shows current spend,
    projected month-end spend, and the budget marker. Its label uses the selected
    display currency while calculations remain canonical in USD. The 100% budget
    marker sits at 70% of the track, leaving visible room to measure projections
    up to roughly 143% of budget.
  - A temporary **legacy telemetry** view retains Summary, Models, Daily,
    Sessions, and Top during the transition. It is explicitly marked incomplete
    and scheduled for removal.
  - A first-run **Connect GitHub** card authenticates the current-cycle account
    counter. BarPilot does not interrupt startup with a sign-in dialog; the
    dashboard remains usable with its temporary local fallback until connected.
  - The legacy footer shows each telemetry source's status — **green** = data flowing,
    **orange** = telemetry enabled but no traces yet, **grey** = telemetry not
    enabled. If either source's OTel telemetry isn't configured, a warning with
    an **Enable…** button appears: it shows exactly what will change (VS Code
    `settings.json` keys; a Copilot LaunchAgent + helper script in `~/Library`),
    then configures it natively on your confirmation. After enabling, restart
    VS Code and relaunch the Copilot app.

Credits are shown to 2 decimal places; cost in your selected currency — USD by
default, or AUD (100 credits = $1.00 USD).

> [!NOTE]
> **On first launch the menu-bar icon may not be visible if your menu bar is
> already full.** macOS inserts new status items toward the **left/centre (by the
> notch)**, where a crowded bar — especially on a notched Mac — can push them out
> of sight. The simplest fix is a free menu-bar manager like
> **[Ice](https://github.com/jordanbaird/Ice)**, which lets you see and rearrange
> hidden items:
>
> ```sh
> brew install jordanbaird-ice@beta
> ```
>
> Use the **`@beta`** build — the current stable release has a bug on macOS **Tahoe**.
>
> Once Ice is installed, run this to enable the **Always Hidden** section (it is off
> by default), then relaunch Ice:
>
> ```sh
> defaults write com.jordanbaird.Ice EnableAlwaysHiddenSection -bool true
> ```
>
> BarPilot will appear in the **Always Hidden** section. Open Ice → **Settings →
> Menu Bar Layout** and drag BarPilot up into the **Visible** section.

## Credit data

The primary dashboard polls GitHub’s authenticated account counter once a minute
and stores each successful cumulative observation in the local SQLite database.
Daily usage is derived from counter increases: observations from the same UTC day
can be assigned to that day, while an unsampled increase crossing a day boundary
remains unallocated. Failed polls never write a zero.

GitHub connection is the dashboard’s normal setup state, not an optional usage
mode. If no credential is available, the window explains the local fallback and
offers **Connect GitHub**. The right-click menu provides the secondary
**Connect GitHub…** or **Disconnect GitHub** account action. Disconnecting removes
only this credential; saved observations and multi-machine sync remain intact.

Optional **Multi-Machine Sync** stores a compact versioned payload in a secret
gist. Each Mac publishes only observations it captured itself: every counter
cycle’s first observation captured in each 15-minute interval.
Matching observations are unioned and de-duplicated, never summed, because every
Mac is observing the same account-wide counter. An opaque account fingerprint
prevents observations from different Copilot accounts being merged.

## Legacy telemetry sources

The deprecated detail view reads these attribution sources directly off disk:

| Source | Format | Path |
|---|---|---|
| VS Code Copilot Chat | SQLite | `~/Library/Application Support/Code/User/globalStorage/github.copilot-chat/agent-traces.db` |
| GitHub Copilot Mac App | JSONL | `~/Library/Application Support/com.github.githubapp/agent-traces.jsonl` |

**Copilot for Xcode and JetBrains IDEs (Android Studio, IntelliJ, etc.) are not supported** — those clients do not write local OTel telemetry to disk. Support will follow if GitHub adds it.

A source is silently skipped if its file is absent. Credits = `nano_aiu / 1e9`;
cost = `credits / 100` (100 credits = $1.00). Model names are normalised so
`claude-sonnet-4-6` (VS Code) and `claude-sonnet-4.6` (Mac App) merge.

The account endpoint is internal and unsupported. Local telemetry remains
available temporarily as a fallback and for the explicitly marked legacy view.

The JSONL file is large (100 MB+), so it's memory-mapped and scanned in a single
pass — only the few hundred lines carrying a usage attribute are JSON-parsed.
A full refresh of both sources takes well under a second.

## Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon Mac — any M-series chip (M1 or later). Intel Macs are not supported.

## Build & run

Requires the Swift toolchain (Command Line Tools are enough — **no full Xcode
needed**).

```sh
./build-app.sh        # compiles with SwiftPM and assembles BarPilot.app
open BarPilot.app    # look for the $ amount in your menu bar
```

To run during development without bundling:

```sh
swift run BarPilot
```

### Headless output

The binary has a `--dump` mode that prints the per-model summary as JSON — handy
for scripting or regression-checking the aggregation:

```sh
.build/release/BarPilot --dump --from 2026-06-01 --to 2026-06-10
```

## Project layout

```
Sources/BarPilot/
  App.swift          Entry point (@main) + AppKit NSStatusItem & NSPopover host
  Store.swift        UsageStore — loads, caches, re-aggregates, 60s refresh
  Model.swift        Core types + formatting helpers
  Sources.swift      SQLite + memory-mapped JSONL loaders; telemetry detection
  Aggregator.swift   Date-range math, model normalisation, per-view rows
  CreditUsage.swift  GitHub account-counter client + defensive response parser
  CreditSamples.swift Persistent cumulative credit samples
  CreditTimeline.swift Conservative daily sample projection
  CreditReconciliation.swift Server total + local attribution overlay
  CompactDashboard.swift Primary current-cycle dashboard + legacy transition
  SyncAggregate.swift Versioned counter-observation + legacy sync payload
  GitHubBackend.swift Private-gist multi-machine sync transport
  DetailView.swift   Window UI: header, sparkline, budget bar, status footer
  Tabs.swift         Summary / Models / Daily / Sessions / Top tables
  Setup.swift        Native opt-in OTel telemetry enablement (the "Enable…" button)
  Dump.swift         Headless --dump output path
Info.plist           LSUIElement (menu-bar-only) agent bundle metadata
build-app.sh         Build + assemble the .app bundle
```

## Can't find the menu-bar icon?

The item shows a **`$` (dollar-circle) icon + the amount** (e.g. `$21.16`). On a
Mac with a **notch** and a **crowded menu bar**, macOS places overflow status
items to the **left of the notch** (left-of-centre) rather than on the right by
the clock — so look there too. You can **⌘-drag** any menu-bar icon to reposition
it (even across the notch) to wherever you like, or quit a few other menu-bar
apps to free up space on the right.

If you truly see nothing, confirm it's running: `pgrep -lf BarPilot`.

## Notes

- The app refreshes automatically every 60 seconds, on window open, and when you
  press the refresh button. The legacy view remembers its selected period.
- **Auto-update:** BarPilot checks GitHub for a newer release shortly after launch
  and every few hours. When one is found it downloads the notarised DMG, verifies
  it's signed by the same developer, then installs it and relaunches — silently, in
  the background. (Only Developer ID release builds self-update; dev builds don't.)
- **Start at Login:** toggle it from the right-click menu to have BarPilot launch
  automatically when you log in.
- **Currency:** show costs in **US $** or **Australian $** (right-click → Currency).
  The USD→AUD rate is fetched from a public service on launch and refreshed daily
  (cached for offline use); your monthly budget stays in USD and is shown converted
  and rounded to a whole dollar when displaying AUD.
- **Left-click** the menu-bar icon to open the usage window; **right-click** (or
  control-click) it for a menu with **Open Usage Window**, **Refresh Now**,
  **Set Monthly Budget…**, **Currency**, **Start at Login**, **GitHub Credit
  Total**, **Check for Updates**, and **Quit BarPilot**. (You can also quit from
  the button in the window footer.)

## License

BarPilot is released under the **MIT License** — see [LICENSE](LICENSE) for the
full text.

Copyright (c) 2026 Victor Rodrigues
