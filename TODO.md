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

## Xcode and Android Studio / JetBrains Copilot support — blocked upstream

Neither Copilot for Xcode nor the JetBrains Copilot plugin emit local OTel telemetry.
Both are blocked at the language-server level and cannot be supported until GitHub/
Microsoft ships proper OTel support in those clients.

**Xcode (confirmed by source inspection):**
- `COPILOT_OTEL_EXPORTER_TYPE=file` is silently dropped — the Xcode extension launches
  the language server with a hardcoded env var whitelist of only 3 vars (`PATH`,
  `NODE_EXTRA_CA_CERTS`, `NODE_TLS_REJECT_UNAUTHORIZED`). The env var never reaches
  the language server.
- No `agent-traces.jsonl` or `.db` is written anywhere on disk.
- The only local per-turn data is raw token counts in a plain-text log file
  (`~/Library/Logs/GitHubCopilot/github-copilot-for-xcode.log`) — no AIU values,
  no reliable model attribution.

**JetBrains / Android Studio (confirmed via open issues):**
- Same failure mode — env var whitelist strips OTel vars before language server launch.
- No local trace files written.
- Open feature requests: microsoft/copilot-intellij-feedback #1680 and #1778.

Revisit when GitHub ships OTel support in either client.
