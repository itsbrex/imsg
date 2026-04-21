# Compose

Goal: `imsg compose` is a pluggable LLM pipe. It takes a short instruction,
pulls the last N messages of a chat as context, asks an LLM provider to draft
a reply, prints it, and only sends on explicit confirmation.

Compose must feel like a Unix filter: deterministic in `--json` mode,
replayable from a stored `draft_id`, offline-testable via `--provider mock`,
and never sends without both `--send` and `--yes`.

## Scope (W1.I1)

This doc is the design. The CLI wiring lands in W1.I2; the `Provider`
protocol and real HTTP providers land in W2.I1. The draft store ships with
W1.I3 (migrations) and W2.I2 (TTL sweeper). Nothing here changes existing
commands; `compose` is additive.

## CLI surface

```
imsg compose --chat-id <id> --prompt <text|-> [flags]
imsg send    --from-draft <draft_id> [--yes]
```

### Flags

| Flag | Default | Notes |
|------|---------|-------|
| `--chat-id <int>` | required | resolves via existing `ChatTargetResolver` |
| `--prompt <text \| ->` | required | `-` reads stdin until EOF |
| `--context-messages <n>` | 20 | min 0, max 200; clamped with warn on stderr |
| `--style formal\|casual\|match` | `match` | `match` analyzes recent outbound tone |
| `--max-tokens <n>` | 400 | bounded 1..2000 |
| `--provider anthropic\|openai\|mock` | `$IMSG_COMPOSE_PROVIDER` or `mock` | see below |
| `--model <id>` | provider default | e.g. `claude-sonnet-4-5`, `gpt-5.1` |
| `--json` | false | single JSON object on stdout |
| `--send` | false | actually send after drafting (still requires `--yes` or prompt) |
| `--yes` | false | skip interactive confirmation; no-op without `--send` |
| `--redact-handles` | false | replace phone numbers / emails with tokens before API call |
| `--unsafe` | false | disable safety regex refusals |
| `--no-store` | false | skip writing to drafts.sqlite |

### Examples

```
# draft only, human-readable, using env-selected provider
imsg compose --chat-id 42 --prompt "nudge about Friday dinner"

# prompt from stdin, JSON output for tooling
echo "thank them for the gift" | imsg compose --chat-id 42 --prompt - --json

# send after interactive confirm
imsg compose --chat-id 42 --prompt "running late, 15m" --send

# fully non-interactive (CI, scripts)
imsg compose --chat-id 42 --prompt "on my way" --send --yes --provider mock

# replay a stored draft
imsg send --from-draft 018f2c1e-... --yes
```

## Provider abstraction

Landing in W2.I1. Sketch:

```swift
public protocol Provider: Sendable {
    var name: String { get }           // "anthropic" | "openai" | "mock"
    var defaultModel: String { get }
    func generate(
        systemPrompt: String,
        messages: [ComposeMessage],
        tools: [Tool]?
    ) async throws -> Draft
}

public struct ComposeMessage: Sendable {
    public let role: Role               // .system, .user, .assistant
    public let author: String?          // display name for user turns in a group
    public let text: String
    public let timestamp: Date?
}

public struct Tool: Sendable { /* reserved for W3 */ }

public struct Draft: Sendable {
    public let id: String               // UUIDv7
    public let text: String
    public let tokensIn: Int
    public let tokensOut: Int
    public let provider: String
    public let model: String
    public let createdAt: Date
}
```

### Implementations (v1)

- `AnthropicProvider` — `ANTHROPIC_API_KEY`, `/v1/messages`, default
  `claude-sonnet-4-5`. Temperature 0.4. Streams disabled in v1 (we only need
  the final text). Honors `--max-tokens`.
- `OpenAIProvider` — `OPENAI_API_KEY`, `/v1/chat/completions`, default
  `gpt-5.1`. Same semantics.
- `MockProvider` — deterministic. Returns
  `Draft(text: "Draft: \(prompt.uppercased())", ...)` regardless of context.
  Used by unit tests and by `--provider mock` for offline dogfooding.

### Selection order

1. `--provider <name>` flag.
2. `$IMSG_COMPOSE_PROVIDER` env var.
3. `mock` (safe default; we do not ship an LLM opinion).

If the selected provider's required env var is missing, fail fast with a
pointer to the flag and env var names; do not silently fall back to mock.

## System prompt template

Rendered from chat metadata pulled by `MessageStore`:

```
You are drafting a single iMessage reply on behalf of {{me_display_name}}.

Chat: {{chat_display_name}}
Group: {{is_group}}
Participants: {{participants_display_names}}
Style hint: {{style}}           # formal | casual | match
Recent tone sample: {{tone_summary}}   # only when style=match
Length: keep it under {{max_tokens_as_words_hint}} words.

Rules:
- Output ONLY the message text. No preface, no quotes, no commentary.
- Do not sign off unless the recent thread does.
- Do not invent facts not present in the thread or the user instruction.
- Never include links unless the user instruction contains one.
```

The last N messages are passed as alternating `.user` / `.assistant` turns
(messages `is_from_me = true` map to `.assistant`). Oldest first. Attachments
are represented as `[image: name.jpg]` / `[file: report.pdf]` placeholders —
no bytes leave the device in v1.

### `--style match`

We compute three cheap signals over the last 20 outbound messages:
average length, emoji density, capitalization ratio. These become a single
`tone_summary` sentence appended to the system prompt, e.g.
`"short, lowercase, occasional emoji"`. No ML; pure string stats.

## Draft store

Path: `~/Library/Application Support/imsg/drafts.sqlite`
(respect `$XDG_DATA_HOME` on non-mac dev checkouts; macOS always uses
`Application Support`). Created on first `compose` run with `mode=rwc`.

Schema:

```sql
CREATE TABLE drafts (
    id               TEXT PRIMARY KEY,     -- UUIDv7
    chat_id          INTEGER NOT NULL,
    prompt           TEXT NOT NULL,
    draft_text       TEXT NOT NULL,
    provider         TEXT NOT NULL,
    model            TEXT NOT NULL,
    token_usage_json TEXT NOT NULL,        -- {"in":123,"out":45}
    created_at       TEXT NOT NULL,        -- ISO8601
    sent_at          TEXT                  -- nullable
);
CREATE INDEX drafts_chat_created ON drafts(chat_id, created_at DESC);
```

TTL: 7 days from `created_at`. A lazy sweep runs at the start of every
`compose` / `send --from-draft` call (`DELETE WHERE created_at < now-7d`).
No background daemon. We also cap the table at 5000 rows — oldest-first
eviction if exceeded.

`--no-store` skips the insert (e.g. for `--provider mock` tests).

### `imsg send --from-draft <id>`

- Loads the row. 404-style error if missing or expired.
- Refuses if `sent_at IS NOT NULL` unless `--resend`.
- Re-uses existing `MessageSender` path; only the text is read, never the
  provider fields.
- On success, sets `sent_at = now()`.

## JSON output

`--json` emits exactly one object on stdout, then newline, then exit:

```json
{
  "draft_id": "018f2c1e-7c4a-7b9d-9f00-0a1b2c3d4e5f",
  "text": "On my way, 15 min out.",
  "tokens": {"in": 182, "out": 9},
  "provider": "anthropic",
  "model": "claude-sonnet-4-5",
  "created_at": "2026-04-21T17:03:11Z",
  "sent": false
}
```

When `--send --yes` succeeds, `sent` is `true` and `sent_at` is added.

## Privacy

### What leaves the device on each API call

1. The system prompt (chat display name, participant display names,
   `is_group` flag, computed tone summary).
2. The last N message texts, with sender display names.
3. The user's prompt instruction.
4. Attachment names only (never bytes).

Phone numbers and email handles are *not* required by the model; they only
appear if a participant has no display name. `--redact-handles` replaces any
E.164 number or email with stable per-run tokens (`<handle_1>`, `<handle_2>`,
…) before the API call and un-maps them on the way back out. The mapping is
held in memory only.

### Offline mode

`--provider mock` performs no network I/O. We recommend it as the default
for CI and for dry-runs against real chat IDs.

### Logging

Compose never writes prompt or draft text to `stderr` at the default log
level. `--verbose` logs prompt length and token counts but not content.

## Safety gates

1. **Double-opt-in send.** `--send` alone prints the draft and then prompts
   `Send? [y/N]` on the controlling TTY. `--send --yes` skips the prompt.
   `--yes` without `--send` is a no-op with a stderr warning. If stdin is
   not a TTY and `--yes` is absent, `--send` refuses with exit 2.
2. **Recent-outbound guard.** Before send, query the most recent outbound
   message on the target `chat_id`. If it was sent within the last 30s,
   print `warning: you just sent "<preview>" 12s ago; send another? [y/N]`
   and require a fresh confirm. `--yes` bypasses this; `--unsafe` does not
   change it (it is a nuisance guard, not a safety one).
3. **Policy refuse list.** A small regex list (`self-harm`, `doxx`,
   `threat`, `credential-leak` markers) runs against the user prompt *and*
   the draft text. A hit aborts with exit 3 and a message pointing at
   `--unsafe`. The list is intentionally short; we are not a content
   moderator. `--unsafe` disables this one check only.
4. **No auto-send, ever.** There is no config flag, env var, or provider
   response that can bypass the `--send --yes` combo. This is enforced in
   the CLI layer, above the provider.

## Cost

Before the API call we print (unless `--json`):

```
compose: provider=anthropic model=claude-sonnet-4-5 ctx=20msgs est_in~1850 max_out=400
```

Estimation is `ceil(chars / 4)` — good enough to catch a 200-message blast.
After the call we print actual usage:

```
compose: used in=1834 out=37 (est was 1850)
```

In `--json`, these appear only in the final object as `tokens.in`/`out`.

## Testing

- `MockProviderTests` — `generate` returns `"Draft: <PROMPT UPPERCASED>"`
  and fixed token counts `{in: 0, out: 0}`.
- `ComposeCLITests` — snapshot tests on:
  - default run (draft only, no send, no store — `--no-store --provider mock`).
  - `--json` shape with UUIDv7 masked.
  - `--prompt -` reading from a piped string.
  - `--send` without `--yes` on a non-TTY → exit 2.
  - `--send --yes` with recent-outbound guard tripped → exit 4.
  - `--unsafe` bypassing the regex refuse list.
- `DraftStoreTests` — insert, load, TTL sweep at 7d+1s, 5000-row cap.
- `RedactionTests` — E.164 and email replacement round-trips.
- `StyleMatchTests` — tone summary is stable for a fixed fixture.

All tests run with `--provider mock`; no network, no `ANTHROPIC_API_KEY`
required in CI.

## Out of scope (for W1.I1)

- Tool use / function calling (reserved `tools: [Tool]?` parameter).
- Streaming output to the terminal.
- Multi-turn compose (edit the draft, ask for another pass).
- Image input to the model.
- Per-chat persona presets.

These are tracked for W3+. The `Provider` shape above was chosen so that
adding streaming and tools later does not break the v1 call sites.
