# TODO

## Persistent span cache (survive VS Code extension updates)

VS Code's Copilot Chat extension wipes `agent-traces.db` when it updates, taking
all historical usage data with it. Confirmed happening to multiple users.

BarPilot should maintain its own persistent cache of every span it has ever loaded,
stored in BarPilot's own Application Support folder. Since spans are already
deduplicated by `spanId`, accumulating them into a local cache is safe — new spans
get merged in on each refresh, and the cache survives any upstream file wipe.

Steps:
1. On each `DataSources.loadAll()`, after loading, merge new spans into a local
   SQLite or flat file cache at `~/Library/Application Support/com.victorrodrigues.barpilot/`.
2. On load, read the cache first, then overlay fresh records from the live sources.
3. The cache only stores the minimal fields BarPilot needs (spanId, model, startMs,
   credits, tokens, conversationId, sessionId, operationName, source).
4. Cap or prune the cache by age (e.g. keep 12 months) to prevent unbounded growth.

---

## Xcode Copilot support

GitHub Copilot for Xcode (`com.github.copilot-for-xcode`) is a separate product
from both current data sources. If it emits OTel spans, they'd land under
`~/Library/Application Support/com.github.copilot-for-xcode/` (path unconfirmed).

Steps:
1. Install Copilot for Xcode, enable any available telemetry option, and find what
   files are written and in what format.
2. Add a path constant + `loadXcode()` loader in `Sources.swift`, wired into `loadAll()`.
3. Add detection / setup logic in `Sources.swift` + `Setup.swift` (same pattern as
   VS Code / Mac App).

The existing JSONL parser already handles both flat Mac App and nested OTLP envelope
shapes, so if the file format is either of those it should work with minimal changes.

---

## Android Studio / JetBrains Copilot support

The GitHub Copilot JetBrains plugin runs inside IDEs that live under
`~/Library/Application Support/JetBrains/<IDE + version>/`. Not currently read.

Steps:
1. Install the Copilot JetBrains plugin in Android Studio (or IntelliJ), enable any
   available telemetry option, and locate the output file + format.
2. Note: the plugin may push telemetry to GitHub's backend only (no local file) — verify
   before assuming local OTel file support exists.
3. If a local file is confirmed: add a path constant + loader in `Sources.swift`,
   detection in `Setup.swift`, same pattern as the other sources.
