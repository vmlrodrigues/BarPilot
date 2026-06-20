# Changelog

All notable changes to BarPilot are documented here.

## [Unreleased]

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
