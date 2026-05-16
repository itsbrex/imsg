# Enrichment

Optional post-processing that adds derived fields to message events without
blocking the base emission path. Opt-in only; default behavior is unchanged.

## Scope

`imsg watch` (and `history`, `rpc`, `serve`) emits a message envelope built
from `chat.db`. Today, attachments carry only metadata (filename, mime type,
transfer GUID). Enrichment adds three derived signals:

- OCR text for image attachments (Vision framework).
- Link unfurl (title, OG/Twitter meta) for URLs in the message body.
- Audio transcript surfaced from `chat.db` transcription columns.

Enrichment is a pipeline of `Enricher`s that mutate an in-memory envelope
*after* it has been built from the database and *before* it is written to
stdout or announced over RPC.

## CLI

```
--enrich ocr,unfurl,transcript
```

Comma-separated list. Default: off (empty list, no enrichment runs).
Valid tokens: `ocr`, `unfurl`, `transcript`, and the meta-token `all`.
The flag is accepted by:

- `imsg watch`
- `imsg history`
- `imsg rpc` (applies to `watch.subscribe` + `messages.history` results)
- `imsg serve`

Additional flags:

- `--enrich-allow-http` — allow unfurl against `http://` URLs (default HTTPS only).
- `--enrich-local-only` — disables any enricher that performs outbound HTTP
  (currently `unfurl`). Takes precedence over `--enrich`.
- `--enrich-parallelism N` — override the default concurrency cap.

Environment:

- `IMSG_ENRICH_LANGS` — comma list of BCP-47 tags for Vision OCR.
  Default: `en-US,es-ES`.
- `IMSG_SCHEMA=v1` — required for the documented output fields. Without it,
  enrichers are still invoked, but results land on a flat legacy shape
  (`ocr_text`, `links`) without versioning guarantees.

## Pipeline location

```
chat.db row -> Message builder -> Envelope v1
                                      |
                                      v
                              EnrichmentPipeline
                                      |
                                      v
                           stdout / RPC notification / serve SSE
```

The pipeline sits in a single choke point so all emission surfaces
(watch stdout, RPC `message` notification, serve event stream) share the
same enriched envelope.

### `Enricher` protocol

```swift
protocol Enricher: Sendable {
    var id: String { get }                 // "ocr" | "unfurl" | "transcript"
    func enrich(_ env: inout Envelope,
                ctx: EnrichContext) async throws
}
```

Enrichers are run in a fixed order: `transcript` -> `ocr` -> `unfurl`. The
order is deterministic so cache keys are stable and regressions are easy to
attribute. Each enricher is responsible for:

1. Deciding if it applies (short-circuit on wrong attachment type, no URLs,
   feature disabled, etc.).
2. Honoring its own timeout.
3. Writing results back into the envelope.
4. Emitting an `enrich_warning` side event on failure (see Error model).

## Output schema (envelope v1)

All additions are optional; absent when enrichment is disabled or produced
no result.

### `attachment.ocr_text` (string, optional)

Set on an individual attachment object inside `message.attachments[]` when
`ocr` is enabled and the attachment has an image mime type
(`image/png`, `image/jpeg`, `image/heic`, `image/gif`, `image/webp`).

```json
{
  "guid": "...",
  "mime_type": "image/png",
  "filename": "IMG_1234.png",
  "ocr_text": "Concert tickets - doors 7pm - section 114"
}
```

### `attachment.audio_transcript` (string, optional)

Set on audio attachments (`audio/*`) when the `transcript` enricher ran and
a transcript was present in the source row. Never synthesized locally in v1.

```json
{
  "guid": "...",
  "mime_type": "audio/x-caf",
  "audio_transcript": "hey sorry I'm gonna be ten minutes late"
}
```

### `message.links` (array, optional)

Unfurled URLs found in the message body. Order matches the order URLs were
first seen in the body. Items have the shape:

```json
{
  "url": "https://example.com/article",
  "title": "Example Article Title",
  "site_name": "Example",
  "description": "Short OG description.",
  "image_url": "https://example.com/og.png",
  "fetched_at": "2026-04-21T15:12:44Z"
}
```

Fields other than `url` and `fetched_at` may be `null` if not discoverable.

## Vision OCR

- Engine: `VNRecognizeTextRequest`, `recognitionLevel = .accurate`,
  `usesLanguageCorrection = true`.
- Languages: parsed from `$IMSG_ENRICH_LANGS`, default `en-US,es-ES`.
- Timeout: 3 seconds per attachment, enforced via `Task.withTimeout` wrapper.
  On timeout: set `ocr_text` to `null`, emit `enrich_warning` with
  `reason: "ocr_timeout"`.
- Input is loaded from the attachment's on-disk copy (`~/Library/Messages/
  Attachments/...`). If the file is missing, enricher skips silently
  (`reason: "attachment_missing"` warning).
- Cache: keyed by `attachment.guid + ":" + sha256(file_bytes)`. Stored at
  `~/Library/Caches/imsg/enrich/ocr/<keyhash>.json`. Hit returns cached
  string without running Vision again.
- Text normalization: trim, collapse internal runs of whitespace, drop
  zero-width characters. No language ID included in the output to keep the
  schema small.

## Link unfurl

- Extraction: `NSDataDetector(types: .link)` over the decoded message body.
  Deduplicate by normalized URL (scheme + host lowercased, default ports
  removed, fragment stripped).
- Protocol policy: HTTPS only by default. `http://` requires
  `--enrich-allow-http`. Any other scheme (including `javascript:`,
  `data:`, `file:`) is rejected before fetch.
- Fetch:
  - `HEAD` first with 5s timeout. If 405/501 or HEAD forbidden, fall back
    to `GET`.
  - `GET` with 5s timeout, 1 MB hard cap on response body.
  - User-Agent: `imsg-enrich/1 (+https://github.com/...; contact: local)`.
  - `Accept: text/html,application/xhtml+xml`.
  - Redirects: followed at most 3 hops, and only if they stay on the same
    protocol tier (HTTPS stays HTTPS; HTTPS never downgrades to HTTP;
    HTTP stays HTTP when allow-http set). Off-protocol redirects abort
    cleanly.
- Parse pass over response body:
  - `<title>` (first occurrence).
  - `<meta property="og:title|og:site_name|og:description|og:image">`.
  - `<meta name="twitter:title|twitter:description|twitter:image">`.
  - Precedence: OG beats Twitter beats bare `<title>`.
- `robots.txt`:
  - Fetched once per host, cached 24h under `enrich/robots/<host>.txt`.
  - Respected for our UA; disallowed URLs produce a warning and no fetch.
- Cache:
  - Response parse results keyed by normalized URL, stored under
    `~/Library/Caches/imsg/enrich/unfurl/<urlhash>.json`.
  - TTL 24h. Stale entries are refreshed opportunistically on hit.
- `fetched_at` is the wall-clock time the body was parsed, not the cache
  read time.

## Audio transcript

- Reads the existing transcription columns from `chat.db` (already partially
  surfaced in the current schema).
- v1 is purely a normalization/surfacing step:
  - Trim surrounding whitespace, collapse runs of spaces, drop a leading
    `"` Apple sometimes inserts.
  - Produce `attachment.audio_transcript` on the matching attachment.
- v1 will **not** run Speech framework or any local STT if the row is
  empty. This keeps the feature predictable and avoids a ~large dependency
  on `Speech.framework` permissions. A future `transcribe-local` enricher
  is tracked separately.

## Privacy

**Unfurl performs outbound HTTP requests.** This is the only enricher that
sends data off-machine. The URL being fetched, the user agent, and the
source IP are visible to the target server and any middleboxes. Operators
who care about this must either:

- Omit `unfurl` from `--enrich`, or
- Pass `--enrich-local-only`, which hard-disables unfurl regardless of the
  `--enrich` list.

`ocr` and `transcript` are fully local. OCR reads files already on disk via
Vision; no network I/O. Transcript reads `chat.db` only.

Caches under `~/Library/Caches/imsg/enrich/` may persist derived data
(OCR'd text, fetched titles) across runs. Users can wipe with
`rm -rf ~/Library/Caches/imsg/enrich`.

## Concurrency

- Orchestrated with a bounded `TaskGroup`.
- Default parallelism: `max(1, ProcessInfo.processInfo.activeProcessorCount / 2)`.
- Override: `--enrich-parallelism N` (clamped to `[1, 32]`).
- Parallelism is **across enrichment units** (per-attachment for OCR,
  per-URL for unfurl), not across envelopes. Envelope ordering is preserved:
  downstream emission waits for the pipeline to finish for a given envelope
  before moving to the next.
- Cache lookups happen on the calling task (synchronous, in-process); only
  misses spawn child tasks.

## Error model

- Enrichment failures **never** fail the base envelope. The original
  message is still emitted with the fields that succeeded (or none) and
  a sibling `enrich_warning` event is emitted on the same surface.
- `enrich_warning` shape:

```json
{
  "type": "enrich_warning",
  "message_guid": "...",
  "enricher": "ocr",
  "reason": "ocr_timeout",
  "detail": "Vision request exceeded 3000ms"
}
```

- `reason` is a stable enum: `ocr_timeout`, `attachment_missing`,
  `unfurl_timeout`, `unfurl_http_error`, `unfurl_blocked_by_robots`,
  `unfurl_protocol_rejected`, `unfurl_too_large`, `transcript_empty`.
- Warnings share the caller's transport: stdout for `watch`, JSON-RPC
  notification `enrich_warning` for `rpc`, SSE event `enrich_warning`
  for `serve`.

## Testing

Fixtures live under `Tests/ImsgTests/Fixtures/enrichment/`:

- `image_with_text.png` — small PNG containing the literal string
  "imsg enrichment test". Asserts `attachment.ocr_text` contains
  `imsg enrichment test` (case-insensitive substring).
- `unfurl.html` — fixture served via an in-test `URLProtocol` stub at
  `https://fixture.local/article`. Asserts `message.links[0].title ==
  "Fixture Article"` and `links[0].site_name == "Fixture"`.

Additional unit coverage:

- Cache hit path (no Vision call, no HTTP call on second run).
- Timeout path (slow fixture -> warning event, null field).
- `--enrich-local-only` disables unfurl even when explicitly listed.
- `robots.txt` disallow path produces `unfurl_blocked_by_robots`.

Integration in `imsg rpc`:

- Subscribe with `enrich: ["ocr", "unfurl"]` parameter (mirrors the CLI
  flag). Assert the resulting `message` notification carries the derived
  fields.
