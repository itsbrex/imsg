# imsg JSON Schema

This document describes the stable, versioned JSON shape emitted by `imsg` on
stdout (for `chats`, `history`, `watch`) and in RPC notifications (`imsg rpc`).
The canonical machine-readable definition lives alongside this guide at
[`schema/v1.json`](./schema/v1.json).

## Versioning policy

- Semver-lite on a single integer component: `v1`, `v2`, `v3`, ….
- The version **only bumps on a breaking change** — for example a field
  rename, a type change, a removal, or a semantic meaning change.
- **Additive changes are not breaking.** New optional fields, new payload
  `kind`s, and new enum values can appear within the same major (`v1`) and
  consumers MUST ignore unknown keys.
- Every supported major is documented in `docs/schema/v<N>.json` and pinned by
  downstream tooling via the envelope's `schema` field.

## Envelope (opt-in)

`imsg` has historically emitted bare JSON objects (one per line). That output
is preserved by default for backwards compatibility. Downstream tools that
want the versioned envelope set:

```
IMSG_SCHEMA=v1
```

When set, every JSON line becomes:

```json
{"schema":"v1","kind":"chat|message|reaction|watch_event|error","data":{…}}
```

- `schema` — the schema major the process is pinned to (currently `v1`).
- `kind` — discriminator for the payload in `data`.
- `data` — one of the payload objects defined below.

When `IMSG_SCHEMA` is unset, the legacy bare objects are emitted and
`schema`/`kind`/`data` are **not** present. Consumers detect which mode is in
use by probing for a top-level `schema` key:

```python
line = json.loads(stdout_line)
if line.get("schema") == "v1":
    kind, data = line["kind"], line["data"]
else:
    # legacy bare object — infer kind from fields
    ...
```

RPC (`imsg rpc`, see [`rpc.md`](./rpc.md)) is unaffected: JSON-RPC 2.0 framing
always applies, and `params`/`result` bodies match the same payload shapes.

## Payload kinds

| `kind`        | Emitted by                          | Payload type     |
| ------------- | ----------------------------------- | ---------------- |
| `chat`        | `imsg chats --json`, `chats.list`   | `ChatPayload`    |
| `message`     | `imsg history --json`, `imsg watch` | `MessagePayload` |
| `reaction`    | `watch --reactions`                 | `MessagePayload` (with reaction-event fields set) |
| `watch_event` | `watch` control frames              | `WatchEvent`     |
| `error`       | any command on failure              | `ErrorPayload`   |

Reaction events reuse `MessagePayload` because the Messages database models
them as messages with extra metadata — see the reaction fields below.

### ChatPayload

Source: `imsg chats --json` (README) and RPC `Chat` object ([`rpc.md`](./rpc.md)).

| Field             | Type        | Required | Notes                                    |
| ----------------- | ----------- | -------- | ---------------------------------------- |
| `id`              | integer     | yes      | `chat.ROWID`. Preferred routing handle.  |
| `name`            | string      | yes      | Display name (may be empty).             |
| `identifier`      | string      | yes      | `chat_identifier` (handle or group id).  |
| `guid`            | string      | no       | RPC only; stable chat GUID.              |
| `service`         | string      | yes      | `iMessage`, `SMS`, etc.                  |
| `last_message_at` | ISO8601     | yes      | UTC, fractional seconds.                 |
| `participants`    | string[]    | no       | RPC only; E.164 handles for groups.      |
| `is_group`        | boolean     | no       | RPC only; true for `;+;`-prefixed chats. |

### MessagePayload

Source: `imsg history --json`, `imsg watch --json`, and RPC `Message` object.

| Field                    | Type     | Required | Notes |
| ------------------------ | -------- | -------- | ----- |
| `id`                     | integer  | yes      | `message.ROWID`. |
| `chat_id`                | integer  | yes      | Always present; preferred routing handle. |
| `guid`                   | string   | yes      | Stable message GUID. |
| `reply_to_guid`          | string   | no       | Parent message for threaded replies. |
| `thread_originator_guid` | string   | no       | Root of the reply thread (0.5.0+). |
| `destination_caller_id`  | string   | no       | Helps disambiguate sends across multiple Apple-ID numbers. |
| `sender`                 | string   | yes      | Handle (E.164 when available). |
| `is_from_me`             | boolean  | yes      | |
| `text`                   | string   | yes      | Decoded body; audio transcription if applicable. |
| `created_at`             | ISO8601  | yes      | UTC, fractional seconds. |
| `attachments`            | object[] | yes      | See `AttachmentItem`; empty array when none. |
| `reactions`              | object[] | yes      | See `ReactionItem`; empty array when none. |
| `chat_identifier`        | string   | no       | RPC only. |
| `chat_guid`              | string   | no       | RPC only. |
| `chat_name`              | string   | no       | RPC only. |
| `participants`           | string[] | no       | RPC only. |
| `is_group`               | boolean  | no       | RPC only. |

#### Reaction-event fields (set when the message is itself a tapback/emoji reaction)

Added in 0.5.0. All five are present together or all absent.

| Field               | Type    | Notes |
| ------------------- | ------- | ----- |
| `is_reaction`       | boolean | `true` for reaction events. |
| `reaction_type`     | string  | e.g. `love`, `like`, `dislike`, `laugh`, `emphasize`, `question`, `emoji`. |
| `reaction_emoji`    | string  | Unicode emoji for the reaction. |
| `is_reaction_add`   | boolean | `false` when the reaction was removed. |
| `reacted_to_guid`   | string  | Target message GUID. |

### AttachmentItem

| Field           | Type    | Required | Notes |
| --------------- | ------- | -------- | ----- |
| `filename`      | string  | yes      | File basename. |
| `transfer_name` | string  | yes      | Original transfer name. |
| `uti`           | string  | yes      | Apple UTI (e.g. `public.jpeg`). |
| `mime_type`     | string  | yes      | MIME type or empty string. |
| `total_bytes`   | integer | yes      | Size on disk. `0` if unknown. |
| `is_sticker`    | boolean | yes      | Sticker vs regular attachment. |
| `original_path` | string  | yes      | Tilde-expanded absolute path. |
| `missing`       | boolean | yes      | `true` if the on-disk file can't be found. |

### ReactionItem

Read-only summary of reactions attached to a message.

| Field         | Type    | Required | Notes |
| ------------- | ------- | -------- | ----- |
| `id`          | integer | yes      | `message.ROWID` of the reaction row. |
| `type`        | string  | yes      | Same vocabulary as `reaction_type`. |
| `emoji`       | string  | yes      | |
| `sender`      | string  | yes      | |
| `is_from_me`  | boolean | yes      | |
| `created_at`  | ISO8601 | yes      | |

### ErrorPayload

| Field     | Type   | Required | Notes                                        |
| --------- | ------ | -------- | -------------------------------------------- |
| `code`    | string | yes      | Stable machine-readable code (e.g. `permission_denied`, `not_found`). |
| `message` | string | yes      | Human-readable description.                  |
| `details` | object | no       | Free-form context; consumers MUST treat as opaque. |

### WatchEvent

Lifecycle frames emitted by `imsg watch` between message payloads.

| Field   | Type    | Required | Notes                                          |
| ------- | ------- | -------- | ---------------------------------------------- |
| `event` | string  | yes      | `started`, `resynced`, `stopped`.              |
| `at`    | ISO8601 | yes      |                                                |
| `since_rowid` | integer | no | Resume cursor (when applicable).               |

## Compatibility matrix

Apple occasionally adds columns to `chat.db` (e.g. `thread_originator_guid`
landed mid-Ventura). The envelope is designed to absorb these changes without
a major bump:

- **New Apple column → new optional field.** Added as an optional key on the
  relevant payload within the same `v1` major. Consumers ignoring unknown
  keys keep working.
- **Apple drops a column.** `imsg` emits the field as absent (optional) or as
  a typed zero value where the field was previously required. No breaking
  bump unless a required field becomes permanently unavailable.
- **Apple renames a column.** `imsg` maps the new column to the existing
  field name — the wire contract is owned by `imsg`, not Apple.
- **Type change in the DB.** `imsg` coerces to the documented JSON type.
- **Only a rename/removal/type-change of an `imsg` field causes a major bump.**

| Change                                   | Bumps major? |
| ---------------------------------------- | ------------ |
| New optional field on an existing payload | No          |
| New `kind` value                         | No           |
| New enum value (e.g. new `reaction_type`) | No          |
| Field rename                             | **Yes**      |
| Field removal                            | **Yes**      |
| Field type change                        | **Yes**      |
| Semantic change to an existing field     | **Yes**      |

## Migration guide

Downstream tooling should:

1. **Opt into the envelope.** Spawn `imsg` (or `imsg rpc`) with
   `IMSG_SCHEMA=v1` in the environment.
2. **Pin on `schema`.** Reject lines whose `schema` value is not one you
   understand. Future majors (`v2`, …) will be emitted only if a consumer
   opts in with `IMSG_SCHEMA=v2`, so `v1` readers never see `v2` payloads.
3. **Switch on `kind`**, never on field presence. New `kind`s may appear
   within `v1`; treat unknown `kind`s as skippable.
4. **Ignore unknown fields.** Additive fields are the primary tool we use
   to avoid majors — silently drop anything you don't consume.
5. **Handle absent optional fields.** Do not assume `reply_to_guid`,
   `thread_originator_guid`, `destination_caller_id`, `guid` (on chats), or
   any reaction-event field is present.
6. **Validate with the JSON Schema.** See
   [`schema/v1.json`](./schema/v1.json); run it in CI to detect drift.

### Legacy (unversioned) output

If you cannot set `IMSG_SCHEMA`, you still receive bare payload objects —
the same objects that appear inside `data` when the envelope is enabled.
You lose the ability to pin a schema, and future breaking changes will not
be gated. Prefer the envelope for anything machine-readable.
