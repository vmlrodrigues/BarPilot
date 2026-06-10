# BarPilot

![Platform](https://img.shields.io/badge/platform-macOS%2013.0%2B-brightgreen)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%2B-black?logo=apple&logoColor=white)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

[![Download for Mac](https://img.shields.io/badge/Download_for_Mac-007AFF?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/vmlrodrigues/BarPilot/releases/latest/download/BarPilot.dmg)

A macOS **menu-bar app** that shows your GitHub Copilot AIU credit **cost** for a
selected period at a glance. Click the menu-bar item to open a window with the
full breakdown — summary, models, daily, sessions, and top calls.

Written in **Swift / SwiftUI**, fully self-contained with **no external
dependencies**: it reads your local GitHub Copilot OTel telemetry directly off
disk — your usage data never leaves your machine. The only network access is
checking GitHub for app updates and fetching the USD→AUD exchange rate.

## What it shows

- **Menu bar:** `$ <total cost>` for the selected period, always visible.
- **Detail window** (click the menu-bar item):
  - Period selector — Today, Last 7 Days, This Month, Last 30 Days, This Year,
    All Time, or a custom date range.
  - Big total (cost + credits) and a daily-spend sparkline.
  - **Budget bar** for the *selected* period: you set one **monthly budget** in
    USD (from the menu-bar icon's right-click menu → **Set Monthly Budget…**);
    it's converted to a per-day rate and pro-rated across the days in the chosen
    span (so "Today" shows ~1/30th of it, "Last 7 Days" shows 7 days' worth,
    etc.). Shows spend vs budget and % used; the current monthly figure is
    displayed as "$150 / mo".
  - Tabs: **Summary** (by model), **Models** (with token breakdown), **Daily**,
    **Sessions**, **Top** (most expensive calls).
  - Footer shows each data source's status — **green** = data flowing,
    **orange** = telemetry enabled but no traces yet, **grey** = telemetry not
    enabled. If either source's OTel telemetry isn't configured, a warning with
    an **Enable…** button appears: it shows exactly what will change (VS Code
    `settings.json` keys; a Copilot LaunchAgent + helper script in `~/Library`),
    then configures it natively on your confirmation. After enabling, restart
    VS Code and relaunch the Copilot app.

Credits are shown to 2 decimal places; cost in your selected currency — USD by
default, or AUD (100 credits = $1.00 USD).

## Data sources

Both are read directly off disk, merged, and de-duplicated:

| Source | Format | Path |
|---|---|---|
| VS Code Copilot Chat | SQLite | `~/Library/Application Support/Code/User/globalStorage/github.copilot-chat/agent-traces.db` |
| GitHub Copilot Mac App | JSONL | `~/Library/Application Support/com.github.githubapp/agent-traces.jsonl` |

A source is silently skipped if its file is absent. Credits = `nano_aiu / 1e9`;
cost = `credits / 100` (100 credits = $1.00). Model names are normalised so
`claude-sonnet-4-6` (VS Code) and `claude-sonnet-4.6` (Mac App) merge.

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
  press the refresh button or change the period. Your period choice is remembered.
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
  **Set Monthly Budget…**, **Currency**, **Start at Login**, **Check for Updates**,
  and **Quit BarPilot**. (You can also quit from the button in the window footer.)

## License

BarPilot is released under the **MIT License** — see [LICENSE](LICENSE) for the
full text.

Copyright (c) 2026 Victor Rodrigues
