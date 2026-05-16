# Search

Goal: fast, local, private full-text and semantic search over the user's iMessage
history. `chat.db` stays read-only and untouched; all search state lives in a
separate index owned by imsg.

This document covers the v1 design for `imsg search` (FTS5) and scaffolding for
the v2 on-device embedding index (MLX/CoreML). It is a design doc, not a
reference — the CLI surface and schema below are the contract v1 will ship.

## Non-goals (v1)

- Cross-device sync of the index.
- Cloud embeddings or any network egress of message text.
- Search over raw attachment bytes (PDFs, audio). Only *derived* OCR and
  transcript text produced by the enrichment pipeline is indexed.
- Fuzzy sender-name resolution beyond the handles already joined in chat.db.
- Writing back to `chat.db`. Ever.

## Storage layout

All index state lives under:

```
~/Library/Application Support/imsg/index/
  v1/
    fts.sqlite               # FTS5 + metadata
    embeddings.sqlite        # vectors + neighbor lists (v2, scaffolded in v1)
    progress.json            # backfill progress, written by `serve`
    cursor.json              # { chat_id: last_indexed_rowid } checkpoints
  v2/                        # future; schema bump creates a new subdir
```

Versioned subdirectories let us reindex from scratch on schema bumps without
deleting the previous generation — useful for rollback during development. The
active version is selected by a constant in the binary, not by filesystem
probing; stale subdirs are garbage-collected by `imsg search index reset`.

Permissions on `index/` are `0700`. The directory is created lazily on first
build.

## Build command

```
imsg search index build [--since <date>] [--enrich] [--full]
imsg search index reset
imsg search index status
```

- `build` is incremental by default. For each chat it reads
  `cursor.json → chat_id.last_indexed_rowid`, pulls new rows from `chat.db`
  ordered by `ROWID`, and upserts them into `messages_fts`. On success it
  advances the cursor and fsyncs.
- `--since <date>` restricts the scan window for a one-off catch-up; it does
  not move the cursor backwards.
- `--enrich` also indexes OCR/transcript text emitted by the attachment
  enrichment pipeline (separate component, out of scope here). Without the
  flag, only `message.text` / `attributedBody` text is indexed.
- `--full` forces a full reindex into the current version subdir. Equivalent to
  `reset` + `build`, but preserves the vector store.
- `reset` wipes `v<current>/` and restarts. Used when the schema bumps or when
  the user suspects corruption.
- `status` prints `{ chats_indexed, messages_indexed, last_run, lag_rows }`.

Incremental correctness: messages in `chat.db` are append-mostly, but edits
and tapbacks mutate existing rows. v1 treats `(ROWID, date_read)` as a
fingerprint; when the fingerprint changes we re-upsert that row by `rowid`.
Deletions are handled by a periodic sweep that compares `COUNT(*) per chat_id`
between `chat.db` and the index and forces a repair on mismatch.

## FTS5 schema

FTS5 contentless-external mode. The *external content* table is our own
`messages` mirror inside `fts.sqlite`, **not** `chat.db`. This keeps chat.db
untouched and lets us own the schema.

```sql
-- fts.sqlite
CREATE TABLE messages (
  rowid       INTEGER PRIMARY KEY,   -- mirrors chat.db message.ROWID
  chat_id     INTEGER NOT NULL,
  sender      TEXT,                  -- resolved handle id / display name
  text        TEXT,                  -- message.text or decoded attributedBody
  created_at  INTEGER NOT NULL,      -- unix seconds (UTC)
  fingerprint TEXT NOT NULL          -- for incremental upsert
);
CREATE INDEX messages_chat_time ON messages(chat_id, created_at);

CREATE VIRTUAL TABLE messages_fts USING fts5(
  text,
  sender,
  chat_id    UNINDEXED,
  rowid      UNINDEXED,
  created_at UNINDEXED,
  content = 'messages',
  content_rowid = 'rowid',
  tokenize = 'unicode61 remove_diacritics 2',
  prefix = '2 3'
);
```

Notes:

- `tokenize = 'unicode61 remove_diacritics 2'` folds diacritics (café ≡ cafe)
  and lowercases. We additionally wrap with the Porter stemmer via a custom
  tokenizer chain registered at open time (`porter unicode61 …`) so English
  queries stem. Non-English text falls through unstemmed, which is the
  desired behavior.
- `prefix = '2 3'` precomputes 2- and 3-char prefix indexes so typeahead
  queries (`dinn*`) don't require a full scan.
- `contentless` external-content means FTS stores only the tokenized form and
  we are responsible for keeping `messages` in sync via `INSERT/UPDATE/DELETE`
  triggers on the external table. The triggers live in the same DB.

Why not attach `chat.db` as external content? Two reasons: (a) we don't want
FTS triggers depending on a file we only open read-only and whose schema
Apple can change at any macOS update; (b) attributedBody decoding happens at
index time in Swift, and the decoded plaintext is what we want tokenized —
not the archived blob.

## Query surface

```
imsg search -q "dinner plans" [options]
```

Options:

| Flag                | Default | Effect                                                     |
|---------------------|---------|------------------------------------------------------------|
| `--limit N`         | 20      | Cap result rows.                                            |
| `--chat-id N`       | —       | Restrict to one chat.                                       |
| `--since <date>`    | —       | ISO8601 or relative (`7d`, `2026-01-01`).                   |
| `--until <date>`    | —       | Upper bound, same parsing.                                  |
| `--sender <handle>` | —       | Exact handle match (email or phone).                        |
| `--order time`      | bm25    | Order by `created_at DESC` instead of relevance.            |
| `--json`            | off     | Emit one JSON object per line to stdout.                    |
| `--semantic`        | off     | Blend embedding similarity into ranking (v2, see below).    |
| `--alpha F`         | 0.6     | Blend weight for FTS vs embedding; `1.0` = pure FTS.        |

Default text output:

```
[123] alice@example.com: let's do dinner tomorrow — 2026-04-20T18:22:10Z
[123] bob:               works for me, 7pm? — 2026-04-20T18:25:44Z
```

JSON output (`--json`, one object per line):

```json
{"chat_id":123,"rowid":98421,"sender":"alice@example.com","text":"let's do dinner tomorrow","created_at":"2026-04-20T18:22:10Z","score":4.21}
```

Query translation: the user's raw query is passed to FTS5 via the MATCH
operator after we escape bareword double quotes. Phrase queries (`"dinner
plans"`) and column filters (`sender:alice`) pass through. Invalid FTS syntax
falls back to a tokenized OR query so typos don't produce zero results.

Ranking: FTS5 bm25 with column weights `text=1.0, sender=0.2`. The
`--order time` flag bypasses bm25 and orders by `created_at DESC` with a
secondary tiebreak on `rowid DESC`.

## Embedding index (scaffolded in v1, active in v2)

### Provider protocol

```swift
public protocol EmbeddingProvider {
    var id: String { get }          // e.g. "mock-v1", "coreml-minilm"
    var dim: Int { get }
    func embed(texts: [String]) throws -> [[Float]]
}
```

Implementations registered in v1:

- `MockProvider` — deterministic hash-based pseudo-embedding (SHA256 →
  [Float]). Exists so the end-to-end plumbing, SQL schema, and blended
  ranking can be tested without a model. Used in fixtures and CI.
- `CoreMLProvider` — stub that loads a `.mlpackage` from `Resources/`. In v1
  it is compiled but guarded by `--semantic` being off by default; calling
  `embed` throws `.unimplemented`. v2 lights it up.
- `MLXProvider` — future. Placeholder file with a one-line `TODO` so the
  registry wiring is obvious.

### Storage

```sql
-- embeddings.sqlite
CREATE TABLE meta (
  provider_id TEXT PRIMARY KEY,
  dim INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE vectors (
  rowid INTEGER PRIMARY KEY,      -- matches messages.rowid
  provider_id TEXT NOT NULL,
  vec BLOB NOT NULL               -- dim × float32, little-endian
);
CREATE TABLE neighbors (
  rowid INTEGER NOT NULL,
  nbr_rowid INTEGER NOT NULL,
  dist REAL NOT NULL,
  PRIMARY KEY (rowid, nbr_rowid)
);
```

v1 ships with linear scan over `vectors` because corpora are small (typical
users have O(100k) messages; 384-dim float32 ≈ 150MB, fits in RAM). The
`neighbors` table is reserved for a v2 HNSW-style graph built offline; its
presence in v1 keeps the schema stable across versions.

### Blending

With `--semantic`:

1. Run the FTS query, collect top `K = max(limit × 5, 200)` candidates with
   their bm25 scores normalized to `[0,1]`.
2. Embed the query once. Score each candidate by cosine similarity against
   its stored vector (also normalized).
3. Final score `= alpha * fts_norm + (1 - alpha) * emb_norm`. Default
   `alpha = 0.6` — FTS-leaning, because precision on proper nouns matters
   more than semantic recall in chat search.
4. Sort, take top `limit`.

If the corpus has no embeddings yet (provider unchanged), `--semantic` logs a
warning and falls back to pure FTS.

## Privacy

- The index never leaves the device. There is no `--export-index` flag, and
  adding one is explicitly out of scope. If a user wants to back up their
  Mac, Time Machine already covers Application Support.
- No telemetry reports query text, hit counts, or corpus size.
- The embedding provider contract forbids network I/O; the CI lint checks
  that provider implementations do not import `URLSession` / `Network`.
- Log lines emitted during indexing redact message text; only rowids and
  chat ids are logged at `info`. `--verbose` can include tokens but is
  opt-in.

## Reindex triggers

A full reindex into a fresh `v<n>/` directory happens when:

- The compiled schema version constant changes (schema bump on release).
- The user runs `imsg search index reset`.
- Integrity check fails: `PRAGMA integrity_check` on `fts.sqlite` returns
  anything other than `ok`.
- The embedding provider id changes (handled at the vector layer only — FTS
  is untouched).

Partial repair (without a full reindex) happens when the chat-level sanity
sweep detects a row-count mismatch; only the affected chat's cursor is
rewound.

## Backfill strategy

First-run indexing of a multi-year iMessage history can take minutes. It
runs in the background behind `imsg serve` (the long-lived gateway process,
see `docs/rpc.md`) so the first `imsg search` call returns partial results
rather than blocking.

- `serve` spawns an indexing worker on startup if
  `cursor.json` is empty or `lag_rows > threshold`.
- The worker writes `progress.json` every N rows:
  ```json
  { "started_at": "…", "chats_total": 312, "chats_done": 87,
    "messages_done": 14203, "messages_total_est": 82010, "rate_per_s": 1850 }
  ```
- `imsg search index status` reads the same file.
- Search queries run against whatever is already committed. FTS5 `MATCH`
  against a partially populated index is safe; results are just incomplete.

The worker yields CPU via small batches (1000 messages per transaction) so
foreground search stays responsive.

## Testing

Unit:

- Tokenizer folds diacritics (`café` matches `cafe`).
- Porter stem matches `running` for query `run`.
- `--since` / `--until` / `--chat-id` / `--sender` filters each round-trip.
- `MockProvider` yields stable vectors across runs.
- Blended ranking with `alpha=1.0` is byte-identical to non-semantic output.

Fixture:

- `Tests/Fixtures/chat-100.db`: a synthetic chat.db with 100 messages
  across 3 chats, including emoji, diacritics, a tapback, and an edited
  message. Checked into git; regenerated by `scripts/make-fixture.swift`.
- Recall assertions: given known query → known-rowid set, assert the rowid
  set is a subset of the returned results. We assert *recall*, not exact
  order, because bm25 scoring is sensitive to tokenizer tweaks.

Integration:

- End-to-end: build index → query → reset → rebuild → query returns same
  results.
- Semantic path with `MockProvider` + `alpha=0.0` returns deterministic top-k.

## Open questions (tracked, not blocking v1)

- Do we want a `--regex` escape hatch for power users? FTS5 does not support
  regex directly; would require a post-filter pass.
- Thread-aware ranking: boost results from chats the user recently opened.
  Needs a signal source we don't currently have.
- Attachment OCR quality gating: some OCR outputs are noisy enough to hurt
  precision. Could be behind an `--enrich-quality=high` flag later.
