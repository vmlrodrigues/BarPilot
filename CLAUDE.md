# BarPilot

A macOS **menu-bar app** (Swift / SwiftUI, SwiftPM, no Xcode) that shows your
GitHub Copilot AIU credit **cost** for a selected period in the menu bar; click
it for a detail window with the full breakdown (summary, models, daily, sessions,
top calls). Formerly named **TokenTally** — the app, bundle id, product/target,
and `Sources/` dir were all renamed to BarPilot; the folder was later renamed too.

It reads your local GitHub Copilot OTel telemetry directly off disk (**no
external dependencies**); network use is limited to the GitHub auto-updater and
the USD→AUD exchange-rate fetch.

## Build / run / verify

```sh
./build-app.sh                       # swift build -c release + assemble BarPilot.app
open BarPilot.app                    # look for the "$ <amount>" item in the menu bar
swift run BarPilot                   # dev run, no bundle
swift build                          # quick compile check
```

**Headless output (the key safety net):** the binary has a `--dump` mode that
prints the per-model summary as JSON on stdout. After any change to data loading
or aggregation, run it and sanity-check the totals against a known-good capture:

```sh
.build/release/BarPilot --dump --from 2026-06-01 --to 2026-06-10
```

`--dump` uses `Fmt.credits4` (4 dp) for exact parity; the UI shows 2 dp.
`--regular` runs as a normal foreground (Dock) app instead of a menu-bar agent.

Requires the Swift toolchain only (Command Line Tools is enough).

## The core invariant

**The aggregation rules below are exact and load-bearing — don't change them
casually.** When touching `Sources.swift` or `Aggregator.swift`, re-check the
totals with `--dump` against a known-good capture. The rules:

- credits = `nano_aiu / 1e9`; cost = `credits / 100` (100 credits = $1.00).
- **Range bounds are UTC** — from = `00:00:00.000Z`, to = `23:59:59.999Z`
  (`Aggregator.utcMidnightMs` + `86_399_999`).
- **Daily buckets use the LOCAL calendar date** (`localDayStr`) — distinct from
  the UTC range bounds above.
- **Model normalisation** merges VS Code vs Mac App punctuation: a *single*
  trailing `-<digit>` → `.<digit>` (so `claude-sonnet-4-6` ≡ `claude-sonnet-4.6`,
  but `...-2024-07-18` is untouched). See `Aggregator.normaliseModel`.
- **Dedup** by `spanId` (first occurrence wins; later duplicates ignored).
- Orchestration/agent spans (no model attribute) are **skipped** — their AIU
  duplicates the child LLM span's value.

## Data sources (read-only, both off the main actor)

| Source | Format | Path |
|---|---|---|
| VS Code Copilot Chat | SQLite (`import SQLite3`, read-only) | `~/Library/Application Support/Code/User/globalStorage/github.copilot-chat/agent-traces.db` |
| GitHub Copilot Mac App | JSONL | `~/Library/Application Support/com.github.githubapp/agent-traces.jsonl` |

A missing source file is silently skipped. The JSONL is 100 MB+, so it's
**memory-mapped** (`.mappedIfSafe`) and scanned in a single byte pass; only lines
containing the substring `aiu` are JSON-parsed. JSONL parsing handles both the
flat Mac-App span shape and the nested OTLP `resourceSpans` envelope. Full load
of both sources is well under a second.

## Architecture

```
Sources/BarPilot/
  App.swift          @main AppMain.main() → AppKit run loop; AppDelegate owns the
                     NSStatusItem + NSPopover(NSHostingController(DetailView)).
  Store.swift        UsageStore (@MainActor ObservableObject) — single source of
                     truth; loads once, re-aggregates on period change; 60s timer.
  Model.swift        Core types (UsageRecord, Report, *Row, PeriodKind) + Fmt.
  Sources.swift      DataSources — SQLite + mmap'd JSONL loaders; telemetry detect.
  Aggregator.swift   Aggregator + PeriodResolver — date-range & bucketing math.
  Dump.swift         Dump.run() — the --dump output path.
  DetailView.swift   Window UI: header, sparkline, budget bar.
  Tabs.swift         Summary / Models / Daily / Sessions / Top tables.
  Setup.swift        TelemetrySetup — opt-in native OTel enablement.
  Updater.swift      Silent GitHub-Releases auto-updater (Developer ID-gated).
  LoginItem.swift    "Start at Login" via SMAppService (macOS 13+).
  Currency.swift     USD/AUD display currency + live USD→AUD rate (open.er-api.com).
Info.plist           LSUIElement (menu-bar-only) agent bundle.
build-app.sh         Build + assemble + ad-hoc codesign the .app.
```

Data flow: `DataSources.loadAll()` (off-actor) → `UsageStore.allRecords` (cached
raw) → `Aggregator.build(...)` on every period change → `Report` → SwiftUI views.
Changing the period only re-aggregates cached records (instant); only the timer /
refresh / window-open re-reads disk.

## Design decisions — don't casually revert these (all user-chosen)

- **AppKit `NSStatusItem` + `NSPopover`, NOT SwiftUI `MenuBarExtra`** —
  MenuBarExtra is unreliable in a hand-assembled SwiftPM bundle. UI is still
  SwiftUI, hosted in the popover. Popover size is re-clamped to the screen's
  `visibleFrame` on each open so it never spills over the top.
- **Left-click** opens the window; **right-click / control-click** shows the menu
  (Open / Refresh / Set Monthly Budget… / Quit).
- **Budget = one editable monthly USD figure** (`monthlyBudgetUSD`, default $150
  ≈ $5/day), pro-rated to a per-day rate via `avgDaysPerMonth = 30.4375` and
  multiplied by the selected range's days. Edited via an NSAlert from the
  right-click menu (not an inline field); shown read-only as "$150 / mo".
- **Telemetry setup is opt-in and user-confirmed.** Detection is read-only; if a
  source isn't configured, the footer shows a warning + an **Enable…** button
  → confirm dialog → native config (patch VS Code `settings.json`; write a helper
  script 0755 + LaunchAgent in `~/Library`, `launchctl load`). Never automatic,
  never a startup prompt. All under `~/Library` — no admin/sudo.
- **Auto-update is a built-in GitHub-Releases updater (NOT Sparkle)** —
  `Updater.swift`. Silent: checks the Releases API, downloads the notarised DMG,
  verifies Team ID `9N354A3UZK` + Gatekeeper, swaps the bundle via a detached
  helper script, relaunches. Gated to Developer ID builds (`isDeveloperIDSigned`)
  so dev builds never self-update. Sparkle rejected as too heavy for a
  hand-assembled SwiftPM bundle. **The app now makes network calls** (GitHub) —
  keep the "no network for your *data*" wording accurate.
- **Start at Login** via `SMAppService.mainApp` (`LoginItem.swift`), toggled from
  the right-click menu — no third-party dependency.
- **Currency (USD/AUD):** everything is computed/stored in USD; AUD is a
  display-time conversion via a live rate (`Currency.swift`, open.er-api.com,
  fetched on launch + every 24h, cached in UserDefaults for offline use). The
  budget stays canonical USD (`monthlyBudgetUSD`); in AUD it's shown converted and
  rounded to a whole dollar (`budgetMoneyString`), and the budget dialog reads/writes
  in the displayed currency. `effectiveCurrency` falls back to USD if AUD is selected
  before a rate has loaded. All cost display goes through `Store.costString`.

## Gotchas

- On a Mac with a notch + crowded menu bar, macOS pushes overflow status items
  to the **left of the notch**; ⌘-drag repositions them. `pgrep -lf BarPilot`
  confirms it's running.
- All formatting goes through `Fmt` (Model.swift) — keep cost/credit/date output
  consistent by reusing it rather than ad-hoc `String(format:)`.
