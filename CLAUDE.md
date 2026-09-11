# BarPilot

A macOS **menu-bar app** (Swift / SwiftUI, SwiftPM, no Xcode) that shows your
GitHub Copilot AIU credit **cost** for a selected period in the menu bar; click
it for a detail window with the full breakdown (summary, models, daily, sessions,
top calls). Formerly named **TokenTally** — the app, bundle id, product/target,
and `Sources/` dir were all renamed to BarPilot; the folder was later renamed too.

It reads your local GitHub Copilot OTel telemetry directly off disk (**no
external dependencies**); network use is limited to the GitHub auto-updater and
the USD→AUD exchange-rate fetch.

## Issue tracking

**Every enhancement/feature and every bug gets a GitHub issue — always.** Even for
a small change requested in chat, open an issue first (label `enhancement` or
`bug`), reference it from the work, and close it when the fix ships, noting the
version (e.g. "shipped in v0.7.1"). This keeps a complete, searchable trail from
request → change → release. The repo is **public** — never put usernames, local
paths, or emails in issues.

### Public-repository privacy

**Treat every GitHub issue, comment, commit message, PR, log excerpt, and checked-in
file as public.** Never publish personal or account-identifying information,
including names, usernames, emails, organisation names, local filesystem paths,
hostnames, account identities, authentication sources, token details/scopes, or
private usage figures. Describe authentication and testing generically, sanitize
examples, and inspect the exact text before every GitHub write. If private context
is accidentally published, edit or delete it immediately rather than explaining
it in another public comment.

## Release checklist

Before running `make release VERSION=x.y.z`:
1. Update `VERSION` with the new version number.
2. **Update `CHANGELOG.md`** — change `[Unreleased]` to `[x.y.z] — YYYY-MM-DD` and
   add a new `## [Unreleased]` section at the top for future changes.
3. Commit both files on the feature branch, merge to `main`, then release.

`make dmg VERSION=x.y.z` runs the identical build/sign/notarise/staple pipeline but
stops before tagging and publishing, so you can install the artifact on a second Mac
and test the upgrade before anyone else receives it. `make release` depends on `dmg`,
so the tested binary and the published one are produced the same way. Note `release`
pushes **main** — merge first.

## Build / run / verify

```sh
./build-app.sh                       # release compile + assemble + stable local signing when available
open BarPilot.app                    # look for the "$ <amount>" item in the menu bar
make local && make run               # preferred interactive dev workflow (stable Keychain identity)
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

Other headless modes — run the relevant ones after touching their area:

| Flag | Checks |
|---|---|
| `--verify-incremental` | incremental JSONL reads never lose/duplicate a record (#24) |
| `--verify-watchdog` | exporter-heartbeat rules: warn only when running-but-not-writing (#27) |
| `--verify-projection` | spend-projection run-rate math + guards (#18) |
| `--verify-sync` | v3 sync payload, account isolation, remote gap-fill, legacy fit |
| `--verify-credits` | server-counter parsing, current-cycle guards, and unclassified reconciliation (#33) |
| `--verify-wake-refresh` | visible-wake freshness and bounded retry rules (#39) |
| `--verify-shortcut` | global shortcut validation and persistence encoding (#40) |
| `--sync-preview` | combined multi-machine view vs a simulated second machine |
| `--diagnose` | support report: state, a timed load, recent reload log |

Every `--verify-*` command exits nonzero when any assertion fails. `make verify`
also runs the projection verifier under Los Angeles and Auckland timezones to
catch UTC/local-date regressions that the host timezone would otherwise hide.

`--diagnose` is the one to ask a **user** to run (from the installed bundle, so it
reads the right Info.plist and preferences):

```sh
/Applications/BarPilot.app/Contents/MacOS/BarPilot --diagnose
```

It prints counts/sizes/durations only — no usage content — with home-relative
paths, so output is safe to paste into the public repo. Runtime history comes from
`DiagLog` (`~/Library/Logs/BarPilot/barpilot.log`, one line per reload, rotated at
256 KB × 2 files so it can never grow unbounded).

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
- Orchestration/agent spans are **skipped** — their AIU duplicates the child LLM
  span's value, so counting them double-counts. Two shapes: spans with **no model
  attribute**, and **`invoke_agent` rollup spans** (which *do* carry a model, but
  whose AIU is the sum of the child chat calls). Both are excluded — at parse time
  (`Sources.parseJSONLLine`) and again at cache-load (`SpanCache.load` filters out
  `op_name LIKE 'invoke_agent%'`), so historical cached rollups stop counting too.

When GitHub is connected, a second invariant overlays this local report for the
current UTC billing cycle:

- `headline total = max(GitHub cumulative counter, locally classified credits)`.
- `unclassified = max(0, GitHub counter - locally classified credits)`.
- Unclassified credits are never distributed across known models, days, sessions,
  or calls. Summary / Models show a separated final bucket; Daily / Sessions / Top
  remain local and classified-only.
- The opening sample is attributed to the connected account and joins that
  account's existing history; it does not establish a visibility boundary.
  Cumulative samples are not converted into daily rows because gaps cannot be
  assigned to a day reliably.
- Billing-cycle budgets are first-class records, independent of counter samples.
  New samples still carry the value for compatibility, while historical cycles
  use the cycle record. A one-time migration repair may fill the immediately
  preceding missed cycle, but ordinary historical budgets are not editable and
  older missing snapshots remain unknown.
- Disconnecting removes only the credential. Stored samples, the account
  attribution on them, and sync authorization are all left intact, so
  reconnecting restores the existing history rather than starting a new one.
- Failed polls are not persisted as zero. The last good sample remains available,
  and ranges outside the provable current-cycle window retain local totals.
- Run `--verify-credits` after changing any of this reconciliation behavior.

## Data sources (read-only, both off the main actor)

| Source | Format | Path |
|---|---|---|
| VS Code Copilot Chat | SQLite (`import SQLite3`, read-only) | `~/Library/Application Support/Code/User/globalStorage/github.copilot-chat/agent-traces.db` |
| GitHub Copilot Mac App | JSONL | `~/Library/Application Support/com.github.githubapp/agent-traces.jsonl` |

A missing source file is silently skipped. Only lines containing the substring
`aiu` are JSON-parsed; parsing handles both the flat Mac-App span shape and the
nested OTLP `resourceSpans` envelope.

**The JSONL is read INCREMENTALLY — don't regress this.** It's append-only and
grows without bound (multi-GB in practice), so re-scanning it on every 60s reload
cost seconds of CPU and pegged machines (#23/#24). `loadJSONL(path:from:)` resumes
from a byte offset persisted in the cache's `meta` table
(`DataSources.jsonlOffsetKey`), scanning only the appended tail — ~1.8 GB/7s
becomes ~KB/50ms. Rules:

- The offset only ever advances to the **last complete newline**; a partially
  written trailing line is left for the next read (consuming it would drop that
  record permanently).
- A file smaller than the stored offset means rotation/truncation → full re-scan
  from 0. The first run after upgrading also does one full scan.
- Full scans still **memory-map** (`.mappedIfSafe`); incremental tail reads use a
  plain `FileHandle`.
- Verify with `--verify-incremental` after touching any of it.

Badge counts in `SourcesStatus` come from the **cache** (`SpanCache.countsBySource`),
not the live read — a reload normally sees 0 new records.

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
  CreditUsage.swift  Defensive `/copilot_internal/user` client + response model.
  CreditSamples.swift  SQLite persistence for cumulative account-counter samples.
  CreditTimeline.swift  Conservative observed daily counter deltas.
  CreditReconciliation.swift  Pure server-total/local-attribution overlay.
  Dump.swift         Dump.run() — the --dump output path.
  DetailView.swift   Window UI: header, sparkline, budget bar.
  CompactDashboard.swift  Primary server-first dashboard and chart.
  SettingsView.swift  Settings window (budget, currency, GitHub, sync, general).
  GlobalShortcut.swift  Persisted shortcut + Carbon hot-key registration/recorder.
  Tabs.swift         Summary / Models / Daily / Sessions / Top tables.
  Setup.swift        TelemetrySetup — opt-in native OTel enablement.
  Updater.swift      Silent GitHub-Releases auto-updater (Developer ID-gated).
  LoginItem.swift    "Start at Login" via SMAppService (macOS 13+).
  Currency.swift     USD/AUD display currency + live USD→AUD rate (open.er-api.com).
  ExporterHealth.swift  Watchdog: Copilot app running but its JSONL not growing
                     ⇒ its exporter is dead (the app heartbeats ~1.5 KB/10s even
                     when idle, so this needs no guess about user activity).
  DiagLog.swift      Size-capped rotating support log (one line per reload).
  Diagnose.swift     Diagnose.run() — the --diagnose support report.
Info.plist           LSUIElement (menu-bar-only) agent bundle.
build-app.sh         Build + assemble + stable-sign locally (ad-hoc fallback for contributors).
```

Primary data flow: `CreditUsageAPI` → `CreditSampleStore` → local observations +
matching `MachineSyncPayload` observations → `CreditTimeline` →
`CompactDashboard`. Account counters are unioned and deduplicated, never summed.

Legacy data flow: `DataSources.loadAll()` (off-actor) → `UsageStore.allRecords`
(cached raw) → `Aggregator.build(...)` on every period change → local `Report` →
`CreditReconciliation.build(...)` → deprecated telemetry views. The reconciliation
overlay never mutates local aggregation.

The daily-cost chart expands sparse observations into every UTC day in the
selected billing cycle, including future placeholders, so its geometry does not
grow through the month. Recent activity shows five rows at once but retains all
stored completed-cycle rows in its own scrollable history; historical cycle
selection narrows the list back to that selected cycle. The production popover
uses 806 points as its comfortable viewport but always clamps to the usable
screen, including displays shorter than the old minimum. The main content
scrolls independently of the pinned footer, and owns an explicit 16-point
bottom inset so card and footer borders cannot collide. Chart hover content is
drawn in `chartOverlay`, never as a mark annotation: annotations alter Swift
Charts’ plot-area geometry when an edge bar is selected. Hovering any chart
column or date reveals that day’s date, credits and display-currency cost.

## Design decisions — don't casually revert these (all user-chosen)

- **AppKit `NSStatusItem` + `NSPopover`, NOT SwiftUI `MenuBarExtra`** —
  MenuBarExtra is unreliable in a hand-assembled SwiftPM bundle. UI is still
  SwiftUI, hosted in the popover. Popover size is re-clamped to the screen's
  `visibleFrame` on each open so it never spills over the top.
- **Left-click** opens the window; **right-click / control-click** shows the menu.
  The primary action acts on left mouse-down and validates the event's source
  window, then defers presentation to the next main-loop turn so AppKit has
  finished its status-button tracking session. Do not move it back to left
  mouse-up or present synchronously during mouse-down: either can turn a later
  content click into a toggle after an idle period. Right-click retains standard
  mouse-up menu timing.
  **The menu holds actions only** — Open Usage Window, Refresh Now, Settings…,
  Check for Updates, What's New, Save Diagnostics…, Quit. Anything that *sets* or
  *toggles* state belongs in Settings, not the menu.
- **Settings is a real `NSWindow` (`SettingsView.swift`), not a popover.** The
  status-item popover uses application-defined dismissal so its inline calendar
  and model-pricing layers cannot trigger AppKit's unspecified transient-close
  heuristics. Paired local/global mouse monitors close it deterministically for
  the known Settings window and other-app outside clicks; unknown AppKit windows
  are retained because SwiftUI uses them for nested controls. The status item,
  Escape, and Settings each use an explicit close path. Settings remains a
  separate window because its sheets, alerts and save panels need an independent
  hierarchy. Opened by
  the cog button in the dashboard header, by "Settings… ⌘," in the menu, or by the
  `--settings` launch flag (the documented notch/overflow gotcha can put the
  status item out of reach). `isReleasedWhenClosed = false`; `windowWillClose`
  clears the reference and restores the `.accessory` activation policy.
  Three things there are load-bearing and easy to break:
  - **Size the host before positioning.** `host.view.layoutSubtreeIfNeeded()` then
    `setContentSize(host.view.fittingSize)` *before* centring. SwiftUI's fitting
    size isn't known at construction, so centring first centres a near-empty
    window and it then grows from that wrong origin (it landed hard against the
    top of the screen).
  - **Position persists** via `setFrameUsingName` / `setFrameAutosaveName`
    (`AppDelegate.settingsFrameName`); `trueCenter` is used only when nothing is
    saved, because `NSWindow.center()` deliberately sits in the upper third.
  - **`SettingsWindow` overrides `performKeyEquivalent`** for ⌘W / ⌘Q / ⌘M.
    BarPilot is an `LSUIElement` agent with no main menu, so AppKit supplies none
    of the standard shortcuts and the window otherwise looks broken.
  The content has a fixed 740×470 sidebar layout with General, Spending, GitHub,
  and Updates & Support panes. `Start at login` is first in General, and the pane
  header provides an explicit Done action in addition to the standard window
  controls. Switch rows go through `switchRow`, which puts the switch after a
  `Spacer` so switches align on the right regardless of label length.
- **The usage-window shortcut uses Carbon `RegisterEventHotKey`, not an event
  tap.** It therefore works globally without Accessibility or Input Monitoring
  permission. Recording temporarily unregisters the current combination; cancel,
  focus loss, or an unconfirmed replacement restores it. Carbon does not report
  conflicts owned by another process, so a new combination is persisted only
  after the user presses it again and BarPilot receives the global event; otherwise
  an eight-second timeout restores the old shortcut. At least two modifiers are
  required so common single-modifier app commands are not captured system-wide.
  The shortcut toggles the popover; closing it restores the application or
  Settings window that held keyboard focus before the popover opened.
- **The budget field is AppKit-backed (`BudgetField`), and its parsing is pure
  (`BudgetInput`).** SwiftUI's `TextField` places the click's caret *after* it
  reports focus, so a typed figure gets appended to the existing one — 1000
  becomes 12001000 with nothing on screen to explain the resulting nonsense
  budget bar. `NSTextField.selectText` on `becomeFirstResponder` is deterministic
  where a deferred `selectAll` on the field editor is not. `updateNSView` syncs on
  binding *provenance* (`Coordinator.lastSeenText`), not on `currentEditor()`,
  because the field takes first responder as the window opens and an
  editor-based guard would swallow the initial value. `BudgetInput.parse` rejects
  non-numeric, negative, non-finite and anything above `BudgetInput.maximum`
  (1,000,000); it is covered by `--verify-projection`.
- **The dashboard has one selected-currency spend summary.** Its segmented
  currency control writes `displayCurrency`; all monetary values render through
  `effectiveCurrency`, so AUD still falls back to USD until a rate loads. The
  budget meter draws the projection beneath current spend, with an endpoint
  marker and anchored value; over-budget projections use off-scale chevrons.
- **GitHub connection is the primary dashboard setup state and is separately
  authorized from gist sync.** A disconnected window shows a **Connect GitHub**
  CTA; there is no unsolicited startup prompt. Settings exposes
  Connect/Disconnect as a secondary account action. It polls GitHub's internal
  account endpoint every 60 seconds and stores samples in the local span-cache
  database. The credentials use separate Keychain entries, so disconnecting one
  feature cannot silently disable the other. (#33)
- **The primary UI is server-first and billing-cycle based.** It shows credits,
  USD + AUD, monthly budget progress, a daily usage bar chart, and daily
  observed counter deltas. Long gaps within one UTC day can be assigned safely;
  unsampled growth crossing a UTC day boundary remains unallocated. Stored
  completed billing cycles remain navigable by arrows or a UTC daily-spend
  calendar. The calendar combines safely observed spend from both cycles when a
  non-midnight reset splits one UTC day, and never invents values for unallocated
  dates. The menu bar stays on the current cycle and historical cycles never
  project forward. The
  telemetry tabs remain temporarily accessible behind a deprecated legacy-view
  control. (#34, #41)
- **The menu-bar figure warns when GitHub is not authoritative.** Reuse the
  existing warning glyph while disconnected, reconnect-required, stale, or in
  error; the amount remains the local fallback rather than disappearing.
- **Multi-machine sync uses schema v3 counter observations and cycle budgets.** Each Mac publishes
  the live cycle's first locally captured observation in each 15-minute UTC
  bucket plus its moving close. Completed cycles retain the first, high-water
  and last observation of each UTC day plus their final close, using server time
  when available for ordering and UTC-day membership, and the payload has a
  defensive 6,144-sample ceiling. That ceiling, a raw payload-size bound and
  numeric/timestamp validation use the same gate before upload and after
  download. The complete snapshot is capped at 64 machine payloads so bounded
  row counters cannot overflow a combined signed-64-bit report. A single
  compact SQL history read avoids
  materialising every minute-level poll. Pulled samples are decoded off the main
  actor once, cached in memory, written to the separate remote store as one
  atomic snapshot, can add remote-only cycles to navigation and rolling
  activity, and are never re-published. Snapshot persistence executes off the
  main actor and is generation-gated so a late write cannot survive a sync
  disable/re-enable. If cached peers and local history finish loading in either
  order, the latter view is recombined before publication. Turning sync off cancels its active
  network task; sync, account-generation, connection-state and fingerprint
  checks reject any late continuation after an identity change. A startup push
  is also withheld unless the complete saved history loads successfully, and an
  enabled connection cannot publish until its account identity is resolved. This
  protection is fingerprint-driven, not connection-driven: disconnecting
  account usage leaves multi-Mac sync enabled, so that state must still load the
  full local history before publishing. Pull failures, unreadable machine files,
  unsupported cached schemas, missing authorization and local snapshot write
  failures retain the complete last-good cache and remain visible in the footer;
  a successful empty pull removes absent peers. A canonical SHA-256 digest of
  every publishable field (except `updatedAt`) controls unchanged uploads; do not
  replace it with aggregate counts or totals that can collide. `--verify-sync`
  always uses a temporary remote database and
  terminates unsuccessfully on either aggregate or persistence mismatches. A
  PBKDF2-derived account
  fingerprint gates merging;
  account-wide counter values are never added across machines. Before any push,
  the complete Gist is validated. A durable database identity gates one-time
  reconciliation with this machine's supported prior payload; this restores
  observations after local database loss without resurrecting normally pruned
  rows, and prevents a downgraded build from overwriting a future self schema.
  Push decisions compare the newly projected content with the downloaded self
  file; a local fingerprint cache must never stand in for remote truth. Cycle
  budgets are stored independently of observations, persist their true edit time
  separately from observation time, and use machine id as the deterministic
  tie-breaker for simultaneous edits. This allows a locally edited budget for a
  peer-only cycle to be published even when this Mac has no sample in that cycle.
  Persistence completions are also gated by account generation and fingerprint;
  an old account's delayed write must not mutate current in-memory state.
  A fresh matching peer observation may drive the current cycle when the local
  Mac missed rollover, with the UI identifying its synced origin. The fingerprint
  must stay deterministic across Macs (no per-install salt), so a plain hash of
  GitHub's small numeric id space would be reversible by a precomputed table —
  hence the KDF. Schema v3 retains legacy
  aggregate rows only during deprecation. Truncated gist files are fetched through
  their authenticated `raw_url`. Payloads also carry the public USD→AUD quote and
  its provider update timestamp. The newest valid provider timestamp wins across
  Macs; local fetch time is never used to decide freshness.
- **Cycle membership is interval containment, not calendar-month equality.**
  `CreditReconciliation.isCurrentCycle` tests `resetAt - 1 month <= now < resetAt`.
  Copilot resets are not always UTC midnight on the 1st — the account response
  carries the reset in four fields, two of which encode a time-of-day, and
  anniversary-billed accounts never land on the 1st. Requiring alignment silently
  blanked the entire dashboard for those accounts with no error shown. The legacy
  overlay (`matchesCurrentCycle`) additionally requires an exact UTC-midnight
  start because even a same-day 10am reset leaves prior-cycle hours in a locally
  aggregated calendar-month range.
- **Sample history is addressed by cycle and account, never by a mutable pointer.**
  `credit_samples.account` records which account observed each row, and
  `Store.loadCycleSamples` reads by UTC reset day + account. Exact reset instants
  remain stored, but same-day variants are coalesced for navigation because the
  API's reset fields can disagree on time-of-day. Rollover is committed only when
  the reset day moves forward *and* the counter drops. The former baseline
  pointer is **deleted, not repurposed** — it was the only account-isolation
  mechanism, so it had to be shoved forward on every reconnect, and any change to
  fingerprint derivation made the *same* account look new and hid the whole cycle.
  `CreditSampleStore.adoptUnattributed` claims pre-migration rows exactly once
  (guarded by a `meta` key) so a second account can never inherit the first's
  history. Never reintroduce a time-based visibility gate for account isolation.
- **`DiagLog` and `--diagnose` carry no monetary or credit figures.** The reload
  line records a menu-state token and a drift flag, not the total, because
  `--diagnose` output is documented as safe to paste into a public issue.
- **Legacy retirement does not delete the application database.** `credit_samples`
  shares the existing SQLite file with `spans` and `meta`. Stop telemetry
  ingestion first; leave legacy tables intact for rollback, then remove them only
  in a later versioned migration. The remote store likewise remains during the
  transition.
- **Budget = one editable monthly USD figure** (`monthlyBudgetUSD`, default $150
  ≈ $5/day), pro-rated to a per-day rate via `avgDaysPerMonth = 30.4375` and
  multiplied by the selected range's days. Edited in Settings via an inline field
  + Set button (the old NSAlert prompt is gone). In the
  compact bar, the 100% budget marker is fixed at 70% of the track, leaving the
  final 30% to visualize projections up to about 143% of budget. Fill widths and
  the marker use that same fixed scale; budget and projection labels use the
  selected display currency and retain actual over-budget values.
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
  Settings — no third-party dependency.
- **Currency (USD/AUD):** everything is computed/stored in USD; AUD is a
  display-time conversion via a live rate (`Currency.swift`, open.er-api.com,
  fetched on launch + every 24h, cached in UserDefaults for offline use). The
  provider update timestamp is persisted with the rate and propagated through
  opt-in multi-machine sync, so a Mac automatically adopts a newer provider
  vintage and never replaces it with an older CDN response. The budget stays
  canonical USD (`monthlyBudgetUSD`); in AUD it's shown converted and rounded to a
  whole dollar (`budgetMoneyString`), and the budget dialog reads/writes in the
  displayed currency. `effectiveCurrency` falls back to USD if AUD is selected
  before a rate has loaded. All cost display goes through `Store.costString`.

## Gotchas

- On a Mac with a notch + crowded menu bar, macOS pushes overflow status items
  to the **left of the notch**; ⌘-drag repositions them. `pgrep -lf BarPilot`
  confirms it's running.
- All formatting goes through `Fmt` (Model.swift) — keep cost/credit/date output
  consistent by reusing it rather than ad-hoc `String(format:)`.
