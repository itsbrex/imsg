---
title: JSON output
description: "The stable JSON schema imsg emits for chats, messages, attachments, and reaction events."
---

Every read command supports `--json`. Output is **newline-delimited JSON (NDJSON)**: one self-contained JSON object per line. This shape works equally well for streaming consumers and for batch readers that pipe through `jq -s` to materialize an array.

```bash
imsg chats --json | jq -s
imsg history --chat-id 42 --json | jq -s
imsg watch --chat-id 42 --json
```

Human progress, prompts, and warnings are written to **stderr**, not stdout. Stdout is reserved for parseable JSON so pipelines stay clean.

## Chat

Returned by `imsg chats`, `imsg group`, and embedded in nested chat references in messages.

| Field | Type | Notes |
|-------|------|-------|
| `id` | int | `chat.ROWID`. Stable within one DB. Preferred routing handle. |
| `name` | string | Display name, contact match, or raw handle fallback. |
| `display_name` | string | Group title from `chat.display_name`. Empty for direct chats without a custom name. |
| `contact_name` | string | Resolved Contacts name (when permission granted). |
| `identifier` | string | `chat.chat_identifier`. Portable. |
| `guid` | string | `chat.guid`. Portable. |
| `service` | string | `iMessage`, `SMS`, etc. |
| `last_message_at` | ISO8601 | Newest activity time. |
| `is_group` | bool | True when identifier or guid contains `;+;`. |
| `participants` | array of strings | External handles only; local user implicit. |
| `account_id` | string | Routing diagnostic. Read-only. |
| `account_login` | string | Routing diagnostic. Read-only. |
| `last_addressed_handle` | string | Routing diagnostic. Read-only. |

## Message

Returned by `imsg history`, `imsg watch`, and the JSON-RPC `messages.history` and `watch.subscribe` notifications.

| Field | Type | Notes |
|-------|------|-------|
| `id` | int | rowid. Use as the `--since-rowid` cursor in watch. |
| `chat_id` | int | Always present. Preferred routing handle. |
| `chat_identifier` | string | Portable handle. |
| `chat_guid` | string | Portable GUID. |
| `chat_name` | string | Display name for the chat. |
| `participants` | array | External handles. |
| `is_group` | bool | True for group threads. |
| `guid` | string | Message GUID. Stable across machines. |
| `reply_to_guid` | string | When set, this message is an inline reply to that GUID. |
| `destination_caller_id` | string | Outgoing only — which of your numbers Messages routed through. |
| `sender` | string | Raw handle. Empty for some self-sent messages. |
| `sender_name` | string | Resolved Contacts name when permission granted. |
| `is_from_me` | bool | True for outbound. |
| `text` | string | Plain text. Recovered from `attributedBody` when `text` column is empty. |
| `created_at` | ISO8601 | Message timestamp. |
| `attachments` | array | Present when `--attachments` is set. See below. |
| `thread_originator_guid` | string | For inline-reply threads. |

### Reaction extensions

Present on `imsg watch --reactions` events:

| Field | Type | Notes |
|-------|------|-------|
| `is_reaction` | bool | `true` for tapback events. |
| `reaction_type` | string | `love`, `like`, `dislike`, `laugh`, `emphasis`, `question`, or a custom emoji marker. |
| `reaction_emoji` | string | Custom emoji, when present. |
| `is_reaction_add` | bool | `true` for add, `false` for remove. |
| `reacted_to_guid` | string | The message guid this tapback targets. |

`history` deliberately hides reaction rows so they don't duplicate the reacted message. Reaction events only surface in the live watch stream.

## Attachment

Inside the `attachments` array on a message:

| Field | Type | Notes |
|-------|------|-------|
| `filename` | string | Stored filename. |
| `transfer_name` | string | Original filename as sent. |
| `uti` | string | Apple UTI. |
| `mime_type` | string | Best-effort MIME. |
| `byte_size` | int | Size in bytes. |
| `is_sticker` | bool | Sticker-pack attachments. |
| `missing` | bool | Underlying file not on disk. |
| `path` | string | Resolved absolute path. |
| `converted_path` | string | Present with `--convert-attachments`. |
| `converted_mime_type` | string | Present with `--convert-attachments`. |

## Conventions

- Every numeric field is a JSON number. `id`, `chat_id`, and `byte_size` are integers; nothing requires 64-bit JSON-string encoding.
- Times are ISO 8601 with explicit timezone (typically `Z`).
- Strings that aren't applicable are omitted, not set to `null`. Test with `field in obj`, not `obj.field === null`.
- Booleans are explicit `true` / `false`, never 0/1.
- Arrays are always present when documented (possibly empty).

## Stability

The JSON schema is treated as a public API. Field renames or removals are tracked in `CHANGELOG.md` with a "change" or "deprecation" note and gated to a minor release.

The 0.2.0 → 0.3.0 cycle did one large rename (camelCase → snake_case). Since 0.3.0 the schema has been additive only.
