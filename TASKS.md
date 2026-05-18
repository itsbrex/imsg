# imsg — Top-10 Improvements: Execution Plan

> **Source of truth for the multi-wave implementation.** Update this file as waves land. Current state is merged to `main`.

## Status snapshot (last updated: Wave 4a complete; Wave 4b queued)

| Wave | Scope | State | Tip commit |
|------|-------|-------|-----------|
| 0    | Scaffolding (TASKS, SchemaVersion module, 9 command stubs, CommandRouter wiring) | ✅ shipped | `0ab81c0` |
| 1    | 10 design docs (~3,400 lines) — one per top-10 idea | ✅ shipped | `ea39b28` |
| 2a   | Schema envelope `{schema, kind, data}` (opt-in via `IMSG_SCHEMA=v1`) | ✅ shipped | `5a03950` |
| 2b   | `imsg mcp` stdio Model Context Protocol server | ✅ shipped | `1e677ac` |
| 2c   | `imsg outbox` queued send with delivery verification + `imsg send --via-outbox` | ✅ shipped | `188b6f3` |
| —    | Upstream sync (0.5.0 → 0.9.1, 85 commits) — bridge, refactors, ~25 new commands | ✅ merged | `7601b15` |
| 3    | Foundation refactors (watcher fanout, TOML, HTTP, contacts bridge) | ✅ shipped (W3.M + W3.T + W3.H + W3.C) | — |
| 4a   | Features: enrichment, export, graph (search dropped — upstream ships it) | ✅ shipped (W4.X + W4.W + W4.E library; W4.E CLI wiring deferred) | — |
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
| 5  | Enrichment (OCR / unfurl / transcripts)   | library             | `docs/enrichment.md` | ✅ library shipped; CLI wiring deferred |
| 6  | Schema envelope                           | n/a (env var)       | `docs/SCHEMA.md`     | ✅ shipped (W2a) |
| 7  | Long-lived socket server                  | `imsg serve`        | `docs/serve.md`      | stub — W4b (W4.V) |
| 8  | Contacts + interaction graph              | `imsg who`/`graph`  | `docs/contacts.md`   | ✅ MVP shipped (W4.W). Note: upstream also ships `imsg whois` for bridge reachability checks. |
| 9  | Compose (LLM-drafted replies)             | `imsg compose`      | `docs/compose.md`    | stub — W4b (W4.C) |
| 10 | Portable chat bundles                     | `imsg export`       | `docs/export.md`     | ✅ MVP shipped (W4.X) |

---

## Wave 3 — foundation refactors

These unblock multiple Wave-4 features. **Land sequentially**, one review batch per task, so any concurrency/permissions issues are caught before parallel work starts.

### W3.M — MessageWatcher multi-consumer fanout ✅
Unblocks: W4.V (serve), W4.R (rules), W4.E (enrichment).
- `Sources/IMsgCore/MessageWatcher.swift` is now an `actor` with a private `FileObserver` wrapper around `DispatchSourceFileSystemObject`. The observer is created lazily on first subscribe and torn down when the last subscriber drops. Each subscriber owns its own cursor + chatID filter; one shared fallback poll runs at the minimum interval across subscribers.
- The public `stream(chatID:sinceRowID:configuration:) -> AsyncThrowingStream<Message, Error>` API is preserved (now `nonisolated`); `WatchCommand`, `RPCServer+Handlers`, and `MCPHandlers` compile unchanged.
- New: `Tests/IMsgCoreTests/MessageWatcherFanoutTests.swift` covers (a) two subscribers each see every row exactly once, (b) cancellation of one consumer leaves the other running, (c) per-subscriber chat filters are independent.

### W3.T — Hand-rolled TOML subset ✅
Unblocks: W4.R (rules).
- `Sources/IMsgCore/Config/TOML.swift` parses the documented subset: `[table]` / `[[array-of-tables]]` headers (with dotted segments), bare + quoted keys, basic strings with the standard escapes (including `\uXXXX`), triple-quoted basic strings (leading-newline trim), signed integers + floats with `_` separators, booleans, arrays (multi-line, trailing comma), inline tables, and `#` comments. The supported grammar is documented in the file's leading comment block.
- No new Swift Package dependency. Output is a `TOMLValue` tree with typed accessors; "unknown key" enforcement is the caller's responsibility (the rules schema validator owns that).
- Errors carry line + column. Duplicate top-level keys, duplicate table headers, unterminated strings, invalid escapes, and newlines inside single-line strings are rejected.
- `Tests/IMsgCoreTests/TOMLTests.swift` covers scalars, escapes, triple-quoted strings, arrays, inline tables, `[[rule]]` arrays-of-tables, a realistic rules.toml fixture, and the negative cases above.

### W3.H — URLSession HTTP helper ✅
Unblocks: W4.C (compose), W4.R webhook action, W4.E unfurl.
- `Sources/IMsgCore/Net/HTTP.swift` is a small HTTPS-by-default client with a 10s default timeout, a `RetryPolicy` (3 attempts, exponential backoff with jitter, configurable), a response size cap (default 1 MiB), a denylist of transport-control headers (`Host`, `Content-Length`, `Connection`, etc.), and optional HMAC-SHA256 body signing that adds `X-Imsg-Signature: sha256=<hex>` + `X-Imsg-Timestamp` (matches the contract in `docs/rules.md`).
- Pure stdlib: `URLSession` + `CryptoKit`, no new dependency. Transport is abstracted behind `HTTPTransport` (with a `URLSessionTransport` default) so tests can drive the helper without touching the network.
- Retry on `408`, `429`, and `5xx`; immediate failure on other `4xx` (`HTTPError.nonRetryableStatus`); `HTTPError.retriesExhausted(lastStatus:)` when the policy runs out; transport throws are retried and surfaced as `.transport`.
- `Tests/IMsgCoreTests/HTTPTests.swift` covers HTTPS-only enforcement (and the `allowInsecureScheme` override), success, 429 → retry → success, 5xx exhaustion, immediate 4xx failure, transport-error retries, response-size cap, HMAC header shape, transport-header stripping, and method/body forwarding. Backoff is short-circuited via an injected sleeper so the suite stays sub-second.

### W3.C — Contacts bridge protocol ✅
Unblocks: W4.W (who/graph).
- Shipped as a thin wrapper over the upstream `ContactResolving`: `Sources/IMsgCore/Contacts/Contact.swift` (record type — `name` + `handle`), `Sources/IMsgCore/Contacts/ContactsBridge.swift` (`protocol ContactsBridge { func find(handle:) async throws -> Contact? }` plus `ResolverContactsBridge`, `NoOpContactsBridge`, and `InMemoryContactsBridge` for tests), and `Sources/IMsgCore/Contacts/ContactsCache.swift` (actor-backed TTL cache, defaults to 24h, caches negative hits, supports per-handle and bulk invalidation, injectable clock).
- `Sources/imsg/Resources/Info.plist` gains `NSContactsUsageDescription`.
- The original plan called for a SQLite cache at `~/Library/Application Support/imsg/contacts.sqlite`. Deferred — upstream `ContactResolver` already loads the full address book up front, so per-handle lookups are cheap and a process-local cache is sufficient. Persistent cache is a follow-up if profiling shows we need it.
- `Tests/IMsgCoreTests/ContactsBridgeTests.swift` covers `InMemoryContactsBridge`, `NoOpContactsBridge`, `ResolverContactsBridge` (against a fake `ContactResolving`), and `ContactsCache` (hit, miss caching, TTL expiry with an injected clock, manual invalidation).

---

## Wave 4a — independent features (4 parallel agents)

Each agent owns a disjoint directory and a fillable command stub.

### W4.E — Enrichment pipeline ✅ (library; CLI wiring deferred)
- `Sources/IMsgCore/Enrichment/Enricher.swift` — `Enricher` protocol, `EnrichmentField` / `EnrichmentValue` / `EnrichmentContext` / `EnrichmentResult` value types, and `EnrichmentChain` (concurrent runner with `TaskGroup`, deterministic merge in registration order, failing enrichers logged via `onError` without breaking the chain).
- `Sources/IMsgCore/Enrichment/UnfurlEnricher.swift` — extracts HTTPS URLs (via `NSDataDetector`, capped per message), fetches each via the W3.H `HTTP` helper (HTTPS-only, size-capped, single attempt), and emits a compact `unfurl: [{url, title, og_title, og_description, og_image}, …]` field. `HTMLMetaScraper` is a small regex-based helper for `<title>` + OpenGraph meta tags — fine for the unfurl path, intentionally not a full HTML parser.
- `Sources/IMsgCore/Enrichment/TranscriptEnricher.swift` — reads the pre-existing transcription stored in `attachment.user_info` (via the new `MessageStore.audioTranscriptionPublic(for:)` shim around the existing internal helper). v1 does not re-transcribe on device.
- `Sources/IMsgCore/Enrichment/OCREnricher.swift` — `OCREnricher` protocol with `VisionOCREnricher` (macOS-only, `VNRecognizeTextRequest`, per-attachment timeout via `withThrowingTaskGroup`, accurate recognition + language correction) and `NoOpOCREnricher` for non-Apple builds / tests.
- `Tests/IMsgCoreTests/EnrichmentTests.swift` — chain (order, failing enricher), HTML scraper happy path + nil cases, HTTPS-only URL extraction, full `UnfurlEnricher` round-trip over a fake transport, `TranscriptEnricher` present / absent / empty.
- Deferred follow-up: wiring `--enrich ocr,unfurl,transcript` into `WatchCommand`, `HistoryCommand`, and `McpCommand`. The library is in place; the CLI integration is a separate, focused change so the cross-cutting touch can land under its own review.

### W4.S — Search (FTS5 tier only)
- `Sources/IMsgCore/Search/SearchIndex.swift` — protocol.
- `Sources/IMsgCore/Search/FTS5Index.swift` — `~/Library/Application Support/imsg/index/v1/messages.sqlite`. FTS5 with porter stemmer + `unicode61`. Incremental builder keyed on `last_indexed_rowid` per chat.
- `Sources/IMsgCore/Search/EmbeddingProvider.swift` — protocol + `MockProvider` only (deterministic hash). CoreML/MLX deferred.
- Fill `Sources/imsg/Commands/SearchCommand.swift` — `index build|reset`, query with `--limit/--chat-id/--since/--sender`, `--json` envelope output.
- Tests: `Tests/IMsgCoreTests/FTS5IndexTests.swift` (fixture chat.db → assert recall), `Tests/imsgTests/SearchCommandTests.swift`.
- **Note:** also add a `tools/call imsg.search` handler in `Sources/imsg/MCP/MCPHandlers.swift` that currently returns `-32601`; remove that stub now that the feature exists.

### W4.X — Export bundles ✅ (MVP)
- `Sources/IMsgCore/Export/BundleManifest.swift` — `BundleManifest` / `BundleSource` / `BundleCounts` (snake_case JSON via `CodingKeys`) + `BundleHasher` (sha256-hex of bytes).
- `Sources/IMsgCore/Export/BundleWriter.swift` — pure-data writer that takes a fetched `ExportSource` (so it's testable without `MessageStore`). Deterministic output: messages sorted by `(created_at, rowid)`, reactions by `(created_at, rowid)`, attachments by lex filename, JSON keys sorted at every depth via `JSONSerialization` `.sortedKeys`, JSONL files terminated with `\n` and `manifest.json` / `meta.json` pretty-printed with trailing newline. ISO-8601 UTC timestamps with second precision (`.SSS` only when the source has sub-second resolution). Refuses non-empty output directories.
- `Sources/IMsgCore/Export/BundleVerifier.swift` — re-hashes every file listed in `manifest.hashes`, compares counts, reports `mismatchedHashes` / `missingFiles` / `unexpectedFiles` / `countDeltas` via `BundleDriftReport`.
- `Sources/IMsgCore/Export/BundleDiffer.swift` — keys messages by `id.guid`, reports `addedMessages` / `removedMessages` / `editedMessages` (text + attachment-set delta) and a coarse symmetric reaction delta keyed by `(target, action, sender, type)`.
- `Sources/imsg/Commands/ExportCommand.swift` now does work: `--action=export|verify|diff` (default `export`), `--chat-id` / `--out` for export, `--in` for verify, `--in` + `--other` for diff. JSON output via `--json`. Verify / diff exit non-zero on drift.
- `Tests/IMsgCoreTests/BundleRoundtripTests.swift` covers layout, deterministic byte-for-byte equality across two runs, message ordering, verifier clean / hash mismatch / missing file / unexpected file, differ identical / added / removed / edited.
- Deferred (per project "Out of scope" list): attachment-bytes copy + per-attachment sha256, `--redact-handles` + side-car redaction map, `--all`, `--since`/`--until`, `--shard-by`, `--tar-zst`, Ed25519 `--sign-with`, and `imsg import`. The MVP is "metadata-only mode" from `docs/export.md`; the bundle is reproducible and verifiable without ever copying attachment payloads.

### W4.W — Contacts (`who`) and interaction graph (`graph`) ✅
Depends on W3.C (`ContactsBridge`).
- `Sources/IMsgCore/Graph/InteractionGraph.swift` — `GraphNode` / `GraphEdge` / `GraphWindow` / `InteractionGraph` value types.
- `Sources/IMsgCore/Graph/GraphBuilder.swift` — takes a list of `Message` rows + a `chats: [Int64: ChatInfo]` map + an injected `ContactsBridge` and aggregates per-`(contact, chat)` edges with `count`, `inbound`, `outbound`, `lastAt`. Reactions are skipped; outbound (`is_from_me`) messages collapse under a synthetic `Me` contact id. Edges are returned ordered by count desc (tiebreak contact asc, then chat asc) so the output is stable. Resolved contact display names become the `contact_id`; unresolved handles fall back to the raw handle. The fuller `sha256(...)` id-synthesis pipeline from `docs/contacts.md` is deferred — the simpler scheme is sufficient for the edge-aggregation use case and stays stable across runs because the inputs are stable.
- `Sources/IMsgCore/Graph/GraphExporter.swift` — schema-envelope JSON (`{schema:"v1",kind:"graph",data:{...}}`, sorted keys at every depth) and Graphviz DOT (`digraph imsg`, ellipses for contacts + boxes for chats, edge labels carry the count).
- `Sources/imsg/Commands/WhoCommand.swift` — `--handle <h>` resolves a single handle via the bridge, `--chat-id <n>` lists all chat participants (each handle resolved against the same bridge). Default text output emits `<name> <<handle>>`; `--json` emits an object with `source: "contacts" | "fallback"`. `bridgeFactory` and `storeFactory` are injectable for testing.
- `Sources/imsg/Commands/GraphCommand.swift` — `--chat-id` restricts to a single chat (default: all chats up to 1000), `--since` accepts ISO-8601 or relative `NNd` / `NNw`, `--until` accepts ISO-8601, `--limit` caps messages scanned (default 50k), `--dot` selects Graphviz output (default JSON).
- Deferred (out of scope for the MVP): `--top K`, `--metrics` (cadence + direction imbalance), `--redact`, `--refresh`, photo data, the full `sha256(contact)` id pipeline, group-handle special casing.
- `Tests/IMsgCoreTests/GraphBuilderTests.swift` covers per-`(contact, chat)` aggregation with inbound/outbound + lastAt, reaction filtering, fallback when the bridge returns nil, count-desc ordering, JSON-envelope shape, and DOT rendering.

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
