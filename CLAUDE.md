# BarPilot

A native macOS menu-bar app (Swift / SwiftUI / AppKit, SwiftPM) that tracks
GitHub Copilot account credits and spend. GitHub's authenticated internal counter
is the only usage source. There is no local OTel ingestion or attribution view.
Network access also supports optional Gist sync, model pricing, updates and
USD-to-AUD exchange rates. Formerly named TokenTally.

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

Use `make verify` after changing counter persistence, sync or presentation.
There is no telemetry dump mode.

`--regular` runs as a normal foreground (Dock) app instead of a menu-bar agent.

Other headless modes — run the relevant ones after touching their area:

| Flag | Checks |
|---|---|
| `--verify-projection` | spend-projection run-rate math + guards (#18) |
| `--verify-sync` | v3 counter payload, account isolation, remote gap-fill and compatibility |
| `--verify-credits` | counter parsing, availability, cycle guards, history retention and telemetry retirement |
| `--verify-wake-refresh` | visible-wake freshness and bounded retry rules (#39) |
| `--verify-shortcut` | global shortcut validation and persistence encoding (#40) |
| `--verify-telemetry-cleanup` | removal of BarPilot's old Copilot telemetry agent, helper and matching session variables only |
| `--verify-startup` | build identity, release-signature gating and recoverable update replacement |
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

## Usage invariants

- Credits / 100 = USD cost. Current totals use account counters only, never local
  attribution or a maximum of counter and telemetry.
- A disconnected, failed-poll, missing, expired-cycle or old cached counter is
  unavailable, not zero. The menu bar shows a dash and the current budget meter
  and forecast are hidden. A successful counter value of zero remains visible.
- Failed polls do not overwrite saved observations. Completed-cycle history is
  still navigable and retained after reconnecting.
- Daily deltas are assigned only when observations prove the UTC day. Unsampled
  increases spanning UTC days remain unallocated. Never diff across a cycle
  reset or turn a counter correction into negative usage.
- Cycles use the actual reset instant and UTC day keys. Budgets are first-class
  cycle records, not derived from today's preference for older history.
- Disconnect removes only the usage credential; account history and separately
  authorized multi-Mac sync remain intact.
- Run `--verify-credits` and `--verify-sync` after changing these rules.

## Architecture

```
Sources/BarPilot/
  App.swift          @main AppMain.main() → AppKit run loop; AppDelegate owns the
                     NSStatusItem + NSPopover(NSHostingController(CompactDashboard)).
  Store.swift        Main-actor counter history, budgets and refresh coordination.
  Model.swift        Billing-cycle projection and formatting helpers.
  CreditUsage.swift  Defensive GitHub account-counter client.
  CreditSamples.swift SQLite counter samples, cycle budgets and retirement migration.
  TelemetryCleanup.swift Launch-time removal of the old telemetry agent and variables.
  CreditTimeline.swift Conservative UTC daily counter deltas.
  CreditCycle.swift  Cycle membership, current-counter availability and checks.
  CompactDashboard.swift Primary dashboard, calendar and daily chart.
  SettingsView.swift Settings window.
  GlobalShortcut.swift Persisted Carbon hot-key registration and recorder.
  SyncAggregate.swift Versioned counter payload and older-peer compatibility.
  GitHubBackend.swift Private-Gist transport.
  RemoteStore.swift  Atomic cached peer snapshots.
  Updater.swift      Native signature detection and silent release updater.
  LoginItem.swift    Start at Login via SMAppService.
  Currency.swift     USD/AUD conversion and exchange-rate freshness.
  DiagLog.swift      Size-capped support log.
  Diagnose.swift     Privacy-safe support report.
Info.plist           LSUIElement (menu-bar-only) agent bundle.
build-app.sh         Build + assemble + stable-sign locally (ad-hoc fallback for contributors).
```

Primary data flow: `CreditUsageAPI` → `CreditSampleStore` → local observations +
matching `MachineSyncPayload` observations → `CreditTimeline` →
`CompactDashboard`. Account counters are unioned and deduplicated, never summed.

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
  account endpoint every 60 seconds and stores samples in the existing SQLite
  database (historical filename retained). The credentials use separate Keychain entries, so disconnecting one
  feature cannot silently disable the other. (#33)
- **The primary UI is server-first and billing-cycle based.** It shows credits,
  USD + AUD, monthly budget progress, a daily usage bar chart, and daily
  observed counter deltas. Long gaps within one UTC day can be assigned safely;
  unsampled growth crossing a UTC day boundary remains unallocated. Stored
  completed billing cycles remain navigable by arrows or a UTC daily-spend
  calendar. The calendar combines safely observed spend from both cycles when a
  non-midnight reset splits one UTC day, and never invents values for unallocated
  dates. The menu bar stays on the current cycle and historical cycles never
  project forward. (#34, #41)
- **Current usage disappears when unavailable.** No local fallback is shown
  after a failed poll or disconnect, even if a peer has a saved counter. Persisted
  history is not erased. A cached sample is not presented as current until this
  launch completes a successful poll; its GitHub observation must be no more
  than five minutes old.
- **Multi-machine sync uses schema v3 counter observations and cycle budgets.** Each Mac publishes
  the live cycle's first locally captured observation in each 15-minute UTC
  bucket plus its moving close. Completed cycles retain the first, high-water
  and last observation of each UTC day plus their final close, using server time
  when available for ordering and UTC-day membership, and the payload has a
  defensive 6,144-sample ceiling. That ceiling, a raw payload-size bound and
  numeric/timestamp validation use the same gate before upload and after
  download. The complete snapshot is capped at 64 machine payloads. A single
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
  terminates unsuccessfully on payload or persistence mismatches. A
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
  hence the KDF. Schema v3 retains the `rows` wire field solely for older-peer
  decoding. Outgoing rows are empty; telemetry rows never contribute or get
  republished. Truncated gist files are fetched through
  their authenticated `raw_url`. Payloads also carry the public USD→AUD quote and
  its provider update timestamp. The newest valid provider timestamp wins across
  Macs; local fetch time is never used to decide freshness.
- **Cycle membership is interval containment, not calendar-month equality.**
  `CreditCycle.isCurrentCycle` tests `resetAt - 1 month <= now < resetAt`.
  Copilot resets are not always UTC midnight on the 1st — the account response
  carries the reset in four fields, two of which encode a time-of-day, and
  anniversary-billed accounts never land on the 1st. Requiring alignment silently
  blanked the entire dashboard for those accounts with no error shown.
- **Sample history is addressed by cycle and account, never by a mutable pointer.**
  `credit_samples.account` records which account observed each row, and
  `Store.loadCycleSamples` reads by UTC reset day + account. Exact reset instants
  remain stored, but same-day variants are coalesced for navigation because the
  API's reset fields can disagree on time-of-day. Near a reset, a sample for the
  new cycle needs a lower counter if the previous cycle ended above zero. A
  post-reset observation after a zero-usage cycle can be accepted immediately.
  The confirmation window ends after 24 hours. The former baseline
  pointer is **deleted, not repurposed** — it was the only account-isolation
  mechanism, so it had to be shoved forward on every reconnect, and any change to
  fingerprint derivation made the *same* account look new and hid the whole cycle.
  `CreditSampleStore.adoptUnattributed` claims pre-migration rows exactly once
  (guarded by a `meta` key) so a second account can never inherit the first's
  history. Never reintroduce a time-based visibility gate for account isolation.
- **`DiagLog` and `--diagnose` carry no monetary or credit figures.** The reload
  line records a connection-state label, not the total, because
  `--diagnose` output is documented as safe to paste into a public issue.
- **Telemetry retirement preserves the application database.** On release launch,
  `CreditSampleStore.retireLegacyTelemetry` transactionally drops only `spans`
  and known telemetry ingestion/backfill metadata. `credit_samples`, cycle
  budgets, account-adoption keys, migration keys and database identity remain.
  Never delete the database or clear the complete `meta` table.
  Cleanup of settings installed in other apps is manual and ownership-sensitive;
  see the README. Source traces and backups are not automatically deleted.
- **Budget = one editable monthly USD figure** (`monthlyBudgetUSD`, default $150
  ≈ $5/day). Edited in Settings; recorded independently for each UTC billing cycle.
  In the compact bar, the 100% budget marker is fixed at 70% of the track, leaving the
  final 30% to visualize projections up to about 143% of budget. Fill widths and
  the marker use that same fixed scale; budget and projection labels use the
  selected display currency and retain actual over-budget values.
- **Auto-update uses GitHub Releases.** `Updater.swift` runs one check at a time
  across manual and scheduled triggers. It stages the bundle beside the running
  app, verifies its identity, Developer ID signature and Gatekeeper assessment,
  and uses a helper process to exchange the two bundles atomically. The helper
  retains the original bundle until the relaunch command succeeds. Developer ID
  release builds use this updater.
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
