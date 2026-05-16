import Foundation

// MARK: - Enrichment surface
//
// An `Enricher` decorates a `Message` payload with additional fields —
// link unfurls, OCR'd attachment text, voice-note transcripts. Each
// enricher is self-contained, idempotent (same input → same output) and
// reports its contribution as an `EnrichmentField`, so the chain runner
// can merge results without ordering being load-bearing.
//
// The W4.E MVP ships the protocol surface and three concrete enrichers
// (`UnfurlEnricher`, `TranscriptEnricher`, `VisionOCREnricher`). Wiring
// the `--enrich ocr,unfurl,transcript` CLI flag into `WatchCommand`,
// `HistoryCommand`, and `McpCommand` is deferred to a follow-up so this
// library can land in one focused review batch.

public struct EnrichmentField: Equatable, Sendable {
  public let key: String
  public let value: EnrichmentValue

  public init(key: String, value: EnrichmentValue) {
    self.key = key
    self.value = value
  }
}

public indirect enum EnrichmentValue: Equatable, Sendable {
  case string(String)
  case array([EnrichmentValue])
  case dictionary([String: EnrichmentValue])
}

public struct EnrichmentContext: Sendable {
  public let message: Message
  public let attachmentPaths: [URL]

  public init(message: Message, attachmentPaths: [URL] = []) {
    self.message = message
    self.attachmentPaths = attachmentPaths
  }
}

public struct EnrichmentResult: Equatable, Sendable {
  public var fields: [EnrichmentField]

  public init(fields: [EnrichmentField] = []) {
    self.fields = fields
  }

  public mutating func merge(_ other: EnrichmentResult) {
    fields.append(contentsOf: other.fields)
  }

  public func toDictionary() -> [String: EnrichmentValue] {
    var out: [String: EnrichmentValue] = [:]
    for field in fields {
      out[field.key] = field.value
    }
    return out
  }
}

public protocol Enricher: Sendable {
  var name: String { get }
  func enrich(_ context: EnrichmentContext) async throws -> EnrichmentResult
}

// MARK: - Chain runner

public struct EnrichmentChain: Sendable {
  private let enrichers: [any Enricher]

  public init(_ enrichers: [any Enricher]) {
    self.enrichers = enrichers
  }

  /// Run every enricher concurrently and merge the results in the
  /// order they were provided. A failing enricher does not bring down
  /// the chain — its error is logged via the optional `onError`
  /// callback and the remaining results are returned as-is.
  public func run(
    _ context: EnrichmentContext,
    onError: (@Sendable (_ enricherName: String, _ error: Error) -> Void)? = nil
  ) async -> EnrichmentResult {
    let local = enrichers
    return await withTaskGroup(of: (Int, EnrichmentResult?).self) { group in
      for (index, enricher) in local.enumerated() {
        group.addTask {
          do {
            let result = try await enricher.enrich(context)
            return (index, result)
          } catch {
            onError?(enricher.name, error)
            return (index, nil)
          }
        }
      }

      var indexed: [(Int, EnrichmentResult)] = []
      for await (index, result) in group {
        if let result {
          indexed.append((index, result))
        }
      }
      indexed.sort { $0.0 < $1.0 }
      var merged = EnrichmentResult()
      for (_, result) in indexed {
        merged.merge(result)
      }
      return merged
    }
  }
}
