# Contacts & Graph

Design and implementation notes for `imsg who` and `imsg graph`. Resolves raw
handles (phone / email) to macOS Contacts entries when permission is available
and exposes a local interaction graph.

Current 0.9.1 support is the MVP: `imsg who --handle`, `imsg who --chat-id`,
and `imsg graph` with JSON or DOT output. The persistent SQLite Contacts cache,
full `sha256(...)` contact-id pipeline, `--refresh`, `--redact`, `--top`, and
extra graph metrics remain follow-up work.

## Goals

- Map each raw `handle` to a human-readable identity when the user
  has granted Contacts access, without leaking contact data.
- Provide a stable `contact_id` that survives across runs whether
  or not Contacts permission is granted.
- Expose the chat participant graph as JSON (default) or DOT for
  Graphviz.
- Keep all contact state on-device.

## Non-goals (v1)

- Writing or modifying Contacts entries.
- Syncing / pushing Contacts to any remote store.
- Image thumbnails larger than 128x128 px; larger photos are
  downscaled or dropped.
- Cross-device identity resolution (iCloud fan-out, CardDAV).
- Fuzzy name matching across handles that do not share a
  phone/email.

## Apple Contacts framework access

We link `Contacts.framework` and use `CNContactStore`. Access is
user-gated:

- `Info.plist` key: `NSContactsUsageDescription` with a plain
  sentence ("imsg uses Contacts to label chat participants by
  name locally.") This mirrors the Automation-for-Messages
  plumbing already in `Resources/Info.plist`.
- On first call, `CNContactStore.requestAccess(for: .contacts)`
  triggers the system prompt.
- If the status is `.denied` or `.restricted`, all resolution
  falls through to the fallback path; we do not block other
  commands.
- Entitlement plumbing: no special entitlement is required for
  read access on macOS when the binary is signed with a standard
  Developer ID; sandboxed builds would need
  `com.apple.security.personal-information.addressbook`. We are
  not sandboxed today.

## Handle normalization

Applied before any lookup, and before computing any hash.

- Phone numbers: strip whitespace, dashes, parens; keep leading
  `+`; if no leading `+`, treat as dial-local and attempt E.164
  using the user's region (from `--region` flag or the
  `destination_caller_id` region hint). If the region is unknown,
  keep the digits as-is but mark `normalized = false` in the
  cache row so a later run can retry.
- Emails: trim, lowercase, strip a single trailing dot.
- Group handles (contain `;+;` or `;-;`): not a contact; `who`
  returns `kind = "group"` with the participant list only.

Result: `normalized_handle` is always UTF-8, NFC.

## Resolution pipeline

1. Normalize the handle as above.
2. Cache probe: look up `(normalized_handle)` in the
   `contacts.sqlite` cache. If the row is fresh (see TTL) return
   it.
3. Query `CNContactStore.unifiedContacts(matching:keysToFetch:)`:
   - For phones: `CNContact.predicateForContacts(matchingPhoneNumber: CNPhoneNumber(stringValue: normalized))`.
   - For emails: `CNContact.predicateForContacts(matchingEmailAddress: normalized)`.
   - Keys: `identifier`, `givenName`, `familyName`,
     `organizationName`, `emailAddresses`, `phoneNumbers`,
     `thumbnailImageData`, and `CNContactFormatter.descriptorForRequiredKeys(for: .fullName)`.
4. Merge: if `unifiedContacts(...)` returns multiple entries
   (happens when cards share a handle but are not linked), pick
   the one with the most fields, then fold non-empty aliases from
   the rest into `emails` / `phones` as extras.
5. Synthesize a stable id:
   - With a match: `contact_id = sha256(CNContact.identifier + "|handle:" + normalized_handle)`.
   - The `CNContact.identifier` survives card edits but not
     card deletion; folding in the handle keeps the id stable
     for that handle even if the contact is re-created later.
6. Build the record (see schema below) with `source = "contacts"`
   and write it into the cache.

On any failure (permission denied, zero matches, predicate
threw), fall through to the fallback.

### Record schema

```json
{
  "contact_id": "sha256-hex",
  "display_name": "Ada Lovelace",
  "given_name": "Ada",
  "family_name": "Lovelace",
  "organization": "Analytical Engines Ltd",
  "emails": ["ada@example.com"],
  "phones": ["+14155551212"],
  "photo_base64": "iVBORw0K...",
  "source": "contacts"
}
```

- `display_name` is produced by `CNContactFormatter.string(from:, style: .fullName)`
  and falls back to `organization`, then to the normalized
  handle.
- `photo_base64` is optional; populated only if the thumbnail is
  <= 128x128; else omitted. Never emitted for `source = "fallback"`.
- `given_name`, `family_name`, `organization` are optional
  strings; omitted (not `null`) when empty, to keep JSON terse.

## Fallback path

Triggered when Contacts access is denied, the framework returns
no match, or the handle is opaque (group rooms).

- `contact_id = sha256("handle:" + normalized_handle)`.
- `display_name = normalized_handle`.
- `source = "fallback"`.
- `emails` / `phones` contain just the one handle depending on
  its shape.
- `photo_base64` is never set.

The fallback row is written to the cache with a matching TTL so
the id stays stable across runs; a later grant of Contacts access
will overwrite the row on its next lookup and `source` flips to
`"contacts"` (the `contact_id` changes — that is documented as
expected; graph edges are keyed by `contact_id` and will
re-point).

## Cache store

Path: `~/Library/Application Support/imsg/contacts.sqlite`
(created with `0700` directory perms; file `0600`).

Schema (single table is enough for v1):

```sql
CREATE TABLE IF NOT EXISTS contacts_cache (
    normalized_handle TEXT PRIMARY KEY,
    contact_id        TEXT NOT NULL,
    source            TEXT NOT NULL,         -- 'contacts' | 'fallback'
    payload_json      TEXT NOT NULL,         -- full record
    fetched_at        INTEGER NOT NULL,      -- unix seconds
    normalized        INTEGER NOT NULL       -- 0 when region unknown
);
CREATE INDEX IF NOT EXISTS idx_cache_contact_id
    ON contacts_cache(contact_id);
```

- TTL: 24 hours for `source = "contacts"`; `fallback` rows are
  effectively permanent but rechecked on `--refresh`.
- `imsg who --refresh` deletes rows matching the requested
  handles (or `DELETE FROM contacts_cache` when used without
  `--handle`) before resolving.
- `imsg graph` uses the cache read-only; expired rows are
  re-resolved lazily.

## CLI surface

### `imsg who`

```
imsg who --handle +14155551212
imsg who --handle ada@example.com --json
imsg who --chat-id 42
```

- `--handle <h>`: resolve a single handle.
- `--chat-id <n>`: list all participants of a chat with full
  contact records.
- `--json`: emit the record(s) as JSON.
- Plain text output is the default and emits `display_name <handle>` per line.

Exit codes: `0` on success (including fallback), `2` on missing
arg, `3` when Contacts access is denied *and* `--strict` was
passed.

### `imsg graph`

```
imsg graph --since 2026-01-01 --limit 5000
imsg graph --since 30d --dot > graph.dot
imsg graph --chat-id 42 --json
```

- Window: `--since` accepts ISO8601 or a relative `NNd` / `NNw`.
- `--limit N`: cap the number of messages scanned (default
  50_000).
- `--until` accepts ISO8601 and is exclusive.
- `--dot`: emit Graphviz DOT; default is JSON.

JSON shape:

```json
{
  "generated_at": "2026-04-21T00:00:00Z",
  "window": {"since": "2026-03-22T00:00:00Z", "until": "2026-04-21T00:00:00Z"},
  "nodes": [
    {"contact_id": "…", "display_name": "Ada", "kind": "contact"},
    {"chat_id": 42, "display_name": "Project Alpha", "kind": "chat"}
  ],
  "edges": [
    {
      "from_contact_id": "…",
      "to_chat_id": 42,
      "count": 137,
      "last_at": "2026-04-20T18:12:05Z",
      "inbound": 90,
      "outbound": 47
    }
  ]
}
```

## Graph metrics

Computed on top of the edges:

- `count`: total messages in window.
- `cadence`: messages per day over the window
  (`count / window_days`), rounded to 2 decimals.
- `last_at`: newest message ISO8601.
- `direction_imbalance`: `(outbound - inbound) / max(1, count)`,
  range `[-1, +1]`. Positive = user talks more.

Cadence and imbalance are emitted inline on each edge when
`--metrics` is passed (omitted by default to keep output small).

## Privacy

- No contact fields, names, emails, phone numbers, or photo data
  are ever written to `stderr` logs, telemetry, crash reports, or
  the verbose flag at any level. The logger has an allow-list of
  field names; `display_name`, `emails`, `phones`,
  `photo_base64`, `given_name`, `family_name`, `organization`
  are on the deny-list.
- `--redact` flag:
  - Replaces `display_name` with `contact_<first8(contact_id)>`.
  - Drops `given_name`, `family_name`, `organization`,
    `photo_base64` from the output.
  - Replaces entries in `emails` / `phones` with a hash suffix
    (`sha256(handle)[0:8]`).
  - `source` is preserved so callers can still distinguish
    resolved vs fallback.
- The cache file's directory is created with `0700`.

## Permissions UX

Status is checked via `CNContactStore.authorizationStatus(for: .contacts)`:

- `.notDetermined`: request access; on denial, continue with
  fallback and print a one-liner once per process:
  `imsg: Contacts access denied. Names will not be resolved. Grant access in System Settings > Privacy & Security > Contacts.`
- `.denied` / `.restricted`: same one-liner; skip the request.
- `.authorized`: proceed silently.

The one-liner goes to `stderr`. It is suppressed when
`--json` is active unless `--strict` is also passed, in which
case we exit non-zero.

## Testing

The implementing protocol is `ContactsBridge` (W2.H1):

```swift
protocol ContactsBridge {
    func authorizationStatus() -> CNAuthorizationStatus
    func requestAccess() async -> Bool
    func lookup(phone: String) throws -> [ContactRecord]
    func lookup(email: String) throws -> [ContactRecord]
}
```

- Production impl wraps `CNContactStore`.
- Tests inject a `FixtureContactsBridge` with canned maps:
  - `+14155551212` -> one record (Ada Lovelace, Analytical Engines).
  - `shared@example.com` -> two records that get merged.
  - Any other handle -> empty, exercising the fallback.
- Cache tests use a temp directory via `XDG_STATE_HOME`-style
  override or a bridge seam in the store constructor.
- Graph tests build an in-memory chat/message set and assert
  edge counts, `last_at`, and direction imbalance.

## Open questions

- Do we want per-handle TTL overrides (e.g. businesses change
  less often than personal contacts)? Not for v1.
- Should we surface `CNContact.nickname` into `display_name`?
  Probably yes in v1.1, gated by a flag; skipped here to keep
  the initial surface small.
- How do we expose "this contact has N handles" in graph
  output? Considered folding multi-handle contacts into a single
  node; deferred until we have usage data.
