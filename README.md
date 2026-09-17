<p align="center">
  <img src="AppIcon.png" width="112" alt="BarPilot app icon">
</p>

<h1 align="center">BarPilot</h1>

<p align="center">
  A native macOS menu-bar app for tracking GitHub Copilot usage and spend.
</p>

<p align="center">
  <img alt="macOS 13 or later" src="https://img.shields.io/badge/platform-macOS%2013.0%2B-brightgreen">
  <img alt="Apple silicon" src="https://img.shields.io/badge/Apple_Silicon-M1%2B-black?logo=apple&amp;logoColor=white">
  <img alt="Developer ID notarised" src="https://img.shields.io/badge/Notarised-Developer%20ID-success">
  <a href="https://github.com/vmlrodrigues/BarPilot/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/vmlrodrigues/BarPilot?label=latest"></a>
  <a href="LICENSE"><img alt="MIT licence" src="https://img.shields.io/badge/Licence-MIT-blue"></a>
</p>

<p align="center">
  <a href="https://github.com/vmlrodrigues/BarPilot/releases/latest/download/BarPilot.dmg"><img alt="Download BarPilot for Mac" src="https://img.shields.io/badge/Download_for_Mac-007AFF?style=for-the-badge&amp;logo=apple&amp;logoColor=white"></a>
</p>

BarPilot keeps the current Copilot billing cycle in the menu bar, with the full
breakdown one click away. It is built with SwiftUI and AppKit, contains no web
view, and stays out of the Dock. The dashboard keeps spend, budget progress and
daily activity primary; model prices, billing history and multi-Mac sync remain
close at hand without crowding the normal view.

Version **0.12.0** adds a complete billing-cycle activity chart, five-day recent
activity with scrollable history, cycle-specific historical budgets, stronger
multi-Mac recovery and sync validation, reliable model-price presentation after
long idle periods, and correct cycle projections while travelling.
See the [0.12.0 release notes](https://github.com/vmlrodrigues/BarPilot/releases/tag/v0.12.0).

> [!NOTE]
> BarPilot is an independent, unofficial tool. It is not made or endorsed by
> GitHub or Microsoft. Its primary dashboard uses an internal GitHub account
> endpoint that may change or stop working in a future GitHub release.

## What it shows

- Current billing-cycle credits and spend in USD or AUD, directly in the menu
  bar and in a compact dashboard.
- Monthly budget progress with an anchored cycle-end projection and the target
  that applied to each completed billing cycle.
- A full-cycle daily cost chart that keeps future days visible. Hover any bar or
  date for its exact observed credits and cost.
- The latest five active days at a glance, with the complete retained history
  still available by scrolling.
- Previous billing cycles with their own totals, daily activity and historical
  budget reference.
- Current GitHub Copilot model prices with search, provider filters, local
  favourites, workload comparison and sortable LM Arena community-preference
  rankings. The last valid catalogue remains available offline.
- Optional private-Gist sync that combines observations from multiple Macs
  without double-counting the account-wide total.
- Clear disconnected, stale and unavailable states while preserving the last
  trustworthy reading.
- A temporary, explicitly marked legacy telemetry view for per-model and
  per-session detail during the transition to GitHub-backed usage data.

The menu bar normally shows the current cycle's cost. A warning glyph appears
when GitHub is disconnected, stale or unavailable, so an incomplete local
fallback is never presented as current account data. Credits are shown to two
decimal places; 100 credits equal US$1.00.

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
offers **Connect GitHub**. Connection management also lives under
**Settings → GitHub**. Disconnecting removes only this credential; saved
observations and multi-machine sync remain intact.
Billing-cycle boundaries and daily activity are attributed in UTC so travelling
does not move usage between days or change historical periods. Reset times are
still displayed in the Mac's current local timezone.

Optional **Multi-Machine Sync** stores a compact versioned payload in a secret
gist. Each Mac publishes only observations it captured itself: 15-minute detail
for the live cycle and correction-aware daily boundaries for completed cycles,
plus the budget recorded for each cycle. Budget snapshots carry their actual
edit time and resolve simultaneous cross-Mac changes deterministically; ordinary
usage polling does not change their precedence. They are stored independently of
counter observations, so a budget can be changed and synced even when that cycle
has only been observed on another Mac.
Matching observations are unioned and de-duplicated, never summed, because every
Mac is observing the same account-wide counter. A key-derived account fingerprint
prevents observations from different Copilot accounts being merged. It is
deterministic (so Macs can match) but derived with PBKDF2, so it cannot be
enumerated back to the account it identifies.

Every sync validates the complete Gist before writing. When a durable database
identity shows that SQLite recreated the local store, the existing payload for
this Mac restores its saved observations and historical budget references. Gist
discovery is paginated, and the selected Gist id is retained per GitHub account
after simultaneous creators have converged on the oldest copy. The preflight
read also repairs a stale copy of this Mac's file and prevents an
older BarPilot build from overwriting a schema it does not understand. A fresh
matching observation from another Mac can drive the current dashboard when this
Mac missed a cycle rollover. The same validation and size limits apply before
upload and after download, including bounds on numeric fields and the complete
machine snapshot, so BarPilot never publishes a file it cannot consume. Cache
replacement runs outside the UI actor and late cache or budget writes are
discarded after sync or account generations change. Cached peer cycles are
recombined with local history regardless of which launch read finishes first.

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
./build-app.sh        # compiles, assembles, and stable-signs BarPilot.app when the project identity is installed
open BarPilot.app    # look for the $ amount in your menu bar
```

For interactive development, use the bundled build above so Keychain sees the
same signed application after every rebuild. `swift run` remains useful for the
headless verification and output modes, but launching the menu-bar UI that way
does not provide a stable app identity.

```sh
make local
make run
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
  ModelPricing.swift  Offline-first pricing catalogue client + interactive dialogue
  SyncAggregate.swift Versioned counter-observation + legacy sync payload
  GitHubBackend.swift Private-gist multi-machine sync transport
  DetailView.swift   Window UI: header, sparkline, budget bar, status footer
  Tabs.swift         Summary / Models / Daily / Sessions / Top tables
  Setup.swift        Native opt-in OTel telemetry enablement (the "Enable…" button)
  Dump.swift         Headless --dump output path
Info.plist           LSUIElement (menu-bar-only) agent bundle metadata
build-app.sh         Build + assemble the .app bundle
Scripts/model_pricing_catalog.py  Builds the price + community-preference contract
.github/workflows/publish-model-pricing.yml  Daily GitHub Pages catalogue pipeline
```

Pipeline details and local verification commands are documented in
[docs/model-pricing-catalog.md](docs/model-pricing-catalog.md).

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
- **Global shortcut:** record an optional system-wide key combination under
  **Settings → General** to toggle the usage window without Accessibility or
  Input Monitoring permission.
- **Start at Login:** toggle it under **Settings → General** to have BarPilot
  launch automatically when you log in.
- **Currency:** switch between **US $** and **Australian $** on the dashboard or
  under **Settings → Spending**.
  The USD→AUD rate is fetched from a public service on launch and refreshed daily
  (cached for offline use); your monthly budget stays in USD and is shown converted
  and rounded to a whole dollar when displaying AUD.
- **Model pricing:** open **Model prices…** from the dashboard header. BarPilot
  reads its versioned public catalogue from GitHub Pages, keeps the last valid
  response for offline use, and checks for a newer snapshot after 12 hours. The
  daily GitHub Actions job—not the app—fetches and exactly matches LM Arena's
  overall, text-style-controlled leaderboard. Favourite changes stay on the Mac
  and are never published or synced.
- **Left-click** the menu-bar icon to open the usage window; **right-click** (or
  control-click) it for a menu with **Open Usage Window**, **Refresh Now**,
  **Settings…**, **Check for Updates**, **What’s New**, **Save Diagnostics…**,
  and **Quit BarPilot**. (You can also quit from the button in the window footer.)

## License

BarPilot is released under the **MIT License** — see [LICENSE](LICENSE) for the
full text. Model-pricing data attribution is recorded in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Copyright (c) 2026 Victor Rodrigues
