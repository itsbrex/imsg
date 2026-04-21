# Rules Engine (`imsg rules`)

Status: design (W1.E1). Implementation: W2.E1 (AST) + W3.E1 (runner).

Goal: react to inbound iMessage events with a declarative rules file. Every incoming
message from `imsg watch` (or a replayed rowid range) is matched against a list of
rules; matching rules fire actions. The engine is a thin layer over the already-shipped
watch stream and `MessageSender`; it adds **matching**, **rate limiting**, **dedupe**,
**templating**, and **durable state** — nothing else.

Non-goals (for the first cut):
- No scripting language, no nested conditions, no `and/or` combinators beyond ANDed match fields.
- No Lua/JS hooks. If you want logic, use `action = "exec"`.
- No queue, no at-least-once delivery — that's the outbox's job (see `docs/outbox.md`).

---

## Use cases

1. **Chatops.** An operator texts the family/team group: `deploy api`. A rule matches
   `^deploy (.+)`, runs `/usr/local/bin/deploy api` as an exec action, and the team sees
   the captured stdout in the rules log.
2. **Bridges.** Forward every message that mentions `@team` in a specific group chat to a
   Slack incoming webhook. Slack sees: `alice: @team check the dashboard`. No daemon,
   no extra binary — it's `imsg watch` piped into the rules evaluator.
3. **Auto-replies.** A caretaker-style reply: if someone texts the house iPad after
   midnight, auto-reply "got it, will check in the morning". Ships with `--dry-run`
   so the first week is observational.
4. **Forensic tail.** `action = "log"` captures every matching message to a file for
   audit without taking any side-effectful action. This is the recommended way to vet
   a rule before flipping it to `exec`/`webhook`/`reply`.

The rules engine is explicitly **not** a replacement for a real automation platform.
It is the 90th-percentile glue code that everyone writes by hand against `imsg watch`.

---

## Config format

TOML. One file, any number of `[[rule]]` blocks. Evaluated top-to-bottom; a single
message can fire multiple rules unless a rule sets `stop_on_match = true`.

### Why TOML, and the hand-rolled vs dependency tradeoff

We prefer TOML for human editability and comment support. Swift has no stdlib TOML
parser. Two paths:

- **Hand-rolled subset (preferred for W3.E1).** We parse only what we document here:
  `[[rule]]` table arrays, string/int/bool/array-of-string values, and triple-quoted
  strings for `body_template`. ~200 lines of Swift, zero new deps, matches the
  project's "no daemons, no frameworks" posture. Unknown keys become hard errors so
  we can extend later without ambiguity.
- **Add a dep later.** If the config grammar grows (nested tables, inline tables,
  datetimes), we'll vendor `TOMLKit` or `swift-toml` in W3 under a feature flag.
  Dep swap is mechanical because the rule AST (`RuleModel.swift`, W2.E1) is the
  parser's output contract, not the TOML types themselves.

Either way, **`imsg rules validate`** is the gatekeeper: it parses, typechecks every
regex, and resolves every template variable against a synthetic message before the
runner will accept the file.

### Example

```toml
# Chatops: run a deploy when the family group texts "deploy <target>"
[[rule]]
name = "deploy-mentions"
match_text = "(?i)^deploy (.+)"
match_chat_id = 42
action = "exec"
cmd = ["/usr/local/bin/deploy", "{{match.1}}"]
dedupe_window_seconds = 30
cooldown_seconds = 10

# Bridge: forward @team mentions to Slack
[[rule]]
name = "mention-webhook"
match_text = "@team"
action = "webhook"
url = "https://hooks.slack.com/services/T000/B000/xxx"
method = "POST"
headers = { "Content-Type" = "application/json" }
body_template = '{"text":"{{sender}} in {{chat_name}}: {{text}}"}'

# Observational tail — log everything from one person for a week
[[rule]]
name = "audit-alice"
match_sender = "+15555550100"
action = "log"
enabled = true

# Auto-reply (off by default; flip with --dry-run first)
[[rule]]
name = "afterhours"
match_chat_id = 17
after_time = "22:00"
before_time = "07:00"
action = "reply"
reply_text = "got it, will check in the morning"
cooldown_seconds = 3600
enabled = false
```

---

## Rule fields

All fields live on `[[rule]]` tables. Unknown fields are errors.

| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | Unique within the file. Used as the dedupe/state key. |
| `enabled` | bool | no (default `true`) | Disable without deleting. |
| `match_text` | string (regex) | no | ICU/NSRegularExpression syntax. Capture groups become `{{match.N}}`. |
| `match_sender` | string | no | Exact handle match (phone, email, or `+E164`). |
| `match_chat_id` | int | no | `chat.ROWID`. |
| `match_is_group` | bool | no | Restrict to group/direct chats. |
| `after_time` | string `HH:MM` | no | Local time window start (inclusive). |
| `before_time` | string `HH:MM` | no | Local time window end (exclusive). Wraps past midnight if `before_time < after_time`. |
| `action` | enum | yes | `exec` \| `webhook` \| `reply` \| `log` |
| `cmd` | array<string> | `action=exec` | argv; element 0 is the program. No shell. |
| `url` | string | `action=webhook` | Must be `https://`. |
| `method` | string | no (default `POST`) | `POST` or `PUT`. |
| `body_template` | string | no | Rendered with templating; sent as request body. |
| `headers` | table<string,string> | no | Extra request headers. |
| `reply_text` | string | `action=reply` | Template-expanded. |
| `reply_with_ai` | bool | no | Reserved. W3 ships false-only; provider wiring is the compose pipeline's job. |
| `dedupe_window_seconds` | int | no (default `0`) | If set, skip firing when `(name, guid)` fired within window. |
| `cooldown_seconds` | int | no (default `1`) | Per-rule minimum gap between fires. |
| `stop_on_match` | bool | no (default `false`) | If true, a fire aborts evaluation of later rules for the same message. |

All `match_*` fields are ANDed. If every provided match field passes, the rule fires.
Absent fields match everything (i.e. a rule with only `match_chat_id` matches all
messages in that chat).

### Template variables

Variables are expanded in `cmd[*]`, `url`, `body_template`, `reply_text`, and every
header value.

- `{{text}}` — message text (may be empty for attachment-only messages).
- `{{sender}}` — canonical handle (`+E164`, email, or the empty string for self).
- `{{chat_id}}` — integer as string.
- `{{chat_name}}` — group name, or the sender's handle for DMs.
- `{{match.0}}` — full regex match.
- `{{match.1}}` .. `{{match.N}}` — capture groups. Missing groups render as empty.
- `{{created_at}}` — ISO-8601 UTC.

Escaping: `{{` is literal if backslash-escaped (`\{{`). No other substitutions;
shell interpolation is explicitly **not** supported — the argv array is the sandbox.

---

## Action contracts

### `exec`
- `cmd` is an argv array; no shell, no globbing, no env expansion.
- Working directory: `$HOME`.
- Environment: inherits `imsg`'s env, plus `IMSG_RULE_NAME`, `IMSG_MESSAGE_GUID`,
  `IMSG_CHAT_ID`, `IMSG_SENDER`, `IMSG_TEXT` (truncated to 4 KiB).
- Timeout: **30 s** wall clock. On timeout, the process gets `SIGTERM` then `SIGKILL`
  after 2 s.
- Output: stdout + stderr captured to `~/Library/Logs/imsg/rules.log` with the rule
  name and message GUID prefixed. Non-zero exit is **logged, not retried**.
- The runner does not propagate exec output back into chat; that's what `reply` is for.

### `webhook`
- HTTPS only. Plain `http://` is rejected at validate time.
- Timeout: **10 s**.
- Retries: **3**, exponential backoff (`1s, 2s, 4s`) on connect errors, 5xx, or 429.
  4xx (except 429) is a permanent failure — logged, not retried.
- HMAC: if `$IMSG_RULES_SECRET` is set, the runner adds
  `X-Imsg-Signature: sha256=<hex(hmac_sha256(secret, body))>` and
  `X-Imsg-Timestamp: <unix_seconds>`. The signed payload is the literal request
  body after template expansion.
- `Content-Type` defaults to `application/json` when `body_template` starts with
  `{` or `[`; otherwise `text/plain`. User-supplied `headers` win.

### `reply`
- Delegates to the existing `MessageSender` (`Sources/IMsgCore/MessageSender.swift`).
- Targets the originating chat (`chat_id` from the triggering message).
- `--dry-run` prints `[dry-run] reply chat_id=<N> text=<rendered>` and does not invoke
  AppleScript.
- **Loop prevention (hard):** replies never fire on messages with `is_from_me = true`.
  The runner checks this before match evaluation as a safety gate.
- Rate limit: a reply rule's effective cooldown is `max(cooldown_seconds, 5)`. You
  cannot disable reply-loop guards.

### `log`
- Appends one JSON line to `~/Library/Logs/imsg/rules.log`:
  `{"ts":"...","rule":"...","guid":"...","chat_id":N,"sender":"...","text":"..."}`.
- Log rotation: runner checks size on boot and every 1000 lines; rotates at 16 MiB to
  `rules.log.1` (keeps one generation). Users who want more should pipe `watch`
  elsewhere — `log` is a debugging surface, not an archive.

---

## Safety model

1. **Universal `--dry-run`.** Every action becomes a no-op that prints what *would*
   happen. This is the first-class way to roll out a new rule file; the engine makes
   no distinction between dangerous and innocuous actions — all of them gate on the
   flag.
2. **Implicit rate limit.** Every rule has a baseline `cooldown_seconds = 1`. You can
   raise it; you cannot lower it below 1. Reply actions clamp to 5.
3. **Dedupe on replay.** Every fire records `(rule.name, message.guid)` in the state
   DB with a timestamp. On restart, or when the user replays `imsg watch --since N`,
   the runner skips any `(rule, guid)` already seen within `dedupe_window_seconds`
   (or the last 24 h if the window is 0). This is what makes `imsg rules run` idempotent
   against the watch stream.
4. **Outbound loop prevention.** `is_from_me = true` messages never trigger `reply`
   actions. `exec`/`webhook`/`log` on outbound messages is allowed but must be opted
   into per-rule via `match_is_from_me = true` (reserved for a follow-up; W3 ships
   this hard-off).
5. **Unknown keys are errors.** Config parses strictly so that typos don't silently
   turn rules off.
6. **Enabled=false rules are parsed but skipped.** Easier to toggle without git churn.
7. **The config is a capability surface.** `exec` with `cmd = ["rm", "-rf", "/"]` is
   legal and will run. We do not sandbox; the user is root on their own machine. The
   mitigation is that the config file lives in the user's home directory and is
   read-only to the daemon process.

---

## Durable state

Path: `~/Library/Application Support/imsg/rules.state.sqlite`.

Schema (W3.E1):

```sql
CREATE TABLE IF NOT EXISTS fires (
  rule_name   TEXT NOT NULL,
  message_guid TEXT NOT NULL,
  fired_at    INTEGER NOT NULL,   -- unix seconds
  PRIMARY KEY (rule_name, message_guid)
);
CREATE INDEX IF NOT EXISTS fires_by_time ON fires(fired_at);

CREATE TABLE IF NOT EXISTS cooldowns (
  rule_name  TEXT PRIMARY KEY,
  last_fire  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS cursor (
  k TEXT PRIMARY KEY,             -- e.g. "watch.rowid"
  v INTEGER NOT NULL
);
```

- `fires` is pruned opportunistically: rows older than 7 days or older than
  `max(dedupe_window_seconds) * 2` are deleted on startup.
- `cooldowns` is one row per rule; updated on each fire.
- `cursor` stores the last-processed `message.ROWID` so restart resumes cleanly
  without a `--since` flag.

State is never shared across config files. If the user points `--config` at a new
file, the runner keys off rule `name`; renaming a rule forgets its dedupe history
(documented footgun).

---

## CLI surface

All commands go through the existing `CommandRouter`.

- `imsg rules run --config <path> [--dry-run] [--chat-id N] [--since ROWID]`
  - Opens the watch stream (internally: the same reader `imsg watch` uses).
  - Evaluates every message against the loaded config.
  - `--chat-id` filters the watch stream itself (cheaper than a rule-level filter).
  - `--since ROWID` starts from a specific message rowid; default uses the
    `cursor` table, or tail-from-now on first run.
  - `--dry-run` prints rendered actions and never touches the network, shell, or
    `MessageSender`.
- `imsg rules validate --config <path>`
  - Parse, typecheck, compile every regex, render every template against a synthetic
    message (`{{text}}="hello"`, etc.), probe that every `cmd[0]` is executable and
    every `url` is `https://`. Exits 0/1.
- `imsg rules list [--config <path>]`
  - Prints a table: `name, action, enabled, match summary, last fire (from state DB)`.
  - No config flag → lists from the state DB only (useful for "what's been firing?").
- `imsg rules tail [--follow]`
  - Convenience wrapper for `tail -f ~/Library/Logs/imsg/rules.log`.

### Hot reload

- `SIGHUP` re-reads the config. On parse failure, the old rules stay loaded and the
  error is logged — the runner never degrades to "no rules" silently.
- `SIGTERM` / `SIGINT` flush the cursor and exit cleanly.
- Config mtime is sampled every 5 s as a convenience so users who don't know about
  signals still get reload. Can be disabled with `--no-autoreload`.

---

## Execution order per message

1. Read message from watch stream.
2. If `is_from_me` — skip `reply` rules entirely (step 4 will not consider them).
3. Update cursor.
4. For each rule in file order:
   a. If `enabled=false` → skip.
   b. Evaluate `match_*` predicates (AND). If any fails → skip.
   c. Check `cooldowns[rule.name]`; if inside window → skip.
   d. Check `fires(rule.name, message.guid)`; if inside `dedupe_window_seconds` → skip.
   e. Render templates. If any template references a missing field (e.g. `{{match.3}}`
      when only 2 groups captured), the group renders empty — it is not an error.
   f. If `--dry-run`, print intent; else execute action.
   g. Record `fires` and bump `cooldowns`.
   h. If `stop_on_match` → break.

---

## Testing strategy

- **Fixture stream.** A JSONL file of `MessagePayload` records, replayed into the
  runner with a stub watch source. Deterministic timestamps.
- **Fixture rules.** `Tests/imsgTests/Fixtures/rules/*.toml` covering: regex with
  captures, time-windowed, dedupe, cooldown, disabled, unknown-key (negative case),
  missing required field (negative case).
- **Action log assertion.** Each action type is double-bound in tests:
  - `exec` → swap `/usr/bin/env` for a script that echoes argv to a temp file; assert
    contents.
  - `webhook` → localhost HTTP recorder; assert method, headers, HMAC, body.
  - `reply` → inject a mock `MessageSender`; assert `send(chatID:text:)` calls.
  - `log` → read the log file and assert JSON lines.
- **Replay idempotency.** Run the fixture stream twice; the second pass must produce
  zero new actions because dedupe state persisted.
- **SIGHUP.** Write config A, start runner, write config B, send SIGHUP, replay one
  message; assert config B rules fired.
- **`validate`.** Every fixture is run through `validate` as part of CI; the negative
  fixtures must exit non-zero with a line/column in the error.

---

## Open questions / deferred

- **Multi-file config.** Defer. For now, one file per `--config`. A future
  `[include]` directive would let teams ship a base ruleset + personal overlay.
- **Conditional combinators.** No `any_of`/`all_of` until a concrete use case demands
  it. Today, write two rules.
- **`reply_with_ai`.** Reserved; needs the compose pipeline (`docs/compose.md`) to
  be real first. The field exists in the schema so configs written today don't need
  migration.
- **Per-rule secrets.** `$IMSG_RULES_SECRET` is a single global HMAC key. If we need
  per-webhook secrets, add `hmac_secret_env = "VAR_NAME"` per rule.
- **Attachment matching.** `match_has_attachment`, `match_attachment_type` — easy
  add, waiting for a user who needs it.
