# Changelog

All notable changes to BarPilot are documented here.

## [Unreleased]

---

## [0.9.0] — 2026-08-04

### Added
- **BarPilot now tells you when Copilot stops recording usage.** Previously, if
  the Copilot app's telemetry silently died, your total just quietly stopped
  moving and looked completely normal — one user lost days of data before
  noticing. BarPilot now watches whether the Copilot app is actually writing, and
  within minutes shows a warning on the menu-bar figure and a banner in the
  window: "Copilot is running but isn't recording telemetry — quit and reopen
  it." It clears itself as soon as data flows again, and stays silent when you're
  simply not using Copilot. (#27)
- **"Save Diagnostics…" in the menu.** Produces the support report without using
  Terminal, then reveals it in Finder so you can send it on. Timings, counts and
  file sizes only — no code, prompts, or account details. (#31)

### Fixed
- **A failed cache write could silently skip usage records.** The read position
  advanced before the data was safely stored, so records could be lost for good.
  It now only advances after a successful write. (#28)
- **Source record counts now match the totals they sit beside** — they were
  including orchestration rollups that every total excludes. (#29)

---

## [0.8.3] — 2026-07-26

### Fixed
- **Idle CPU usage is essentially gone.** BarPilot was re-reading your entire
  usage log — often over a gigabyte — every single refresh, which burned seconds
  of CPU a minute and got worse the longer you'd used it. It now reads only what's
  been added since the last check: a refresh went from ~7s to ~0.05s here, and no
  longer scales with your history. (#24)

### Added
- **`--diagnose` support report.** If something looks wrong, run
  `/Applications/BarPilot.app/Contents/MacOS/BarPilot --diagnose` in Terminal and
  send us the output — it lists versions, file sizes, load timings and recent
  refresh history. Counts and timings only (never your prompts or code), with your
  username stripped from paths so it's safe to paste into a public issue.
- A size-capped log at `~/Library/Logs/BarPilot/barpilot.log` recording one line
  per refresh. Rotates at 256 KB and keeps two files, so it can never grow
  unbounded.

---

## [0.8.2] — 2026-07-23

### Fixed
- **High CPU and memory after waking the Mac.** Overlapping refreshes could each
  re-scan your full usage log at the same time — pegging CPU and memory, and
  getting worse the larger your history. Refreshes now run one at a time. (#23)

---

## [0.8.1] — 2026-07-09

### Fixed
- **Menu bar no longer flashes a low total on launch.** With multi-machine sync
  on it could briefly show the other machine's total alone before this machine's
  data finished loading; it now stays on "—" until the real combined total is
  ready. (#20)
- **The "restart to start capturing" telemetry nudge no longer nags existing
  users.** It was firing whenever a source's live DB was momentarily empty (which
  extension updates cause routinely), even for sources with captured history. It
  now appears only for a source that has never captured anything — the fresh-setup
  case it was meant for. (#21)

---

## [0.8.0] — 2026-07-09

### Added
- **Month-end spend projection.** On "This Month", the budget bar now projects
  your full-month spend from the run rate so far: a faint "ghost" fill extends to
  where you're heading, and a caption reads e.g. "Projected $186 by Jul 31 · over
  by $36". Turns red when you're on pace to exceed the budget. (#18)

### Changed
- **Budget-bar heading now says "spend", not "budget".** The figure under the
  heading is what you've spent — the budget is the reference on the right — so it
  now reads "This month's spend" instead of "This month's budget". (#17)
- **Footer nudges you to restart a configured source that isn't capturing.** If
  telemetry is on for VS Code or the Copilot app but BarPilot sees no usage yet,
  the footer now says to quit and reopen it — the exporter only starts on
  relaunch. Previously this hint lived only in a hover tooltip. (#16)

---

## [0.7.1] — 2026-07-06

### Added
- **"Previous Month"** period option in the range dropdown — the full previous
  calendar month (e.g. all of June while you're in July).

---

## [0.7.0] — 2026-07-04

### Added
- **Opt-in multi-machine usage aggregation.** If you run Copilot on more than one
  Mac, BarPilot can now show a single combined total across all of them. Turn it on
  from the menu-bar icon's right-click menu → **Multi-Machine Sync**: a one-time
  GitHub device-flow sign-in (**gist scope only**), after which each machine keeps a
  compact per-day, per-model usage **summary — numbers only, never code, prompts, or
  content** — in a **private secret gist** in your own account, and pulls the other
  machines'. The **Summary**, **Models**, **Daily**, the total, and the menu-bar
  figure combine across machines; **Sessions** and **Top** stay per-machine. Off by
  default — if you never enable it, nothing changes. The footer shows which GitHub
  account you're synced as, and turns red with the reason if an upload fails.
  Requires a GitHub account that can create gists (work/enterprise accounts with
  gists disabled can't sync).
- **What's New** in the right-click menu — opens the changelog.

---

## [0.6.1] — 2026-07-02

### Fixed
- **Models tab: single-level rows wrapped their text.** A model that ran at only
  one reasoning level renders as a single row with the model name and an inline
  level chip in the same column; on the narrow Models layout the name and the
  level word ("medium" → "medi-/um") could wrap character-by-character. The name
  is now kept to one line (truncating with a full-name tooltip) and the level chip
  never wraps. Grouped (multi-level) models were unaffected.

---

## [0.6.0] — 2026-07-02

### Fixed
- **Totals were over-counted for agent-mode usage.** The GitHub Copilot Mac App
  emits an `invoke_agent` orchestration span per agent task whose AIU equals the
  sum of the child model calls it drove — so counting it alongside those calls
  double-counted. It slipped past the existing "skip orchestration spans" guard
  because, unlike other agent spans, it carries a model attribute. These rollups
  are now excluded both when parsing and at cache-load, so **every past period
  recomputes to the correct, lower figure** — non-destructively (the rows stay in
  the cache, just uncounted). The over-count ranged from 0% (no agent use) up to
  ~2× in an all-agent period.

### Added
- **Reasoning-effort breakdown in the Models tab.** Each model's spend is now
  grouped by the reasoning level it ran at (`low`/`medium`/`high`/`xhigh`/`max`).
  A model used at more than one level expands into a bold model-total row — whose
  effective rate and Fit use every call, so it stays the reliable figure — with a
  row per level beneath it, each marked by a coloured effort dot. Single-level and
  non-reasoning models stay a single row; calls with no level set are collected
  under a "no level" row with an ⓘ explaining what they are. The level is read
  from both sources and normalised, and a one-time, reversible backfill fills it
  onto already-cached history (Mac App fully; VS Code across its ~7-day retention).

### Improved
- **Header sparkline now spans the whole period.** For short periods (Today,
  Last 7 / 30 Days, This Month, Custom) the mini bar chart shows one slot per day
  across the period's full calendar span — so early in the month you see a couple
  of small bars with the rest blank, filling in as the month progresses, instead
  of two bars stretched across the whole strip. This Year / All Time keep the
  compact data-day view.

---

## [0.5.3] — 2026-07-01

### Fixed
- **"This Month" budget bar measured against a single day.** On the 1st of the
  month the pro-rated budget collapsed to one day (days-elapsed = 1), so the bar
  compared spend against ~one day's budget (identical to "Today") instead of the
  month — e.g. showing 64% when only 2% of the monthly budget was used. "This
  Month" now compares against the **full monthly budget**, so the bar reflects
  progress through the month. Other periods are unchanged.

---

## [0.5.2] — 2026-06-30

### Fixed
- **Self-update failed on networks that block Apple's notarization service.** The
  in-app updater verifies the downloaded app with Gatekeeper, but only the DMG was
  stapled — not the app bundle — so verifying the *extracted* app required a live
  call to Apple, which fails behind some corporate firewalls/VPNs (the update was
  silently rejected). The release now staples the notarization ticket to the **app**
  itself, so the updater verifies it **offline**. The updater also now logs which
  verification check fails, to make any future issue self-diagnosing.

---

## [0.5.1] — 2026-06-29

### Fixed
- **First-run flash of `$0`.** On a cold cache (fresh install, before the first
  read completes — now slightly longer because of the history backfill), the
  window briefly showed a misleading `$0.00` total. It now shows a "loading…"
  placeholder until the first load finishes, so a fresh install never flashes a
  fake zero.

---

## [0.5.0] — 2026-06-29

### Added
- **One-time chat-history backfill.** On first launch, BarPilot reads the VS Code
  Copilot chat session files and backfills *exact* recorded-credit usage for the
  window between the usage-based-billing start (2026-06-01 UTC) and the earliest
  OTel span it has — recovering history that the ~7-day `agent-traces.db`
  retention drops, which is otherwise invisible to new installs. Recorded credits
  only (no estimation); models normalise to the same form as live data so they
  merge into existing per-model rows. Runs at most once (gated by an in-DB
  `backfill_version`), is additive and reversible (rows tagged
  `source = chatBackfill`; a re-run cleanly replaces only its own rows), and takes
  a one-time cache backup before its first run.

---

## [0.4.7] — 2026-06-26

### Fixed
- **Popover stays visible (translucent) after changing the period dropdown.**
  Interacting with the period picker opens a native `NSMenu` that runs a modal
  event loop, which disrupts `NSPopover`'s built-in `.transient` outside-click
  monitor. A supplemental `NSEvent` global monitor now acts as a reliable backup
  so that any click outside BarPilot closes the window, even after the picker
  has been used. Fixes [#1](https://github.com/vmlrodrigues/BarPilot/issues/1).

---

## [0.4.6] — 2026-06-23

### Added
- **Models tab — effective per-token cost.** Each model now shows the input and
  output rate you actually paid (`in $/Mtok` / `out $/Mtok`) over the selected
  period, derived from a least-squares fit of credits against token counts — so
  cache discounts are baked in and the figures sit well below list price. A
  `Fit` column reports how well that two-rate split explains the real credits,
  and a blue ⓘ explains all three. Token counts are now abbreviated (`86.3M`,
  `661K`) to keep the full breakdown within the window.

---

## [0.4.5] — 2026-06-21

### Improved
- **Sessions tab:** added "Last active" column showing the most recent call
  timestamp for each session — makes it easy to see which sessions are still
  ongoing. In/Out token columns replaced with Last active and Cost. Sessions
  now sortable by Started, Last active, Calls, and Cost (defaults to Last
  active descending).

---

## [0.4.4] — 2026-06-21

### Improved
- **Daily tab:** added Cost column; Day header is now clickable to toggle sort
  order (latest first by default); bold "Daily total" subtotal row after each
  day's model breakdown shows summed calls, credits, and cost.
- **Top tab:** Model column is now flex (adapts to name length); Op column
  tightened to 90 px — just wide enough for `invoke_agent`; blue ⓘ on the Op
  header opens a popover explaining `chat` vs `invoke_agent`; In/Out token
  columns replaced with a Cost column.

---

## [0.4.3] — 2026-06-20

### Improved
- UTC info icon (ⓘ) next to the date range is now blue and clickable, opening
  a popover explaining that date ranges use UTC midnight to match GitHub's
  billing cycle.

---

## [0.4.2] — 2026-06-20

### Fixed
- Period boundaries (Today, This Month, Last 7 Days, Last 30 Days, This Year)
  now use **UTC midnight** rather than local midnight, aligning exactly with
  GitHub's billing cycle reset (UTC midnight on the 1st of each month).
  Previously, users in UTC+ timezones would see "This Month" roll over at local
  midnight — up to 14 hours before GitHub's actual reset — causing June costs
  to disappear into "Last Month" prematurely.
- Date range header tooltip explains that ranges use UTC midnight to match
  GitHub's billing cycle.
- `--dump` default date range now uses the same UTC-based month start as the UI.

---

## [0.4.1] — 2026-06-14

### Fixed
- Budget bar now shows the prorated percentage in parentheses next to the period
  budget (`A$62.20 of A$130.90 budget (48%)`), and the right-side label shows
  the spend as a percentage of the full monthly budget (`22% of monthly budget`).
  Previously the 48% appeared on the right with no context, making it look like
  48% of the monthly budget rather than the pro-rated period budget.

---

## [0.4.0] — 2026-06-12

### Added
- **Persistent span cache** — BarPilot now maintains its own local SQLite cache of
  every span it has ever loaded (`~/Library/Application Support/com.victorrodrigues.barpilot/spans-cache.db`).
  Usage history survives VS Code Copilot Chat extension updates, which were confirmed
  to wipe `agent-traces.db` and zero out all historical data.
- **Version number** shown in the detail window footer.
- **Ice setup instructions** in the README — a one-line command to enable Ice's
  Always Hidden section so BarPilot is accessible from Ice's Menu Bar Layout.

### Fixed
- Dev builds (`./build-app.sh` without `make release`) now stamp the correct version
  from the `VERSION` file into the app bundle; previously they always showed `0.1.0`.

---

## [0.3.0] — 2026-06-09

### Added
- **USD / AUD currency toggle** — right-click the menu-bar icon → Currency to switch.
  The live USD→AUD rate is fetched from a public exchange-rate service on launch and
  refreshed every 24 hours (cached in UserDefaults for offline use).
- Budget dialog is currency-aware: input and display are in the selected currency;
  the canonical stored value remains USD.
- "Check for Updates" menu item added to the right-click menu.

---

## [0.2.0] — 2026-06-05

### Added
- **Silent auto-update** — BarPilot checks GitHub Releases shortly after launch and
  every 6 hours. When a newer release is found it downloads the notarised DMG,
  verifies the Developer ID signature (Team ID `9N354A3UZK`) and Gatekeeper approval,
  then installs and relaunches silently. Only active on Developer ID release builds.
- **Start at Login** via `SMAppService` — toggle from the right-click menu.

---

## [0.1.0] — 2026-06-02

### Added
- Initial public release.
- Menu-bar item showing total Copilot credit cost for the selected period.
- Detail window with period selector (Today / Last 7 Days / This Month / Last 30 Days /
  This Year / All Time / Custom range) and five tabs: Summary, Models, Daily,
  Sessions, Top.
- Daily sparkline and pro-rated budget bar (editable monthly budget, right-click →
  Set Monthly Budget…).
- Two data sources read directly off disk — VS Code Copilot Chat (SQLite) and
  GitHub Copilot Mac App (JSONL) — merged and deduplicated by span ID.
- Opt-in OTel telemetry setup: detects unconfigured sources and offers a one-click
  Enable flow that patches VS Code `settings.json` and installs a Mac App LaunchAgent.
- App icon, Developer ID signing, notarisation, and DMG release pipeline.
