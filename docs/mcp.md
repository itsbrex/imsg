# MCP Server

Goal: let LLM hosts (Claude Code, Cursor, Zed) spawn `imsg mcp` and drive the
same primitives that `imsg rpc` (see `docs/rpc.md`) exposes, framed as a
[Model Context Protocol](https://modelcontextprotocol.io) server. `imsg mcp`
is a sibling subcommand to `imsg rpc` and reuses `MessageStore`,
`MessageWatcher`, `ChatCache`, `SubscriptionStore`, and `ChatTargetResolver`;
only the wire framing, naming, and safety gates change.

## Transport

- stdio: requests on stdin, responses + notifications on stdout.
- Newline-delimited JSON-RPC 2.0, one object per line. stderr is reserved for
  diagnostic text (never MCP frames).
- Reuse `Sources/imsg/JSONLines.swift` and `StdoutWriter`.
- Notifications omit `id`; responses echo `id` verbatim.
- Process lives until stdin closes or `shutdown` arrives.

## Lifecycle

1. Host spawns `imsg mcp [--allow-send]`.
2. Host → `initialize`; server → capabilities + `serverInfo`.
3. Host → `notifications/initialized`; server accepts tool calls.
4. Supported methods: `tools/list`, `tools/call`, `resources/list`,
   `resources/read`, `logging/setLevel`, `ping`, `shutdown`.
5. On EOF/`shutdown` the server cancels watch subscriptions and exits 0.

### `initialize`

Request:
```
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
  "protocolVersion":"2025-06-18",
  "capabilities":{},
  "clientInfo":{"name":"claude-code","version":"1.0"}}}
```

Response:
```
{"jsonrpc":"2.0","id":1,"result":{
  "protocolVersion":"2025-06-18",
  "serverInfo":{"name":"imsg","version":"0.5.0"},
  "capabilities":{
    "tools":{"listChanged":false},
    "resources":{"listChanged":true,"subscribe":false},
    "logging":{}},
  "instructions":"macOS Messages bridge. Read-only unless started with --allow-send."}}
```

- `serverInfo.version` is `IMsgVersion.current` (tracks `version.env`).
- `protocolVersion` is the MCP spec revision targeted; the server negotiates
  down to the highest common value.
- Every tool result embeds `"schema":"v1"` (see Versioning).

## Tools

Tool names are `imsg.`-prefixed so they stay unambiguous when merged with
other MCP servers in one host. Each tool ships a JSON Schema `inputSchema`.
Structured results are returned as a single `{"type":"json","json":{...}}`
content block; free-form errors use `{"type":"text","text":"..."}`.

The five `imsg rpc` methods map 1:1; `imsg.react` and `imsg.search` are added
for parity with what LLM hosts expect from a Messages bridge.

### `imsg.chats.list`

Mirrors `chats.list`.

```json
{
  "inputSchema": {
    "type": "object",
    "properties": {"limit": {"type":"integer","minimum":1,"maximum":500,"default":20}},
    "additionalProperties": false
  }
}
```
Result: `{ "schema":"v1", "chats":[Chat] }` — `Chat` per
`docs/schema/v1.json#/definitions/Chat`.

### `imsg.history`

Mirrors `messages.history`; adds `reactions` to surface data the watcher
already gathers.

```json
{
  "inputSchema": {
    "type": "object",
    "required": ["chat_id"],
    "properties": {
      "chat_id":     {"type":"integer"},
      "limit":       {"type":"integer","minimum":1,"maximum":1000,"default":50},
      "participants":{"type":"array","items":{"type":"string"}},
      "start":       {"type":"string","format":"date-time"},
      "end":         {"type":"string","format":"date-time"},
      "attachments": {"type":"boolean","default":false},
      "enrich":      {"type":"array","items":{"enum":["transcript","ocr","unfurl","all"]}},
      "reactions":   {"type":"boolean","default":false}
    },
    "additionalProperties": false
  }
}
```
Result: `{ "schema":"v1", "messages":[Message] }` — `Message` per
`docs/schema/v1.json#/definitions/Message`.

### `imsg.watch.subscribe`

Long-running. Returns a subscription id; new messages arrive as MCP
notifications until unsubscribed.

```json
{
  "inputSchema": {
    "type": "object",
    "properties": {
      "chat_id":     {"type":"integer"},
      "since_rowid": {"type":"integer"},
      "attachments": {"type":"boolean","default":false},
      "enrich":      {"type":"array","items":{"enum":["transcript","ocr","unfurl","all"]}},
      "reactions":   {"type":"boolean","default":false}
    },
    "additionalProperties": false
  }
}
```
Call result: `{ "schema":"v1", "subscription_id":3 }`.

Streamed notifications ride the standard `notifications/message` envelope so
generic clients still log them, with a `data.kind` marker for imsg-aware
clients:
```
{"jsonrpc":"2.0","method":"notifications/message","params":{
  "level":"info","logger":"imsg.watch",
  "data":{"kind":"imsg/message","schema":"v1","subscription_id":3,"message":{...}}}}
```
Stream errors use `level:"error"` and `data.kind:"imsg/error"`.

### `imsg.watch.unsubscribe`

```json
{
  "inputSchema": {
    "type": "object",
    "required": ["subscription_id"],
    "properties": {"subscription_id": {"type":"integer"}},
    "additionalProperties": false
  }
}
```
Result: `{ "schema":"v1", "ok":true }`.

### `imsg.send` *(gated by `--allow-send`)*

Same parameter shape as `send` over `imsg rpc`; accepts a direct recipient or
a resolved chat target.

```json
{
  "inputSchema": {
    "type": "object",
    "properties": {
      "to":              {"type":"string"},
      "chat_id":         {"type":"integer"},
      "chat_identifier": {"type":"string"},
      "chat_guid":       {"type":"string"},
      "text":            {"type":"string"},
      "file":            {"type":"string"},
      "service":         {"enum":["imessage","sms","auto"],"default":"auto"},
      "region":          {"type":"string","default":"US"}
    },
    "anyOf": [{"required":["to"]},{"required":["chat_id"]},
              {"required":["chat_identifier"]},{"required":["chat_guid"]}],
    "additionalProperties": false
  }
}
```
Result: `{ "schema":"v1", "ok":true }`.

### `imsg.react` *(gated by `--allow-send`)*

Thin wrapper over the existing `ReactCommand` pipeline.

```json
{
  "inputSchema": {
    "type": "object",
    "required": ["chat_id","target_guid","reaction"],
    "properties": {
      "chat_id":     {"type":"integer"},
      "target_guid": {"type":"string"},
      "reaction":    {"enum":["love","like","dislike","laugh","emphasize","question"]},
      "remove":      {"type":"boolean","default":false}
    },
    "additionalProperties": false
  }
}
```
Result: `{ "schema":"v1", "ok":true }`.

### `imsg.search`

Placeholder for W3.D1 (full-text search). The tool is advertised day one so
hosts can discover it; until W3.D1 lands the handler returns MCP error
`-32004 "not_implemented"`.

```json
{
  "inputSchema": {
    "type": "object",
    "required": ["query"],
    "properties": {
      "query": {"type":"string","minLength":1},
      "limit": {"type":"integer","minimum":1,"maximum":200,"default":50}
    },
    "additionalProperties": false
  }
}
```
Result (once implemented): `{ "schema":"v1", "messages":[Message] }`.

## Resources

MCP resources give hosts a cacheable read-only view of history without going
through `tools/call`.

| URI                                         | Description |
| ------------------------------------------- | ----------- |
| `imsg://chat/<chat_id>`                     | Last N (default 50) messages as JSON; `mimeType: application/json`. Suited for priming LLM context. |
| `imsg://chat/<chat_id>/attachments/<guid>`  | Single attachment. `mimeType` mirrors the stored UTI (`image/jpeg`, `video/mp4`, ...). Returned as a `blob` when the host accepts binary resources, otherwise as a `file://` path in a text block. |

`resources/list` enumerates the top 20 chats as `imsg://chat/<id>`.
Attachment URIs are discoverable by prefix but not auto-expanded, to keep the
listing cheap. Resource reads are unconditionally read-only; `--allow-send`
has no effect here and the server never writes to `~/Library/Messages/`.

## Logging

MCP's logging channel carries operator diagnostics:
```
{"jsonrpc":"2.0","method":"notifications/message","params":{
  "level":"debug|info|notice|warning|error",
  "logger":"imsg.<area>",
  "data":{"kind":"imsg/log","message":"...","context":{...}}}}
```

| imsg area              | Logger       | Level    |
| ---------------------- | ------------ | -------- |
| Tool call start/finish | `imsg.tools` | info     |
| Watcher lifecycle      | `imsg.watch` | info     |
| DB open/refresh        | `imsg.store` | debug    |
| AppleScript send       | `imsg.send`  | notice   |
| Recoverable errors     | `imsg.*`     | warning  |
| Unrecoverable errors   | `imsg.*`     | error    |

`imsg rpc --verbose` maps to `debug`. Hosts control volume via
`logging/setLevel`.

## Safety

Default posture is read-only. Tools split into two sets:

- **Read-only** (always on): `imsg.chats.list`, `imsg.history`,
  `imsg.watch.subscribe`, `imsg.watch.unsubscribe`, `imsg.search`; plus all
  resources.
- **Side-effecting** (require `--allow-send`): `imsg.send`, `imsg.react`.

Without `--allow-send`:

- `tools/list` still includes the gated tools with
  `annotations.readOnly=false` and `annotations.enabled=false` so the host
  can surface them as disabled.
- `tools/call` on a gated tool fails with
  `{"code":-32001,"message":"send disabled; pass --allow-send"}` before any
  AppleScript is touched.
- The server never auto-escalates; every launch decides send capability.

Additional hardening:
- Refuse to start if `~/Library/Messages/chat.db` cannot be opened `mode=ro`.
- AppleScript is only loaded when `--allow-send` is set, so read-only hosts
  never trigger Automation permission prompts.
- Attachment reads are confined to `~/Library/Messages/Attachments/`; any
  path outside that root fails with `-32002 "path_outside_attachments"`.

## Versioning & schemas

- Every payload embeds `"schema":"v1"` so clients can branch without parsing
  `serverInfo.version`.
- Full schemas for `Chat`, `Message`, `Attachment` live in
  `docs/schema/v1.json` (authored under W1.B2). Tool `inputSchema` blocks
  reference those definitions via `$ref` in the committed schemas and are
  inlined above for readability.
- `serverInfo.version` bumps with the imsg release; `schema` bumps only on
  backwards-incompatible payload changes (`v2`, `v3`, ...).
- `protocolVersion` tracks the MCP spec.

## Launch example

Claude Code `~/.config/claude-code/mcp.json`:
```json
{
  "mcpServers": {
    "imsg": {"command": "imsg", "args": ["mcp", "--allow-send"]}
  }
}
```
Cursor and Zed accept the same `command`/`args` pair. For read-only hosts
drop `--allow-send`:
```json
{ "command": "imsg", "args": ["mcp"] }
```
The binary auto-discovers the Messages DB; `IMSG_DB_PATH` is honored for
tests and CI.

## Test strategy

Golden-file dialog transcripts under `Tests/imsgTests/fixtures/mcp/`. Each
scenario is a pair of files:

```
Tests/imsgTests/fixtures/mcp/
  initialize.in.jsonl            initialize.out.jsonl
  tools_list.in.jsonl            tools_list.out.jsonl
  history_happy.in.jsonl         history_happy.out.jsonl
  watch_subscribe.in.jsonl       watch_subscribe.out.jsonl
  send_without_allow.in.jsonl    send_without_allow.out.jsonl
  resources_read.in.jsonl        resources_read.out.jsonl
```

`MCPServerTests` harness:
1. Boots `MCPServer` against `CommandTestDatabase` for deterministic rows.
2. Replays `*.in.jsonl` line by line and diffs emitted lines against
   `*.out.jsonl`, masking volatile fields (ISO timestamps, echoed `id`s)
   with the same helper `RPCServerTests` already uses.
3. Covers: capability negotiation, read-only happy paths, watcher
   notification ordering, send-disabled error mapping, unknown-tool error,
   attachment resource read, graceful shutdown on EOF.

Additional unit tests assert that `tools/list` output validates against
`docs/schema/v1.json`, that `--allow-send` toggles the gated tool
annotations, and that logging notifications fire at the documented levels.
Live Messages DB access stays out of scope; fixtures exercise every MCP code
path without Full Disk Access.
