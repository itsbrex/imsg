# imsg — Top-10 Improvements: Execution Plan

> **Source of truth for the multi-wave implementation.** Update this file as waves land. Branch: `claude/top-10-improvements-pTpkb`.

## Status snapshot (last updated: W3.M complete)

| Wave | Scope | State | Tip commit |
|------|-------|-------|-----------|
| 0    | Scaffolding (TASKS, SchemaVersion module, 9 command stubs, CommandRouter wiring) | ✅ shipped | `0ab81c0` |
| 1    | 10 design docs (~3,400 lines) — one per top-10 idea | ✅ shipped | `ea39b28` |
| 2a   | Schema envelope `{schema, kind, data}` (opt-in via `IMSG_SCHEMA=v1`) | ✅ shipped | `5a03950` |
| 2b   | `imsg mcp` stdio Model Context Protocol server | ✅ shipped | `1e677ac` |
| 2c   | `imsg outbox` queued send with delivery verification + `imsg send --via-outbox` | ✅ shipped | `188b6f3` |
| —    | Upstream sync (0.5.0 → 0.9.1, 85 commits) — bridge, refactors, ~25 new commands | ✅ merged | `7601b15` |
| 3    | Foundation refactors (watcher fanout, TOML, HTTP, contacts bridge) | 🚧 W3.M shipped; W3.T / W3.H / W3.C pending — note: upstream now ships `ContactResolver` so W3.C may collapse to a thin protocol over it | — |
| 4a   | Features: enrichment, export, graph (search dropped — upstream ships it) | 📋 planned | — |
| 4b   | Features: rules, compose, serve | 📋 planned | — |

Originally listed Waves 2/3/4 in the pre-Wave-1 TASKS.md have been superseded by this plan.

---

## Deferred-set inventory

The 10 ideas, mapped to current status:

| #  | Idea | Command | Design doc | Status |
|----|------|---------|-----------|--------|
| 1  | MCP server                                | `imsg mcp`          | `docs/mcp.md`        | ✅ shipped (W2b) |
| 2  | Search                                    | `imsg search`       | `docs/search.md`     | **superseded by upstream `imsg search`** (bridge-backed). Our W4.S FTS5 + embedding plan is descoped; if we want local-only indexing without the bridge, file it as a follow-up. |
| 3  | Rules engine                              | `imsg rules`        | `docs/rules.md`      | stub — W4b (W4.R) |
| 4  | Outbox                                    | `imsg outbox`       | `docs/outbox.md`     | ✅ shipped (W2c) |
| 5  | Enrichment (OCR / unfurl / transcripts)   | flag on watch/etc.  | `docs/enrichment.md` | not started — W4a (W4.E) |
| 6  | Schema envelope                           | n/a (env var)       | `docs/SCHEMA.md`     | ✅ shipped (W2a) |
| 7  | Long-lived socket server                  | `imsg serve`        | `docs/serve.md`      | stub — W4b (W4.V) |
| 8  | Contacts + interaction graph              | `imsg who`/`graph`  | `docs/contacts.md`   | stubs — W4a (W4.W). Note: upstream now ships `imsg whois` (reachability check via bridge) and `Sources/IMsgCore/ContactResolver.swift` (display-name lookup). Our W4.W focus narrows to interaction-graph aggregation and `--dot` export; the basic resolver work upstream already covers. |
| 9  | Compose (LLM-drafted replies)             | `imsg compose`      | `docs/compose.md`    | stub — W4b (W4.C) |
| 10 | Portable chat bundles                     | `imsg export`       | `docs/export.md`     | stub — W4a (W4.X) |

---

## Wave 3 — foundation refactors

These unblock multiple Wave-4 features. **Land sequentially**, one review batch per task, so any concurrency/permissions issues are caught before parallel work starts.

### W3.M — MessageWatcher multi-consumer fanout ✅
Unblocks: W4.V (serve), W4.R (rules), W4.E (enrichment).
- `Sources/IMsgCore/MessageWatcher.swift` is now an `actor` with a private `FileObserver` wrapper around `DispatchSourceFileSystemObject`. The observer is created lazily on first subscribe and torn down when the last subscriber drops. Each subscriber owns its own cursor + chatID filter; one shared fallback poll runs at the minimum interval across subscribers.
- The public `stream(chatID:sinceRowID:configuration:) -> AsyncThrowingStream<Message, Error>` API is preserved (now `nonisolated`); `WatchCommand`, `RPCServer+Handlers`, and `MCPHandlers` compile unchanged.
- New: `Tests/IMsgCoreTests/MessageWatcherFanoutTests.swift` covers (a) two subscribers each see every row exactly once, (b) cancellation of one consumer leaves the other running, (c) per-subscriber chat filters are independent.

### W3.T — Hand-rolled TOML subset
Unblocks: W4.R (rules).
- New `Sources/IMsgCore/Config/TOML.swift` — parse `[[rule]]` array-of-tables, scalars (string / int / bool / float / array), triple-quoted strings, `#` comments. Reject unknown keys.
- No new Swift Package dependency. Document the supported subset in the file's leading comment.
- Files: `Sources/IMsgCore/Config/TOML.swift`, `Tests/IMsgCoreTests/TOMLTests.swift`.

### W3.H — URLSession HTTP helper
Unblocks: W4.C (compose), W4.R webhook action, W4.E unfurl.
- New `Sources/IMsgCore/Net/HTTP.swift` — HTTPS-only by default, 10s timeout, 3 retries with jitter, size cap, header allow-list, optional HMAC-SHA256 body signing.
- Pure stdlib (`URLSession`, `CryptoKit`). No new dependency.
- Files: `Sources/IMsgCore/Net/HTTP.swift`, `Tests/IMsgCoreTests/HTTPTests.swift` (uses `URLProtocol` stub).

### W3.C — Contacts bridge protocol
Unblocks: W4.W (who/graph).
- New `Sources/IMsgCore/Contacts/ContactsBridge.swift` — `protocol ContactsBridge { func find(handle:) async throws -> ContactRecord? }` plus a `SystemContactsBridge` impl using `Contacts.framework`. Cache layer at `~/Library/Application Support/imsg/contacts.sqlite` with 24h TTL.
- Edit `Sources/imsg/Resources/Info.plist` to add `NSContactsUsageDescription`.
- Files: `Sources/IMsgCore/Contacts/{ContactsBridge,ContactsCache,ContactRecord}.swift`, `Sources/imsg/Resources/Info.plist` (edit), `Tests/IMsgCoreTests/ContactsBridgeTests.swift` (uses an in-memory mock bridge).

---

## Wave 4a — independent features (4 parallel agents)

Each agent owns a disjoint directory and a fillable command stub.

### W4.E — Enrichment pipeline
- `Sources/IMsgCore/Enrichment/Enricher.swift` — protocol + chain runner.
- `Sources/IMsgCore/Enrichment/OCREnricher.swift` — `VNRecognizeTextRequest`, 3s timeout per attachment, cache at `~/Library/Caches/imsg/enrich/ocr/`.
- `Sources/IMsgCore/Enrichment/UnfurlEnricher.swift` — uses `Sources/IMsgCore/Net/HTTP.swift` (W3.H); extracts `<title>` + OG/Twitter meta; cache at `enrich/unfurl/`; HTTPS-only.
- `Sources/IMsgCore/Enrichment/TranscriptEnricher.swift` — reuses existing chat.db transcription column; no on-device re-transcription in v1.
- Wiring: `--enrich ocr,unfurl,transcript` flag on `WatchCommand`, `HistoryCommand`, and `McpCommand`. Added fields appear only inside the envelope payload (additive).
- Tests: per-enricher unit tests, `Tests/imsgTests/EnrichmentFlagTests.swift` for CLI parsing.

### W4.S — Search (FTS5 tier only)
- `Sources/IMsgCore/Search/SearchIndex.swift` — protocol.
- `Sources/IMsgCore/Search/FTS5Index.swift` — `~/Library/Application Support/imsg/index/v1/messages.sqlite`. FTS5 with porter stemmer + `unicode61`. Incremental builder keyed on `last_indexed_rowid` per chat.
- `Sources/IMsgCore/Search/EmbeddingProvider.swift` — protocol + `MockProvider` only (deterministic hash). CoreML/MLX deferred.
- Fill `Sources/imsg/Commands/SearchCommand.swift` — `index build|reset`, query with `--limit/--chat-id/--since/--sender`, `--json` envelope output.
- Tests: `Tests/IMsgCoreTests/FTS5IndexTests.swift` (fixture chat.db → assert recall), `Tests/imsgTests/SearchCommandTests.swift`.
- **Note:** also add a `tools/call imsg.search` handler in `Sources/imsg/MCP/MCPHandlers.swift` that currently returns `-32601`; remove that stub now that the feature exists.

### W4.X — Export bundles
- `Sources/IMsgCore/Export/BundleManifest.swift` — schema-v1 manifest struct + sha256 hashing.
- `Sources/IMsgCore/Export/BundleWriter.swift` — deterministic output: messages ordered by `(created_at, rowid)`, attachments by lex filename, sorted JSON keys, `\n` line endings.
- `Sources/IMsgCore/Export/BundleVerifier.swift` — recompute hashes, return drift report.
- `Sources/IMsgCore/Export/BundleDiffer.swift` — structural diff (adds/removes/edits).
- Fill `Sources/imsg/Commands/ExportCommand.swift` — `export|verify|diff` subcommands via `--action`.
- Tests: golden-file round-trip in `Tests/IMsgCoreTests/BundleRoundtripTests.swift`.

### W4.W — Contacts (`who`) and interaction graph (`graph`)
- Depends on W3.C (`ContactsBridge`).
- `Sources/IMsgCore/Graph/GraphBuilder.swift` — read `MessageStore` history, group by `(contact_id, chat_id)`, compute frequency/cadence/last-seen.
- `Sources/IMsgCore/Graph/GraphExporter.swift` — JSON (envelope-wrapped) + DOT for Graphviz.
- Fill `Sources/imsg/Commands/WhoCommand.swift` — resolve one handle or all participants of a chat.
- Fill `Sources/imsg/Commands/GraphCommand.swift` — windowed export.
- Tests: in-memory `ContactsBridge` mock + fixture chat.db.

---

## Wave 4b — higher-risk features (3 parallel agents)

Separate sub-wave so each gets a focused review.

### W4.R — Rules engine
- Depends on W3.M (fanout), W3.T (TOML), W3.H (HTTP).
- `Sources/IMsgCore/Rules/{RuleModel,RuleLoader,RuleMatcher,RuleActions,RulesState}.swift`.
- Actions: `exec` (argv, 30s timeout, env injected), `webhook` (HTTPS via W3.H, optional HMAC), `reply` (delegates to `MessageSender`; `--dry-run` aware), `log`.
- Safety: implicit 1s rate limit (5s for replies), `(rule.name, message.guid)` dedupe in `rules.state.sqlite`, hard refuse of `reply` on `is_from_me=true` to prevent loops, universal `--dry-run`.
- SIGHUP hot reload; mtime fallback every 5s.
- Fill `Sources/imsg/Commands/RulesCommand.swift` with subcommands `run | validate | list | tail`.

### W4.C — Compose (LLM-drafted replies)
- Depends on W3.H (HTTP).
- `Sources/IMsgCore/Compose/Provider.swift` — `protocol Provider { func generate(...) -> Draft }`.
- `Sources/IMsgCore/Compose/AnthropicProvider.swift`, `OpenAIProvider.swift`, `MockProvider.swift`.
- `Sources/IMsgCore/Compose/DraftStore.swift` — `~/Library/Application Support/imsg/drafts.sqlite`, 7d TTL.
- Fill `Sources/imsg/Commands/ComposeCommand.swift` — `--chat-id`, `--prompt -` (stdin), `--style`, `--max-tokens`, `--json`, `--send --yes` double opt-in, `--redact-handles`, `--unsafe` override of refuse-list.
- Extend `Sources/imsg/Commands/SendCommand.swift` with `--from-draft <id>` to resend a stored draft.
- Tests: `MockProvider` returns deterministic uppercase; snapshot the CLI flows including TTY-less `--send` and recent-outbound 30s warning.

### W4.V — Long-lived socket server (`imsg serve`)
- Depends on W3.M (fanout).
- `Sources/imsg/Serve/SocketServer.swift` — accept loop on `$XDG_RUNTIME_DIR/imsg.sock` (fallback `~/Library/Caches/imsg/imsg.sock`), perms 0600.
- `Sources/imsg/Serve/ClientSession.swift` — JSON-RPC 2.0 framing, handshake (`server.hello`), heartbeat, backpressure with `ERR_LAGGED`.
- `Sources/imsg/Serve/RingBuffer.swift` — per-chat ring buffer for replay, fallback to DB query when out of window.
- Reuses `MCPHandlers` where overlap exists; `serve` adds `replay_from` to `watch.subscribe`.
- Optional token auth via `~/.config/imsg/serve.token`.
- Fill `Sources/imsg/Commands/ServeCommand.swift`.

---

## Process improvements (carried over from Wave 2 post-mortem)

1. **Pin the worktree base in every agent prompt.**
   - Required preamble: *"Before writing code, run `git fetch origin && git reset --hard origin/claude/top-10-improvements-pTpkb`. Confirm `git rev-parse HEAD` equals `<EXPECTED_SHA>` before proceeding; refuse to continue otherwise."*
   - W2b silently branched off `c9fa1c2` (pre-Wave-0). Do not let that recur.

2. **Swift Testing only for new tests.** All new test files must use `@Test` + `#expect`. As a one-shot cleanup task in Wave 3 (`W3.X`), migrate the three XCTest holdovers I authored in Wave 0/2a:
   - `Tests/IMsgCoreTests/SchemaVersionTests.swift`
   - `Tests/IMsgCoreTests/SchemaEnvelopeTests.swift`
   - `Tests/imsgTests/EnvelopeRoundtripTests.swift`

3. **Single envelope producer.** `Sources/imsg/MCP/MCPHandlers.swift` currently builds envelopes inline via `JSONValue`. Add `JSONValue.envelope(kind:data:)` helper (or migrate MCP handlers to `EnvelopePayload<JSONValue>` via `Encodable`) so every code path converges on one envelope producer. Suggest as `W3.X` cleanup.

4. **Pre-register command stubs.** Already done — all 9 deferred commands are registered in `CommandRouter`. Agents must NOT touch `CommandRouter.swift` in Wave 4; if they think they need to, the task scope is wrong.

5. **Explicit file allow-list per agent.** Every prompt enumerates exactly which files may be created or edited. Anything else is a violation and must be rebased out during merge.

---

## Parallelism plan

| Wave | Agents | Execution                            | Review batch          |
|------|--------|--------------------------------------|-----------------------|
| 3    | 1 + 1 + 1 + 1 | Sequential (each foundation reviewed before next) | 4 small reviews |
| 4a   | 4 parallel    | Isolated worktrees, all from same base SHA       | 1 combined review |
| 4b   | 3 parallel    | Isolated worktrees, all from same base SHA       | 1 combined review |

Total: **11 agents across 3 review batches.** Plus a `W3.X` cleanup task (XCTest → Swift Testing + envelope helper) that lands in the Wave-3 batch.

---

## Out of scope (entire project)

- CoreML / MLX on-device embedding model — protocol + Mock only.
- Signed export bundles — scaffold only; no Ed25519 key handling.
- Launchd plist for `imsg serve` — documented, never installed.
- Cloud LLM streaming in compose — single-shot completion only.
- Cross-device sync of search index, outbox, drafts, or rules state.
- Writes against `chat.db` — read-only forever.
- AppleScript surface beyond `MessageSender` and `react` paths.

---

## How to pick this up next session

1. `git fetch origin && git checkout claude/top-10-improvements-pTpkb && git pull`.
2. Read `TASKS.md` (this file), `docs/SCHEMA.md`, `docs/mcp.md`, `docs/outbox.md` for landed context.
3. Read the four foundation docs: `docs/serve.md` (for W3.M context), `docs/rules.md` (W3.T), `docs/compose.md` (W3.H), `docs/contacts.md` (W3.C).
4. Start Wave 3 by launching `W3.M` (the watcher fanout refactor) — it has the highest blast radius. Use the pinned-base preamble. Review the diff manually before continuing.
5. After all four Wave-3 tasks land, kick off Wave 4a as four parallel isolated-worktree agents. Then Wave 4b as three parallel agents.
6. End with a final `imsg` README + CHANGELOG pass that documents every new command, flag, and env var. Bump version in `version.env`.

Branch tip when this plan was written: `188b6f3`.
