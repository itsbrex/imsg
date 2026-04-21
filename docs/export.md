# Export Bundles

Goal: a portable, reproducible, diffable bundle that represents a single chat
(or a set of chats) as plain files. Produced by `imsg export`; verified and
compared by `imsg export verify` / `imsg export diff`; consumed (eventually) by
`imsg import`. Bundles never embed `chat.db`.

## Design principles

- **Plain files, no DB.** JSONL + JSON + blobs. Anyone with `sha256sum`, `jq`,
  and a text editor can audit a bundle without imsg.
- **Deterministic.** Two exports of the same source data on the same schema
  version produce byte-identical files. This makes diffs meaningful and
  enables content-addressed archival.
- **Stream-friendly.** `messages.jsonl` and `reactions.jsonl` are line-delimited
  so they can be tailed, grep-ed, and streamed into other tools.
- **Privacy-first.** Redaction is opt-in but supported natively; the mapping
  from redacted ids to real handles is never written to the main bundle.
- **Evolvable.** Schema version is pinned in the manifest. Minor versions may
  add fields; removing a field requires a major bump.

## Bundle layout

```
<bundle>/
  manifest.json          # schema, version, counts, hashes, source_guid
  messages.jsonl         # one message per line, envelope-wrapped (schema v1)
  attachments/
    by-guid/<guid>/<filename>
  reactions.jsonl        # separate stream for tapbacks
  participants.json      # contact_id + handles (redaction-friendly)
  meta.json              # chat metadata
```

Notes:

- `attachments/by-guid/<guid>/<filename>` preserves the Messages-assigned GUID
  as the directory name and the user-visible filename inside. Collisions are
  impossible because the GUID dir scopes them. Empty attachment set => the
  `attachments/` directory is omitted.
- `reactions.jsonl` is split from `messages.jsonl` so that tapback churn does
  not change the hash of the main message stream.
- `participants.json` is stable across exports of the same chat even when the
  message window narrows (e.g. `--since`).
- There is no nested bundle. A `--all` export produces one top-level subdir
  per chat under the output dir; each subdir is a full, independent bundle.

### `manifest.json`

```json
{
  "schema": "v1",
  "created_at": "2026-04-21T00:00:00Z",
  "imsg_version": "0.5.0",
  "source": { "chat_id": 42, "guid": "iMessage;+;chat123" },
  "counts": { "messages": 1234, "attachments": 17, "reactions": 88 },
  "hashes": {
    "messages.jsonl": "<sha256>",
    "reactions.jsonl": "<sha256>",
    "participants.json": "<sha256>",
    "meta.json": "<sha256>",
    "attachments/by-guid/<guid>/<file>": "<sha256>"
  },
  "redactions": []
}
```

- `schema` pins the envelope schema. v1 is defined here.
- `imsg_version` is informational (the producer build); it does **not**
  participate in compatibility decisions — `schema` does.
- `source.chat_id` is DB-local and only meaningful on the originating machine;
  `source.guid` is portable.
- `counts` is advisory (used to detect truncation quickly) and must agree with
  what `verify` recomputes.
- `hashes` covers every file in the bundle except `manifest.json` itself.
  Hashes are sha256, hex, **lowercase**. Keys are POSIX-style paths relative
  to the bundle root. Map keys are sorted lexicographically when serialized.
- `redactions` is an array of redaction descriptors (see Privacy) or `[]`.

### `meta.json`

```json
{
  "chat_id": 42,
  "identifier": "iMessage;+;chat123",
  "guid": "iMessage;+;chat123",
  "display_name": "Lunch Club",
  "is_group": true,
  "service": "iMessage"
}
```

### `participants.json`

```json
{
  "participants": [
    { "contact_id": "c_0001", "handles": ["+15551234567", "alice@example.com"], "display_name": "Alice" },
    { "contact_id": "c_0002", "handles": ["+15559876543"], "display_name": null }
  ]
}
```

`contact_id` is the stable id defined in `docs/contacts.md` (W1.H1). Under
`--redact-handles`, `handles` is replaced with `[]` and the mapping moves to
out-of-bundle `redactions.json`.

### `messages.jsonl` (schema v1 envelope)

One JSON object per line, `\n`-terminated, sorted keys. Each line is a full
envelope so a single line is self-describing:

```json
{"schema":"v1","type":"message","id":{"guid":"...","rowid":9001},"chat_id":42,"sender":{"contact_id":"c_0001"},"from_me":false,"created_at":"2026-04-21T12:00:00Z","text":"hi","attachments":[{"guid":"...","filename":"img.jpg","mime":"image/jpeg","sha256":"..."}],"reply_to":null,"service":"iMessage"}
```

Required keys on every message: `schema`, `type`, `id.guid`, `id.rowid`,
`chat_id`, `created_at`, `from_me`. All optional fields must be present with
`null` (not omitted) so that hash stability does not depend on writer mood.

### `reactions.jsonl`

Same envelope shape, `type: "reaction"`, with `target_guid` pointing at the
message being tapbacked and `action` in `{added, removed}`.

## Determinism

Two exports of the same DB state at the same schema version must be
byte-identical. Rules:

1. **Message order**: ascending `(created_at, rowid)`. `rowid` is the
   tiebreaker for messages sharing a timestamp. Never rely on insertion
   order.
2. **Reaction order**: ascending `(created_at, rowid)` on the reaction row
   itself (not the target message).
3. **Attachment file order on disk** is irrelevant to bytes on disk, but the
   `manifest.hashes` map keys are sorted lexicographically by path.
   `attachments[]` within a message is ordered by attachment filename
   lexicographically; ties broken by attachment GUID.
4. **JSON canonicalization**: sorted keys at every depth, UTF-8, no trailing
   whitespace, no BOM. JSONL lines are terminated with a single `\n` including
   the last line. `manifest.json` and `meta.json` are pretty-printed with
   2-space indent and a trailing newline; JSONL files are compact (no inner
   spaces).
5. **Timestamps** are ISO-8601 in UTC with `Z` suffix, second precision unless
   the source has sub-second resolution, in which case millisecond precision
   with exactly 3 fractional digits.
6. **Numeric fields** are emitted as integers when integral; floats use the
   shortest round-trip representation.
7. **Unknown/empty collections** serialize as `[]` or `{}`, never omitted.

A compliant writer that follows these rules will produce the same bytes on
any platform; a compliant `verify` only needs sha256 to confirm.

## CLI

```
imsg export --chat-id N --out <dir> [--since ISO] [--until ISO]
            [--attachments] [--redact-handles]
            [--shard-by month|rowid:<N>] [--tar-zst]
            [--sign-with <key.pem>]
imsg export --all --out <dir> [common flags]
imsg export verify <dir-or-tar>
imsg export diff <a> <b>
imsg import --dry-run <dir>   # scaffold only in v1
```

Flag semantics:

- `--chat-id` is required unless `--all`. Accepts a single integer; use
  repeated flags or `--all` for multiple chats.
- `--out` must point at an empty directory or a path that does not yet exist.
  The command will refuse to overwrite a non-empty directory without
  `--force`.
- `--since` / `--until` filter by `message.created_at` (inclusive / exclusive).
  They do not affect `participants.json` or `meta.json`.
- `--attachments` copies attachment bytes into the bundle. Without it,
  `attachments/` is omitted and per-message `attachments[].sha256` is still
  populated (so the manifest remains auditable even in "metadata-only" mode).
- `--redact-handles` enables redaction (see Privacy).
- `--shard-by` is documented under Large bundles.
- `--tar-zst` documented under Large bundles.
- `--sign-with` documented under Signing.

### `verify`

- Recomputes sha256 for every file listed in `manifest.hashes` and checks
  each against the manifest.
- Reports any file in the bundle **not** in `manifest.hashes` as `unexpected`.
- Reports any manifest entry whose file is missing as `missing`.
- Recounts `messages.jsonl` / `reactions.jsonl` / attachments and checks
  `manifest.counts`.
- Confirms stable ordering of message and reaction lines (detects tampering
  that preserves sha by coincidence — impossible with sha256, but the check
  doubles as a schema lint).
- Exit code 0 on clean, 1 on any drift. Machine-readable JSON report with
  `--json`.

### `diff`

- Pairs messages by `id.guid` across the two bundles. Output:
  - `added`, `removed`, `edited` (text / attachment set changed).
  - `attachments.added` / `attachments.removed` per message.
  - `reactions.delta` grouped by `target_guid`.
  - `participants.delta` (added, removed contact_ids).
  - `meta.delta` (display_name changes, etc.).
- Ignores ordering; reports by content. Byte-identical bundles diff empty.
- `--json` for machine-readable output; default is a human summary.
- Exit code 0 if bundles are equivalent, 1 if drift is reported.

### `import --dry-run` (scaffold)

- Parses the manifest, validates the schema version, runs `verify` internally,
  reports what would be inserted / updated / skipped. Writes nothing to
  `chat.db`. Actual insertion is out of scope for v1.

## Privacy

- Default export includes handles (phones / emails) inside
  `participants.json` and `sender` objects where present.
- `--redact-handles` replaces every handle with the corresponding
  `contact_id` and emits the mapping to a **separate** file written next to
  (not inside) the bundle:

  ```
  <out>/
    <bundle>/
    <bundle>.redactions.json     # NOT inside the bundle
  ```

  The main bundle's `manifest.redactions` then lists which fields were
  redacted (e.g. `["participants[].handles", "messages[].sender.handle"]`).
- The redaction map is never hashed into the manifest. Shipping a bundle
  never reveals the underlying handles unless the redactions file is shipped
  with it.
- Never embed `chat.db` (full or partial) inside a bundle.
- Never emit OS user paths, keychain material, or Apple ID tokens.

## Large bundles

### `--shard-by`

- `--shard-by month` creates one bundle per calendar month (UTC) named
  `YYYY-MM/`. Each shard is a complete, independently-verifiable bundle with
  its own manifest. The outer `<out>` dir gets an `index.json` listing the
  shards and their manifest hashes.
- `--shard-by rowid:<N>` creates shards of up to `<N>` messages, named
  `rowid-<first>-<last>/`.
- Attachments live in the shard whose first-referencing message lives there;
  a message in another shard referencing that attachment carries the sha256
  but not the bytes (consistent with metadata-only mode for that message).
  This avoids duplicating large blobs across shards.

### `--tar-zst`

- Produces a single `<bundle>.tar.zst` archive containing the bundle with the
  same internal layout. `manifest.json` is inside; hashes still refer to
  paths relative to the bundle root, not archive offsets.
- `verify` auto-detects `.tar.zst` input, streams entries in a tempdir, and
  runs the same checks.
- Archive ordering follows the same lexicographic rule as `manifest.hashes`
  so the archive itself is reproducible.

## Signing (future, scaffold only)

- `--sign-with <key.pem>` will produce `manifest.sig` next to `manifest.json`.
- Signature algorithm: **Ed25519**. 64-byte raw signature, hex-encoded in a
  one-line file with trailing newline.
- **Signed bytes**: the exact on-disk bytes of `manifest.json`, including its
  trailing newline, with no normalization on the verify side. Verifiers hash
  and compare the file byte-for-byte — they do not re-canonicalize.
- `manifest.json` itself therefore transitively covers every other file via
  `hashes`, and `manifest.sig` covers `manifest.json`. One signature
  authenticates the whole bundle.
- Key format: PKCS#8 PEM-encoded Ed25519 private key.
- v1 design fixes these bytes but does not ship an implementation. A v1
  bundle with no `manifest.sig` is valid; a bundle with `manifest.sig` must
  verify if the caller provides a public key.

## Round-trip compatibility

- **Major version (`v1` -> `v2`)**: `verify` of a v2 bundle with a v1-only
  binary must fail fast with `unsupported_schema` rather than pretending.
- **Minor additions**: within `v1`, writers may add new optional fields. All
  fields present in a v1 bundle must be preserved by any v1 reader/writer
  round trip. Readers MUST ignore unknown fields; they MUST NOT drop them
  on rewrite.
- `verify` must succeed on any bundle produced by the same major version
  from any minor.
- `diff` treats unknown-but-equal fields as equal.
- Removing a field, renaming a field, or changing a field's type is a major
  version bump.

## Testing

- Fixture: a tiny synthetic `chat.db` under `Tests/Fixtures/chat-export/`
  with:
  - one direct chat, one group chat,
  - a handful of messages (mix of text-only, with attachment, with reply,
    with tapback), and
  - one attachment blob.
- Golden bundle: committed under `Tests/Fixtures/chat-export/golden/` with
  the exact expected bytes (including `manifest.json` hashes). Tests:
  1. `export` the fixture to a tempdir, byte-compare every file against the
     golden tree. Fails loudly on any drift — catches any accidental
     nondeterminism in the writer.
  2. `verify` the golden bundle: exit 0, zero findings.
  3. Corrupt a byte in `messages.jsonl`; `verify` must exit 1 and name the
     file.
  4. `diff` golden vs. golden => empty.
  5. `diff` golden vs. a mutated copy (added message, removed attachment,
     changed reaction) => expected structural report.
  6. `--redact-handles`: confirm no handle strings appear anywhere inside
     the bundle (grep test), and that the sibling redactions file contains
     them.
  7. `--shard-by month` on a fixture that spans two months: two shards,
     each independently `verify`-clean, `index.json` references both.
  8. `--tar-zst`: extract and byte-compare against the plain-dir export.

## Open questions (tracked, not blocking v1)

- Do we want to include a minimal HTML renderer inside the bundle for quick
  human review? Leaning no — keep bundles data-only.
- Should `participants.json` carry avatar bytes? Likely yes under
  `--attachments`, keyed like other attachments.
- Import conflict policy (merge vs. reject on `id.guid` collision) — defer
  to the import task.
