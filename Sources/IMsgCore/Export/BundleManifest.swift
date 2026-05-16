import Foundation

#if canImport(CryptoKit)
  import CryptoKit
#endif

// MARK: - Bundle types
//
// The W4.X export bundle is a directory of plain files (no chat.db inside)
// produced by `imsg export`, verified by `imsg export verify`, and
// compared by `imsg export diff`. See `docs/export.md` for the design.
//
// The W4.X MVP shipped here covers the metadata-only mode: manifest,
// meta.json, participants.json, messages.jsonl, reactions.jsonl. Copying
// attachment bytes, sharding, tar.zst archives, redaction, and Ed25519
// signing are all deferred (see the project "Out of scope" list in
// TASKS.md).

public struct BundleSource: Codable, Equatable, Sendable {
  public let chatId: Int64
  public let guid: String

  public init(chatId: Int64, guid: String) {
    self.chatId = chatId
    self.guid = guid
  }

  enum CodingKeys: String, CodingKey {
    case chatId = "chat_id"
    case guid
  }
}

public struct BundleCounts: Codable, Equatable, Sendable {
  public let messages: Int
  public let attachments: Int
  public let reactions: Int

  public init(messages: Int, attachments: Int, reactions: Int) {
    self.messages = messages
    self.attachments = attachments
    self.reactions = reactions
  }
}

public struct BundleManifest: Codable, Equatable, Sendable {
  public let schema: String
  public let createdAt: String
  public let imsgVersion: String
  public let source: BundleSource
  public let counts: BundleCounts
  public let hashes: [String: String]
  public let redactions: [String]

  public init(
    schema: String,
    createdAt: String,
    imsgVersion: String,
    source: BundleSource,
    counts: BundleCounts,
    hashes: [String: String],
    redactions: [String] = []
  ) {
    self.schema = schema
    self.createdAt = createdAt
    self.imsgVersion = imsgVersion
    self.source = source
    self.counts = counts
    self.hashes = hashes
    self.redactions = redactions
  }

  enum CodingKeys: String, CodingKey {
    case schema
    case createdAt = "created_at"
    case imsgVersion = "imsg_version"
    case source
    case counts
    case hashes
    case redactions
  }
}

// MARK: - Hashing

public enum BundleHasher {
  /// Lowercase hex sha256 of `data`. Returns the empty string if CryptoKit
  /// is unavailable (only relevant for non-Apple test builds; the export
  /// surface is gated to macOS).
  public static func sha256Hex(_ data: Data) -> String {
    #if canImport(CryptoKit)
      let digest = SHA256.hash(data: data)
      return digest.map { String(format: "%02x", $0) }.joined()
    #else
      _ = data
      return ""
    #endif
  }
}
