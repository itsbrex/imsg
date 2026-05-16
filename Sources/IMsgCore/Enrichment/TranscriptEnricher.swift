import Foundation

/// Surfaces voice-note transcripts that Messages.app has already
/// computed and stored in `chat.db` via `attachment.user_info`. v1
/// explicitly does not re-transcribe audio on-device — the data is
/// there for the taking when the OS has filled it in.
public struct TranscriptEnricher: Enricher {
  public let name = "transcript"

  public typealias Provider = @Sendable (Int64) async throws -> String?
  private let provider: Provider

  public init(provider: @escaping Provider) {
    self.provider = provider
  }

  public func enrich(_ context: EnrichmentContext) async throws -> EnrichmentResult {
    if context.message.attachmentsCount == 0 { return EnrichmentResult() }
    guard let transcript = try await provider(context.message.rowID),
      !transcript.isEmpty
    else {
      return EnrichmentResult()
    }
    return EnrichmentResult(fields: [
      EnrichmentField(key: "transcript", value: .string(transcript))
    ])
  }
}

extension TranscriptEnricher {
  /// Convenience initializer that wraps a `MessageStore`'s
  /// audio-transcription lookup. The lookup is performed on the
  /// store's connection queue, off the actor that drives the chain.
  public static func makeStoreBackedProvider(_ store: MessageStore) -> Provider {
    return { [store] rowID in
      try store.audioTranscriptionPublic(for: rowID)
    }
  }
}
