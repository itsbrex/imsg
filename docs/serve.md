# Serve

Design for `imsg serve`: a long-lived local daemon that exposes the same
JSON-RPC methods as `imsg rpc` over a UNIX domain socket, with event fanout
and replay.

## Motivation

- `imsg rpc` is per-process on stdio. Each client (Clawdis, scripts, TUIs)
  pays cold start cost and opens its own `chat.db` cursor.
- `imsg watch` uses filesystem events on `chat.db`/`-wal`/`-shm`; running N
  watchers means N pollers hitting SQLite on every write.
- AppleScript bridge setup (Messages app availability check, event handler
  install) is slow. We want to pay it once.
- Goal: one tail of `chat.db`, many consumers. Subsecond fanout. No new
  network surface.

## Transport

- UNIX domain socket, stream type.
- Framing: same as `imsg rpc` — JSON-RPC 2.0, one JSON object per line
  (`\n` delimited). No HTTP, no length prefix.
- Loopback only (UNIX sockets cannot cross hosts).

### Socket path

- Default: `$XDG_RUNTIME_DIR/imsg.sock` when `XDG_RUNTIME_DIR` is set and
  writable.
- Fallback: `~/Library/Caches/imsg/imsg.sock`.
- Parent directory is created with mode `0700` if missing.
- Socket file is created with mode `0600`. Server refuses to start if an
  existing socket is owned by another UID.
- Stale sockets (no listener) are unlinked on startup after a `connect(2)`
  probe fails with `ECONNREFUSED`.

## Wire protocol

Identical to `imsg rpc` (see `docs/rpc.md`) for `chats.list`,
`messages.history`, `send`, `watch.unsubscribe`. Adds the methods below.

### `server.hello`

First call on every connection. Server rejects other methods (except the
heartbeat) until hello completes.

Params:
- `client` (string, optional) — human-readable client id for logs.
- `token` (string, optional) — required if the server was started with
  `--token-file`.

Result:
```
{
  "version": "0.X.Y",
  "schema": 1,
  "capabilities": ["watch.replay", "reactions", "groups"],
  "pid": 12345
}
```

`schema` bumps on breaking JSON-RPC changes. Clients should pin a
supported `schema` range.

### `watch.subscribe`

Extends the `rpc` version with a `replay_from` field:

Params:
- All existing `watch.subscribe` params from `docs/rpc.md`.
- `replay_from` (optional): one of
  - integer `rowid` — replay messages with `rowid > replay_from`,
  - ISO8601 string — replay messages created at/after that time,
  - the literal string `"start"` — replay the entire in-memory buffer.

Result: `{ "subscription": N }`.

Notifications stream in order: first historical (replay) messages, then
live messages, with no gap or duplicate. The server uses a single
monotonic cursor per chat to merge replay + live.

### Other methods

- `watch.unsubscribe`, `chats.list`, `messages.history`, `send` — unchanged
  from `docs/rpc.md`.

## Connection lifecycle

1. Client `connect(2)` to socket.
2. Server sends no banner. Client must issue `server.hello`.
3. After hello, client may call any method.
4. Client issues `watch.subscribe` zero or more times. Notifications flow
   as JSON-RPC notifications on the same connection.
5. Heartbeat: the server sends `{"jsonrpc":"2.0","method":"ping"}` every
   30s on idle connections. Clients respond with a `pong` notification.
6. If the server sees no bytes for 90s (3 missed pings), it closes the
   connection.
7. Client close: `watch.*` subscriptions bound to that connection are
   torn down automatically.

## Ring buffer

The server keeps an in-memory FIFO buffer per `chat_id`.

- Capacity: `N = 1024` messages per chat (configurable later).
- Global cap: if memory pressure becomes a concern, evict by LRU chat.
- Each entry is the same `Message` object shape as `rpc` emits.
- Buffer is populated by the single chat.db reader task (see below).

On `watch.subscribe` with `replay_from`:

1. Lock the chat's buffer for read.
2. Find the first entry whose `rowid > replay_from` (or >= timestamp for
   ISO8601, or head for `"start"`).
3. Drain matching entries to the client as notifications.
4. Atomically switch the client to the live broadcast channel at the
   buffer's tail cursor. No gap: the broadcast is paused for that client
   until replay finishes, because the live tap is attached before the
   drain loop runs.

If `replay_from` points before the oldest buffered entry, the server
falls back to a direct DB query via `MessageStore.messagesAfter` to
backfill, then switches to the live tap. If the DB range is huge, the
server caps backfill at `messages.history`'s default limit and returns a
`subscription` result with `"truncated": true`.

## Backpressure

- Each client has a bounded notification queue (default 4096 entries).
- Writes from the broadcaster use non-blocking send into the client
  queue.
- Queue full means the consumer cannot keep up. The server:
  1. Logs a lag event with client id + chat id.
  2. Sends a final JSON-RPC error
     `{"code": -32010, "message": "ERR_LAGGED"}` with `id: null`.
  3. Closes the socket.
- Clients should reconnect and resubscribe with `replay_from =
  last_seen_rowid`.

## Concurrency model

- One **reader task** watches `chat.db` filesystem events (same mechanism
  as `Sources/IMsgCore/MessageWatcher.swift`). On each wakeup it polls
  `messagesAfter(cursor)` and pushes results into:
  - the per-chat ring buffer (append, evict oldest on overflow),
  - a fanout `AsyncChannel<Message>` consumed by all subscribers.
- One **listener task** accepts new connections and spawns a **connection
  task** per client.
- Each connection task:
  - Runs the JSON-RPC loop (request → dispatch → reply).
  - Owns 0..N subscription filters.
  - Consumes a per-client bounded `AsyncChannel` of notifications fed by
    the broadcaster.
- Per-subscription filter runs in the broadcaster loop, not the DB
  reader, so filter cost does not block ingest.

All shared state (ring buffers, subscription table) lives behind an
`actor` boundary. The DB reader is the only writer; connection tasks are
readers.

## Security

- UNIX socket permissions `0600` restrict to the owning UID.
- macOS sandbox entitlements (`Resources/imsg.entitlements`) continue to
  apply to the `chat.db` read and AppleScript send.
- Optional token auth: `--token-file ~/.config/imsg/serve.token`.
  - File mode must be `0600`; server refuses to start otherwise.
  - First line is the token (bytes compared constant-time).
  - Clients pass it in `server.hello` params.
- No remote access. No TCP listener. The server never binds an IP port.
- Logging: method names and error codes only. Message bodies and
  attachment paths are not logged at the default level.

## Launchd integration

Shipped as an example at `Resources/com.imsg.serve.plist` (this doc only
describes it; the plist is added in a later task). Sketch:

- `Label`: `com.imsg.serve`
- `ProgramArguments`: `["/usr/local/bin/imsg", "serve", "--foreground"]`
- `RunAtLoad`: true
- `KeepAlive`: `{"SuccessfulExit": false}`
- `StandardOutPath` / `StandardErrorPath`:
  `~/Library/Logs/imsg/serve.log`
- `Sockets`: omitted; the server creates its own socket so it can run
  outside launchd during development.

Install: `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.imsg.serve.plist`.

## CLI flags

`imsg serve` accepts:

- `--socket <path>` — override socket path. Default per above.
- `--token-file <path>` — require auth token from file.
- `--foreground` — do not daemonize. Default `true` for now; we defer
  real daemonization until launchd is the expected host.
- `--log-level <off|error|info|debug>` — default `info`.

Exit codes:
- `0` — clean shutdown.
- `64` — usage error.
- `69` — socket path unavailable (EADDRINUSE on a live socket).
- `77` — token file permission error.

## Graceful shutdown

On `SIGTERM` (and `SIGINT` when foreground):

1. Stop accepting new connections (close listener, unlink socket).
2. Cancel the DB reader task.
3. Send each connection a JSON-RPC notification
   `{"method":"server.shutdown"}`.
4. Drain any in-flight request replies (bounded wait, 2s).
5. Close connections.
6. Exit `0`.

`SIGHUP` is reserved for future config reload; currently ignored.

## Testing

Integration test lives at `Tests/IMsgServeTests/ServeSocketTests.swift`
(added in a later task). Plan:

- Spin up `imsg serve --socket $TMPDIR/imsg-test.sock --foreground` as a
  subprocess against a fixture `chat.db`.
- Connect two clients. Both issue `server.hello`, then
  `watch.subscribe` with `replay_from: "start"`.
- Write a new row into the fixture DB.
- Assert:
  - Both clients receive the same message notification.
  - Replay order is strictly ascending by `rowid`.
  - A third client joining after the write and subscribing with
    `replay_from: 0` receives the new message via the ring buffer (not a
    DB query).
  - Killing one client does not disturb the other.
- Backpressure test: one client never reads; server closes it with
  `ERR_LAGGED` after the bounded queue fills; the other client keeps
  receiving.
- Shutdown test: send `SIGTERM`, expect `server.shutdown` notification
  and exit code `0`.

## Open questions

- Should `server.hello` return the current `chat.db` snapshot identity
  (mtime + size) so clients can detect DB swaps (restore, migration)?
- Do we want a per-chat capability to pin the in-memory buffer larger
  than `N=1024` for active chats? Probably yes, driven by recent use.
- Token rotation: reload on `SIGHUP` once `SIGHUP` is wired up.
