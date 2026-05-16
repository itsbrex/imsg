---
title: History
description: "Read message history from one chat with optional date, participant, and attachment filters."
---

`imsg history` reads messages from a single chat in chronological order. It's the bread-and-butter command for one-shot reads — search, archive, summarize, transcribe.

## Basic read

```bash
imsg history --chat-id 42 --limit 50
imsg history --chat-id 42 --limit 50 --json | jq -s
```

`--limit` defaults to 50 and applies *after* filters. So `--limit 20 --start ...` returns up to 20 messages from inside the date window, not 20 messages globally then date-filtered.

## Date windows

```bash
imsg history --chat-id 42 \
  --start 2026-05-01T00:00:00Z \
  --end   2026-05-06T00:00:00Z \
  --json
```

Both bounds accept ISO 8601 with explicit timezone. Either bound is optional:

```bash
# Everything since May 1st.
imsg history --chat-id 42 --start 2026-05-01T00:00:00Z --json

# Everything before May 6th.
imsg history --chat-id 42 --end 2026-05-06T00:00:00Z --json
```

## Participant filters

For group chats, narrow to messages from specific people:

```bash
imsg history --chat-id 42 --participants "+14155551212,jane@example.com" --json
```

Match is on the message's `sender` (raw handle), not the resolved contact name. Pass a comma-separated list.

## Attachments

`--attachments` adds an `attachments` array to each message containing filename, UTI, MIME type, byte count, and resolved on-disk path:

```bash
imsg history --chat-id 42 --attachments --json
```

`--convert-attachments` additionally exposes model-friendly variants when `ffmpeg` is available — CAF audio → M4A, GIF → first-frame PNG. See [Attachments](attachments.md).

## Recovering text from attributed bodies

Some Messages rows store rich text in a binary `attributedBody` column with the plain `text` column empty. `imsg history` decodes the typed-stream payload (including UTF-16LE BOM bodies) and surfaces the recovered text in the standard `text` field. No flag needed; this is on by default.

If a message is still empty, the source row genuinely had no text — usually a sticker, link preview, or attachment-only message.

## Reactions in history

Tapback rows (`Liked "..."`, `Loved "..."`, etc.) are hidden from `history` output by design. They'd otherwise duplicate every reacted message. To see tapbacks, use [`imsg watch --reactions`](watch.md#reactions); the live stream surfaces add and remove events with `is_reaction`, `reaction_type`, and `reacted_to_guid`.

## Performance

JSON history batches attachment and reaction lookups in one pass per request, so large `--limit` values stay cheap. Reading 1000 messages with `--attachments --json` is bound by SQLite, not by per-row queries.

For very large reads, prefer streaming through `jq` rather than buffering the whole result:

```bash
imsg history --chat-id 42 --limit 5000 --json \
  | jq -c 'select(.is_from_me == false)' \
  > inbound.ndjson
```

## Message object

See [JSON output](json.md#message) for the canonical schema. Every history result has at minimum:

`id`, `chat_id`, `chat_identifier`, `chat_guid`, `chat_name`, `participants`, `is_group`, `guid`, `reply_to_guid`, `destination_caller_id`, `sender`, `sender_name`, `is_from_me`, `text`, `created_at`.

When `--attachments` is set, also: `attachments[]`. Reactions only appear in `watch --reactions` output.
