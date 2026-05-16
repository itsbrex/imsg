---
name: imsg
description: "iMessage/SMS: local archive, contacts, chat history, watch, requested sends."
---

# imsg

Use this for Messages.app history, chat lookup, streaming, visible UI contact lookup, and sends. Reading is local DB access; sending uses Messages automation and must be explicitly requested.

## Sources

- DB: `~/Library/Messages/chat.db`
- Repo: `~/Projects/imsg`
- CLI: `imsg`
- JSON output is NDJSON; pipe to `jq -s` for arrays.

## Read Workflow

Check DB access:

```bash
sqlite3 ~/Library/Messages/chat.db 'pragma quick_check;'
```

For a visible Messages.app person/name, start with chats. The UI-resolved name usually appears as `contact_name`; it may not appear in `imsg search`, raw `message.text`, or the `handle` table.

```bash
imsg chats --limit 200 --json | jq -s '.[] | select((.contact_name // .display_name // .name // .identifier // "" | ascii_downcase) | contains("beatrix"))'
```

Then read the chat by id:

```bash
imsg history --chat-id ID --json | jq -s
```

Use `imsg search --query ... --json` for message-body search only; do not treat no search hits as proof that a visible UI contact does not exist. Use `--attachments` when attachment metadata matters. Use `--start`/`--end` with absolute timestamps for date-scoped questions.

Useful current commands:

```bash
imsg search --query "pizza tonight" --match contains --json | jq -s
imsg status --json
imsg account --json
imsg whois --address "+15551234567" --type phone --json
imsg nickname --address "+15551234567" --json
```

Direct DB checks are only a fallback. The `handle` table is keyed by phone/email and often lacks the contact display name that `imsg chats` resolves.

## Sends

Only send, react, mark read, or show typing when the user explicitly asks. Prefer dry wording in the final confirmation: recipient, service, and what was sent.

Common send command:

```bash
imsg send --to "+15551234567" --text "message" --service auto
```

## Verification

For repo edits:

```bash
make test
make build
```

For live read proof:

```bash
imsg chats --limit 3 --json | jq -s
```
