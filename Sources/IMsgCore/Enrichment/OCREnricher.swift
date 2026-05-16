import Foundation

#if canImport(Vision)
  import Vision
#endif

/// OCR text extraction over message attachments. Production
/// implementation is `VisionOCREnricher`; tests inject the protocol so
/// they can run without the Vision framework.
public protocol OCREnricher: Enricher {}

/// Vision-backed OCR. Only available on macOS — the Linux build of the
/// package surface installs `NoOpOCREnricher` instead so the public
/// type tree stays portable.
#if canImport(Vision) && os(macOS)
  public struct VisionOCREnricher: OCREnricher {
    public let name = "ocr"

    public let perAttachmentTimeout: TimeInterval
    public let maxAttachments: Int

    public init(perAttachmentTimeout: TimeInterval = 3, maxAttachments: Int = 4) {
      self.perAttachmentTimeout = perAttachmentTimeout
      self.maxAttachments = maxAttachments
    }

    public func enrich(_ context: EnrichmentContext) async throws -> EnrichmentResult {
      let urls = Array(context.attachmentPaths.prefix(maxAttachments))
      if urls.isEmpty { return EnrichmentResult() }

      var entries: [EnrichmentValue] = []
      for url in urls {
        if let text = try await recognizeText(at: url), !text.isEmpty {
          entries.append(
            .dictionary([
              "path": .string(url.lastPathComponent),
              "text": .string(text),
            ])
          )
        }
      }
      if entries.isEmpty { return EnrichmentResult() }
      return EnrichmentResult(fields: [
        EnrichmentField(key: "ocr", value: .array(entries))
      ])
    }

    private func recognizeText(at url: URL) async throws -> String? {
      let timeout = perAttachmentTimeout
      return try await withThrowingTaskGroup(of: String?.self) { group in
        group.addTask {
          try await Self.runRequest(url: url)
        }
        group.addTask {
          try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
          return nil
        }
        let first = try await group.next() ?? nil
        group.cancelAll()
        return first
      }
    }

    private static func runRequest(url: URL) async throws -> String? {
      try await withCheckedThrowingContinuation { continuation in
        let request = VNRecognizeTextRequest { request, error in
          if let error {
            continuation.resume(throwing: error)
            return
          }
          let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
          let text = observations.compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
          continuation.resume(returning: text.isEmpty ? nil : text)
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
          let handler = VNImageRequestHandler(url: url, options: [:])
          try handler.perform([request])
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
#endif

/// Stub OCR enricher used on non-macOS platforms and in tests where
/// Vision is not desired.
public struct NoOpOCREnricher: OCREnricher {
  public let name = "ocr"
  public init() {}
  public func enrich(_ context: EnrichmentContext) async throws -> EnrichmentResult {
    _ = context
    return EnrichmentResult()
  }
}
