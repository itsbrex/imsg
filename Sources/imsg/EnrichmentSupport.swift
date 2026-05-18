import Foundation
import IMsgCore

enum MessageEnrichmentKind: String, CaseIterable, Sendable {
  case transcript
  case ocr
  case unfurl
}

struct MessageEnrichmentOptions: Sendable {
  static let disabled = MessageEnrichmentOptions(kinds: [])

  let kinds: [MessageEnrichmentKind]

  var isEnabled: Bool { !kinds.isEmpty }

  var needsAttachmentMetadata: Bool {
    kinds.contains(.transcript) || kinds.contains(.ocr)
  }

  init(kinds: [MessageEnrichmentKind]) {
    self.kinds = kinds
  }

  static func parse(_ rawValues: [String]) throws -> MessageEnrichmentOptions {
    let tokens =
      rawValues
      .flatMap { $0.split(separator: ",") }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty }
    if tokens.isEmpty { return .disabled }

    var requested = Set<MessageEnrichmentKind>()
    for token in tokens {
      if token == "all" {
        requested.formUnion(MessageEnrichmentKind.allCases)
        continue
      }
      guard let kind = MessageEnrichmentKind(rawValue: token) else {
        throw ParsedValuesError.invalidOption("enrich")
      }
      requested.insert(kind)
    }

    let ordered = MessageEnrichmentKind.allCases.filter { requested.contains($0) }
    return MessageEnrichmentOptions(kinds: ordered)
  }

  func chain(store: MessageStore, localOnly: Bool = false) -> EnrichmentChain {
    var enrichers: [any Enricher] = []
    for kind in kinds {
      switch kind {
      case .transcript:
        enrichers.append(
          TranscriptEnricher(provider: TranscriptEnricher.makeStoreBackedProvider(store)))
      case .ocr:
        #if canImport(Vision) && os(macOS)
          enrichers.append(VisionOCREnricher())
        #else
          enrichers.append(NoOpOCREnricher())
        #endif
      case .unfurl:
        if !localOnly {
          enrichers.append(UnfurlEnricher())
        }
      }
    }
    return EnrichmentChain(enrichers)
  }
}

func enrichedMessagePayload(
  _ payload: [String: Any],
  message: Message,
  attachmentMetas: [AttachmentMeta],
  store: MessageStore,
  options: MessageEnrichmentOptions,
  localOnly: Bool = false
) async -> [String: Any] {
  guard options.isEnabled else { return payload }

  let attachmentPaths = attachmentMetas.compactMap { meta -> URL? in
    guard !meta.missing else { return nil }
    let path = meta.convertedPath ?? meta.originalPath
    guard !path.isEmpty else { return nil }
    return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
  }

  let result = await options.chain(store: store, localOnly: localOnly)
    .run(EnrichmentContext(message: message, attachmentPaths: attachmentPaths))
  let fields = result.toDictionary()
  guard !fields.isEmpty else { return payload }

  var enriched = payload
  for (key, value) in fields {
    enriched[key] = anyValue(from: value)
  }
  return enriched
}

private func anyValue(from value: EnrichmentValue) -> Any {
  switch value {
  case .string(let string):
    return string
  case .array(let values):
    return values.map { anyValue(from: $0) }
  case .dictionary(let dictionary):
    var out: [String: Any] = [:]
    for (key, value) in dictionary {
      out[key] = anyValue(from: value)
    }
    return out
  }
}
