# Enrichment

Optional post-processing that adds derived fields to message events without
blocking the base emission path. Opt-in only; default behavior is unchanged.

## Scope

`imsg history` and `imsg watch` emit message payloads built from `chat.db`.
Enrichment adds three derived signals:

- OCR text for resolved image attachment paths through Vision on macOS.
- Link unfurl metadata for HTTPS URLs in the message body.
- Audio transcripts already stored by Messages in `attachment.user_info`.

The same enrichment path is also available through JSON-RPC
`messages.history` / `watch.subscribe` and MCP `imsg.history` /
`imsg.watch.subscribe`.

## Usage

```bash
imsg history --chat-id 42 --enrich transcript --json
imsg watch --chat-id 42 --enrich ocr,unfurl --json
```

Valid tokens are `transcript`, `ocr`, `unfurl`, and `all`. The default is off.

Additional CLI flag:

- `--enrich-local-only` disables enrichers that perform outbound HTTP
  (`unfurl`) even when requested.

JSON-RPC and MCP accept the same selector as an array or comma-separated
string:

```json
{"chat_id": 42, "enrich": ["transcript", "unfurl"]}
```

## Output

All additions are optional and absent when enrichment is disabled or produces
no result. In schema-envelope mode (`IMSG_SCHEMA=v1`), these fields appear
inside `data`; otherwise they appear on the legacy bare message object.

### `transcript`

String from the first attachment `audio-transcription` value Messages has
stored for the message:

```json
{"transcript": "hey sorry I'm going to be ten minutes late"}
```

### `unfurl`

Array of HTTPS URL metadata, capped by the enricher:

```json
{
  "unfurl": [
    {
      "url": "https://example.com/article",
      "title": "Example Article",
      "og_title": "Example Article",
      "og_description": "Short description.",
      "og_image": "https://example.com/og.png"
    }
  ]
}
```

Fields other than `url` are omitted when not discoverable.

### `ocr`

Array of OCR results from resolved attachment paths:

```json
{"ocr": [{"path": "IMG_1234.png", "text": "Concert tickets doors 7pm"}]}
```

## Behavior

- Enrichers run concurrently through `EnrichmentChain`; successful results are
  merged in deterministic registration order: `transcript`, `ocr`, `unfurl`.
- Enrichment failure never fails the base message. Failed enrichers simply
  contribute no fields.
- `unfurl` uses the shared HTTPS-first HTTP helper, performs one `GET` per URL,
  caps each response at 256 KiB, and skips per-URL failures.
- `ocr` uses `VNRecognizeTextRequest` on macOS with a per-attachment timeout.
  Non-macOS builds use a no-op OCR enricher.
- `transcript` reads only existing Messages transcription metadata; it does not
  run Speech or any other transcription engine.

## Privacy

`unfurl` performs outbound HTTPS requests. The URL, user agent, and source IP
are visible to the target server and network intermediaries. Omit `unfurl` or
pass `--enrich-local-only` when network access is not acceptable.

`ocr` and `transcript` are local: OCR reads files already on disk, and
transcript reads `chat.db`.

## Testing

Unit coverage includes:

- `EnrichmentChain` deterministic merge order and failure isolation.
- `UnfurlEnricher` HTTPS extraction and title/Open Graph scraping over a fake
  transport.
- `TranscriptEnricher` present / absent / empty values.
- `history --enrich transcript --json` against a fixture chat database with
  `attachment.user_info`.
