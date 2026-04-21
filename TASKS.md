# imsg — Top 10 Improvements: Task Graph

Branch: `claude/top-10-improvements-pTpkb`
Status: scaffolding landing; implementation in waves.

## Legend
- ID prefix = group. Dependencies listed after `deps:`.
- `file:` = primary file(s) the task owns. Parallel-safe tasks own **disjoint** files.
- `wave:` = which parallel wave the task belongs to.
- `agent:` = yes means eligible to run as an isolated sub-agent worktree.

## Groups (map to the ranked top 10)

| Group | Title                                                     | Idea # |
|-------|-----------------------------------------------------------|--------|
| A     | Schema versioning                                         | 6      |
| B     | MCP server (`imsg mcp`)                                   | 1      |
| C     | Long-lived socket server (`imsg serve`)                   | 7      |
| D     | Semantic / FTS search (`imsg search`)                     | 2      |
| E     | Rules engine (`imsg rules`)                               | 3      |
| F     | Outbox + delivery verification                            | 4      |
| G     | Derived-field enrichment (OCR / unfurl / transcripts)     | 5      |
| H     | Contacts graph (`imsg who`, `imsg graph`)                 | 8      |
| I     | Compose pipeline (`imsg compose`)                         | 9      |
| J     | Export / import bundles (`imsg export`)                   | 10     |

---

## Wave 0 — shared scaffolding (done on main line, NOT parallel)

- W0.1 Register new command stubs in `CommandRouter.swift`, add stub files in `Sources/imsg/Commands/`.
- W0.2 Add `Sources/IMsgCore/SchemaVersion.swift` (constant + module doc).
- W0.3 Add `docs/TASKS.md` pointer, keep this file as source of truth.
- W0.4 Add `Tests/IMsgCoreTests/SchemaVersionTests.swift` smoke test.

Blocks: all other waves.

---

## Wave 1 — docs + schema + design notes (parallel-safe, disjoint files)

Each task owns a new file in `docs/` or a brand-new module file. No shared edits.

- W1.A1 `docs/SCHEMA.md` + `docs/schema/v1.json` — JSON Schema for message/chat payloads; deps: W0.2.
- W1.B1 `docs/mcp.md` — design for `imsg mcp` (tools, resources, capability map to existing RPC); deps: W0.1.
- W1.C1 `docs/serve.md` — design for long-lived socket server (socket path, handshake, replay, fanout); deps: W0.1.
- W1.D1 `docs/search.md` — design for FTS5 index layout + embedding roadmap; deps: W0.1.
- W1.E1 `docs/rules.md` — rules DSL grammar (TOML), action types, safety model; deps: W0.1.
- W1.F1 `docs/outbox.md` — outbox schema, idempotency, verification tail loop; deps: W0.1.
- W1.G1 `docs/enrichment.md` — OCR/unfurl/transcript pipeline + flags; deps: W0.1.
- W1.H1 `docs/contacts.md` — Contacts framework bridge, stable contact_id, graph export format; deps: W0.1.
- W1.I1 `docs/compose.md` — provider abstraction, safety gates, draft store; deps: W0.1.
- W1.J1 `docs/export.md` — bundle layout, manifest hashing, round-trip differ; deps: W0.1.

Up to 10 parallel agents. All files new, no shared edits.

---

## Wave 2 — module skeletons in IMsgCore (parallel-safe)

Adds empty-but-compiling type definitions. No behavior yet. Each task = one new file.

- W2.A1 `Sources/IMsgCore/SchemaEnvelope.swift` — envelope that wraps emitted payloads with `schema_version`; deps: W0.2.
- W2.B1 `Sources/IMsgCore/MCP/MCPTypes.swift` — MCP request/response structs; deps: W0.2.
- W2.C1 `Sources/IMsgCore/Serve/SocketServerTypes.swift` — session/state types; deps: W0.2.
- W2.D1 `Sources/IMsgCore/Search/SearchIndex.swift` — protocol + FTS5 stub; deps: W0.2.
- W2.E1 `Sources/IMsgCore/Rules/RuleModel.swift` — rule/action AST; deps: W0.2.
- W2.F1 `Sources/IMsgCore/Outbox/OutboxStore.swift` — sqlite schema for outbox; deps: W0.2.
- W2.G1 `Sources/IMsgCore/Enrichment/Enricher.swift` — enrichment protocol + no-op impl; deps: W0.2.
- W2.H1 `Sources/IMsgCore/Contacts/ContactsBridge.swift` — protocol + stub; deps: W0.2.
- W2.I1 `Sources/IMsgCore/Compose/Provider.swift` — provider protocol + MockProvider; deps: W0.2.
- W2.J1 `Sources/IMsgCore/Export/BundleManifest.swift` — manifest struct + hashing; deps: W0.2.

Up to 10 parallel agents.

---

## Wave 3 — command implementations (parallel-safe, each owns its command file)

Each task owns exactly one stub command file created in W0.1, plus one `Tests/imsgTests/<Name>CommandTests.swift`.

- W3.A1 SchemaEnvelope wired into `ChatPayload`/`MessagePayload` gated by `IMSG_SCHEMA=v1` env; deps: W2.A1.
- W3.B1 `imsg mcp` minimal MCP stdio loop delegating to existing RPC handlers; deps: W2.B1.
- W3.C1 `imsg serve --socket <path>` unix-socket accept loop; deps: W2.C1.
- W3.D1 `imsg search "query"` FTS5 query over an opt-in index; deps: W2.D1.
- W3.E1 `imsg rules run --config <path>` reading TOML (native, no new dep); deps: W2.E1.
- W3.F1 `imsg outbox enqueue|list|verify` under existing `send` family; deps: W2.F1.
- W3.G1 `watch --enrich ocr,unfurl,transcript`; deps: W2.G1.
- W3.H1 `imsg who <handle>` + `imsg graph --json`; deps: W2.H1.
- W3.I1 `imsg compose --chat-id <id> --prompt <file>`; deps: W2.I1.
- W3.J1 `imsg export --chat-id <id> --out <dir>`; deps: W2.J1.

Each agent edits only its own command + test file. No shared edits.

---

## Wave 4 — integration + QA (sequential on main line)

- W4.1 Add integration tests that round-trip schema version across RPC.
- W4.2 Update README with new commands + feature flags.
- W4.3 Update CHANGELOG under Unreleased.

---

## Parallelism plan

| Wave | Max agents | Gate                                     |
|------|------------|------------------------------------------|
| 0    | 1 (me)     | clean branch                             |
| 1    | 10         | W0 committed                             |
| 2    | 10         | W1 merged + build green                  |
| 3    | 10         | W2 merged + build green                  |
| 4    | 1          | W3 merged + tests green                  |

Merge strategy: each agent runs in `isolation: "worktree"`, returns a branch; main thread merges them sequentially using `git merge --no-ff` after a local build check.

---

## Non-goals for this branch
- Actual on-device embedding model (MLX/CoreML) — ships scaffolding only.
- Distributed / remote MCP transport — stdio only.
- AppleScript API expansion — treat existing send surface as fixed.
- Signing of export bundles — scaffold only; signing keys out of scope.
