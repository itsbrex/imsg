# Outbox: durable send with idempotency and delivery verification

Status: design (W1.F1)

## Problem

`imsg send` today shells out to AppleScript (`Sources/IMsgCore/MessageSender.swift`)
and returns as soon as the event is dispatched. Failures surface as non-zero exits
or, worse, silent drops: AppleScript times out, Messages.app is rebooting, the
handle is unresolved, or the message lands in an unintended chat. Callers have no
retry, no idempotency, and no way to know whether a message actually reached
`chat.db`.

The outbox introduces a durable queue that sits between the CLI and the send
primitive. It guarantees at-least-once delivery to Messages.app, exactly-once
semantics per idempotency key, and ex-post verification against `chat.db`.

## Store

Location: `~/Library/Application Support/imsg/outbox.sqlite` (created 0700). A
single-writer SQLite database using WAL mode. Migrations live in
`Sources/IMsgCore/Outbox/Schema.swift` and run on open.

### Schema

```sql
CREATE TABLE outbox (
    id                TEXT PRIMARY KEY,          -- ULID
    idempotency_key   TEXT NOT NULL UNIQUE,
    to_handle         TEXT,                      -- null iff chat_id set
    chat_id           INTEGER,                   -- null iff to_handle set
    text              TEXT,
    file_path         TEXT,
    service           TEXT NOT NULL,             -- "iMessage" | "SMS"
    region            TEXT,                      -- ISO region hint for handle normalization
    state             TEXT NOT NULL,             -- see state machine
    attempts          INTEGER NOT NULL DEFAULT 0,
    next_attempt_at   INTEGER NOT NULL,          -- unix seconds
    created_at        INTEGER NOT NULL,
    updated_at        INTEGER NOT NULL,
    last_error        TEXT,
    verified_guid     TEXT,                      -- chat.db message.guid once matched
    verified_rowid    INTEGER                    -- chat.db message.ROWID once matched
);

CREATE INDEX outbox_state_due ON outbox(state, next_attempt_at);
CREATE INDEX outbox_created   ON outbox(created_at);

CREATE TABLE outbox_events (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    outbox_id   TEXT NOT NULL REFERENCES outbox(id) ON DELETE CASCADE,
    at          INTEGER NOT NULL,
    from_state  TEXT,
    to_state    TEXT NOT NULL,
    note        TEXT                             -- error detail or verifier info
);

CREATE INDEX outbox_events_by_row ON outbox_events(outbox_id, id);
```

At least one of `to_handle` or `chat_id` must be set; enforced by a
`CHECK((to_handle IS NULL) <> (chat_id IS NULL))` constraint. `text` may be null
when `file_path` is set.

### State machine

```
                +--------+
enqueue -->  queued
                  |
                  | worker picks up
                  v
              sending
               /  |  \
       success    |   transient failure
           /      |     \
          v       |      v
        sent      |     queued (attempts++, backoff)
          |       |
          | verifier (10s budget)
          v       |
      verified    |
                  |
                  | terminal error OR attempts >= max
                  v
               failed  --(operator retry)--> queued
                  |
                  | attempts >= max after retry too
                  v
             dead_letter   (never auto-reaped)
```

| State         | Terminal | Worker-visible | Notes                                       |
|---------------|----------|----------------|---------------------------------------------|
| `queued`      | no       | yes            | Eligible when `next_attempt_at <= now`.     |
| `sending`     | no       | held           | Single-flight lease for one worker.         |
| `sent`        | no       | no             | Dispatched; awaiting or timed-out verifier. |
| `verified`    | yes      | no             | Row found in `chat.db`.                     |
| `failed`      | soft     | no             | Operator may `retry`.                       |
| `dead_letter` | yes      | no             | Audit only. Requires explicit `retry`.      |

## Idempotency

Every enqueue resolves to exactly one row keyed by `idempotency_key`.

1. If the caller passes `--idempotency-key KEY`, use it verbatim.
2. Otherwise derive
   `sha256(to_handle | chat_id | text | file_path | service)` hex-encoded.
   Null fields contribute the literal byte `0x00`.
3. Re-enqueue with the same key is a no-op and returns the existing row. The
   caller gets the same `id` and current `state`; attempts and backoff are
   untouched.
4. Callers that want a distinct message should pass an explicit key.

```swift
struct EnqueueRequest {
    var to: Recipient              // .handle(String) | .chat(Int64)
    var text: String?
    var filePath: String?
    var service: Service           // .iMessage | .sms
    var region: String?
    var idempotencyKey: String?    // optional override
}
```

## Retry policy

Exponential backoff, jittered +/-20%:

| Attempt | Delay before next try |
|---------|-----------------------|
| 1       | 1s                    |
| 2       | 2s                    |
| 3       | 4s                    |
| 4       | 8s                    |
| 5       | 16s                   |
| 6       | 32s (cap)             |

Default `max_attempts = 5`; override via `--max-attempts N` at enqueue or the
config key `outbox.max_attempts`.

### Error classification

The sender returns a typed error; the worker decides whether to back off or go
terminal.

| Class                   | Terminal | Source                                      |
|-------------------------|----------|---------------------------------------------|
| `transient_applescript` | no       | AppleScript timeout, Messages.app not ready |
| `network_timeout`       | no       | iMessage gateway unreachable                |
| `permission_denied`     | yes      | Automation / Full Disk Access missing       |
| `unknown_handle`        | yes      | Handle cannot be resolved on any service    |
| `invalid_arguments`     | yes      | Empty text and missing file, bad chat id    |

```swift
enum SendErrorClass {
    case transientAppleScript
    case networkTimeout
    case permissionDenied      // terminal
    case unknownHandle         // terminal
    case invalidArguments      // terminal
}
```

Terminal classes jump straight to `failed` regardless of `attempts`.

## Verification loop

After a successful send, the worker hands the row to the verifier with a 10s
budget.

1. Open `~/Library/Messages/chat.db` read-only. The caller is expected to have
   Full Disk Access; if not, the verifier logs once and leaves the row in
   `sent`.
2. Poll `message` every 500ms for rows where:
   - `is_from_me = 1`
   - `date` within `[enqueue_time - 2s, now]`
   - The chat matches: either `message.ROWID IN (SELECT message_id FROM
     chat_message_join WHERE chat_id = ?)` for chat sends, or the counterpart
     handle resolves to `to_handle` for 1:1 sends.
3. For text sends, normalize both sides with
   `String.precomposedStringWithCanonicalMapping` then collapse runs of
   whitespace to a single space before comparing. Trailing/leading whitespace is
   stripped.
4. For file sends, join `message_attachment_join` + `attachment` and match
   `attachment.transfer_name` against the enqueued basename.
5. On match: set `verified_guid = message.guid`, `verified_rowid = message.ROWID`,
   `state = verified`. Write an `outbox_events` row.
6. On timeout (10s): leave the row in `sent`. Operators can call
   `imsg outbox verify <id>` later for a one-shot retry against `chat.db`; this
   is useful when Messages.app was slow to flush.

```swift
actor Verifier {
    func verify(_ row: OutboxRow, budget: Duration = .seconds(10)) async -> VerifyResult
}

enum VerifyResult {
    case matched(guid: String, rowid: Int64)
    case timedOut
    case unavailable   // no FDA
}
```

## CLI

All commands write JSON on stdout unless `--human` is set.

```
imsg outbox enqueue  --to HANDLE|--chat ID  (--text STR | --file PATH)
                     [--service iMessage|SMS] [--region CC]
                     [--idempotency-key KEY] [--max-attempts N]
   -> {"id":"01H…","idempotency_key":"…","state":"queued"}

imsg outbox list     [--state queued|sending|sent|verified|failed|dead_letter]
                     [--limit N] [--since ISO8601]
   -> [{…}, …]

imsg outbox show     <id>
   -> {row, events:[…]}

imsg outbox retry    <id>
imsg outbox retry-all --state failed
   -> moves matching rows back to queued, resets next_attempt_at=now,
      does NOT reset attempts (so they hit dead_letter faster on re-failure
      unless --reset-attempts is passed).

imsg outbox verify   <id>                  # one-shot re-check against chat.db
   -> updates verified_guid / state on match

imsg outbox drain    [--timeout SECS]      # blocks until queue empty or timeout
   -> exit 0 when empty, 2 on timeout

imsg outbox watch                          # long-running JSON stream of events
   -> {"at":…,"id":…,"from":"queued","to":"sending"}

imsg send --via-outbox --to HANDLE --text STR
   -> thin wrapper: enqueue + drain synchronously + print final state.
      Exit 0 on verified or sent, non-zero on failed/dead_letter.
```

Flags that apply to all subcommands: `--db PATH` (override store location),
`--json|--human`.

## Worker model

```swift
actor OutboxWorker {
    init(store: OutboxStore, sender: MessageSending, verifier: Verifier, clock: Clock)

    func start() async              // main loop
    func stop() async
    func tick() async -> TickStats  // exposed for tests
}
```

Loop:

1. Acquire one row via
   `UPDATE outbox SET state='sending', updated_at=? WHERE id=(SELECT id FROM outbox WHERE state='queued' AND next_attempt_at<=? ORDER BY next_attempt_at LIMIT 1) RETURNING *`.
   The `UNIQUE(idempotency_key)` combined with the state transition guarantees
   single-flight per key even with multiple workers.
2. Dispatch via `MessageSending.send(...)`.
3. On success, mark `sent`, kick off `Verifier.verify`.
4. On transient error, bump `attempts`, compute next backoff, set
   `next_attempt_at`, drop back to `queued`.
5. On terminal error or `attempts >= max`, transition to `failed` (or
   `dead_letter` when retrying a `failed` row hits max again).

The worker is embeddable: `imsg serve` wires one `OutboxWorker` into its actor
graph so a long-running daemon drains continuously. The one-shot
`imsg send --via-outbox` spins a worker, enqueues, drains, exits.

### Concurrency

- One worker per process by default.
- SQLite `BEGIN IMMEDIATE` on the claim query serializes the claim itself.
- `UNIQUE(idempotency_key)` prevents duplicate enqueue races.
- The `(state, next_attempt_at)` index keeps the claim query O(log n).

## Observability

- `imsg outbox watch` opens a blocking JSON stream backed by
  `outbox_events`. New rows are pushed via a simple polling tail (250ms) until
  SQLite `data_version` change-notify is wired up.
- Every state transition writes an `outbox_events` row with `from_state`,
  `to_state`, and a `note` carrying either the error message or the verifier
  result. `last_error` mirrors the most recent error note for quick `list`
  output.
- `imsg outbox show <id>` returns the current row plus its event log, suitable
  for bug reports.

Event JSON:

```json
{
  "at": 1713657600,
  "id": "01HV…",
  "from": "sending",
  "to": "sent",
  "attempts": 2,
  "note": null
}
```

## Safety

- No row is ever deleted by the worker. `dead_letter` is terminal and stays
  until an operator runs `imsg outbox purge --state dead_letter --older-than
  30d` (separate command, out of scope here).
- `last_error` is preserved across retries so postmortems have the full chain
  via `outbox_events`.
- The store is opened with `PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;`
  so a crash cannot lose an acknowledged enqueue.
- `imsg send` without `--via-outbox` keeps its current behavior; opting in is
  explicit so we do not silently change semantics for existing callers.

## Testing

Tests live in `Tests/IMsgCoreTests/OutboxTests/`.

- `MockMessageSender` implements `MessageSending` and can be programmed with a
  sequence of outcomes (`.transient`, `.permissionDenied`, `.success`).
- A fixture `chat.db` under `Tests/Fixtures/chat_db/` seeds a handful of
  handles, one chat, and a tool to append synthetic `message` rows so the
  verifier has something to match.
- Scenarios:
  1. Happy path: enqueue, one send call, verifier matches, row becomes
     `verified`.
  2. Transient then success: two `.transient` then `.success`, expect
     `attempts == 3` and final state `verified` (or `sent` if verifier fixture
     omitted).
  3. Permission denied: single call, state `failed`, attempts `1`, terminal
     error class recorded.
  4. Max attempts: five `.transient` outcomes, state `failed`, then
     `retry` + five more `.transient`, state `dead_letter`.
  5. Idempotency: two enqueues with same derived key return the same `id`; two
     enqueues with different `--idempotency-key` create distinct rows even for
     identical payloads.
  6. Verifier whitespace: send `"hi   world"`, fixture row has `"hi world"`,
     verifier matches after normalization.
  7. File verify: enqueue `--file /tmp/a.png`, fixture attachment with
     `transfer_name = "a.png"` matches.
  8. Drain: enqueue N rows, call `drain --timeout 5`, assert exit 0 and all
     rows terminal.

`OutboxWorker.tick()` is exposed so tests drive the loop deterministically via
an injected `Clock`.

## Open questions

- Should `dead_letter` rows block new enqueues with the same idempotency key?
  Current proposal: yes, returning the dead row, so callers must rotate keys
  after a definitive failure. Revisit after first round of usage.
- Multiple-worker support across `imsg` processes. The schema is ready; the
  CLI currently starts at most one.
- `chat.db` change-notify vs polling. Polling is simpler and good enough for
  the 10s verification window.
