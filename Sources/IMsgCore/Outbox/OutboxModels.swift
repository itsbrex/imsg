#if os(macOS)
import CryptoKit
import Foundation
import SQLite

/// Lifecycle state of an outbox row.
///
/// Matches the state machine documented in `docs/outbox.md`:
/// `queued -> sending -> sent -> verified` on success,
/// `queued -> sending -> queued` on transient failure with backoff,
/// `... -> failed -> dead_letter` when attempts are exhausted.
public enum OutboxState: String, Sendable, Codable {
  case queued
  case sending
  case sent
  case verified
  case failed
  case deadLetter = "dead_letter"
}

/// Recipient target for an enqueue. Exactly one of `.handle` or `.chat` must
/// be supplied; the store enforces this via the row-level constraint.
public enum OutboxRecipient: Sendable, Equatable {
  case handle(String)
  case chat(Int64)
}

/// Caller-provided input when enqueuing a message. Translated by
/// ``OutboxStore/enqueue(_:)`` into a persisted row.
public struct OutboxItem: Sendable, Equatable {
  public var recipient: OutboxRecipient
  public var text: String?
  public var filePath: String?
  public var service: String
  public var region: String?
  public var idempotencyKey: String?

  public init(
    recipient: OutboxRecipient,
    text: String? = nil,
    filePath: String? = nil,
    service: String = "iMessage",
    region: String? = nil,
    idempotencyKey: String? = nil
  ) {
    self.recipient = recipient
    self.text = text
    self.filePath = filePath
    self.service = service
    self.region = region
    self.idempotencyKey = idempotencyKey
  }

  /// Derives `sha256(to_handle | chat_id | text | file_path | service)` per
  /// `docs/outbox.md` §Idempotency when no explicit key is supplied.
  public func resolvedIdempotencyKey() -> String {
    if let key = idempotencyKey, !key.isEmpty { return key }
    var hasher = SHA256()
    let nul: [UInt8] = [0x00]
    switch recipient {
    case .handle(let h): hasher.update(data: Data(h.utf8))
    case .chat(let id): hasher.update(data: Data(String(id).utf8))
    }
    hasher.update(data: Data(nul))
    if let text {
      hasher.update(data: Data(text.utf8))
    } else {
      hasher.update(data: Data(nul))
    }
    hasher.update(data: Data(nul))
    if let filePath {
      hasher.update(data: Data(filePath.utf8))
    } else {
      hasher.update(data: Data(nul))
    }
    hasher.update(data: Data(nul))
    hasher.update(data: Data(service.utf8))
    let digest = hasher.finalize()
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

/// Persisted outbox row. Encodes to the JSON shape documented in
/// `docs/outbox.md` §Store when embedded in a schema envelope.
public struct OutboxRow: Sendable, Codable, Equatable {
  public let id: String
  public let idempotencyKey: String
  public let toHandle: String?
  public let chatID: Int64?
  public let text: String?
  public let filePath: String?
  public let service: String
  public let region: String?
  public let state: String
  public let attempts: Int
  public let nextAttemptAt: Int64?
  public let createdAt: Int64
  public let updatedAt: Int64
  public let lastError: String?
  public let verifiedGUID: String?
  public let verifiedRowid: Int64?

  public init(
    id: String,
    idempotencyKey: String,
    toHandle: String?,
    chatID: Int64?,
    text: String?,
    filePath: String?,
    service: String,
    region: String?,
    state: String,
    attempts: Int,
    nextAttemptAt: Int64?,
    createdAt: Int64,
    updatedAt: Int64,
    lastError: String?,
    verifiedGUID: String?,
    verifiedRowid: Int64?
  ) {
    self.id = id
    self.idempotencyKey = idempotencyKey
    self.toHandle = toHandle
    self.chatID = chatID
    self.text = text
    self.filePath = filePath
    self.service = service
    self.region = region
    self.state = state
    self.attempts = attempts
    self.nextAttemptAt = nextAttemptAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.lastError = lastError
    self.verifiedGUID = verifiedGUID
    self.verifiedRowid = verifiedRowid
  }

  public enum CodingKeys: String, CodingKey {
    case id
    case idempotencyKey = "idempotency_key"
    case toHandle = "to_handle"
    case chatID = "chat_id"
    case text
    case filePath = "file_path"
    case service
    case region
    case state
    case attempts
    case nextAttemptAt = "next_attempt_at"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case lastError = "last_error"
    case verifiedGUID = "verified_guid"
    case verifiedRowid = "verified_rowid"
  }
}

/// A single audit entry from `outbox_events`. Streamed by
/// `imsg outbox watch`.
public struct OutboxEvent: Sendable, Codable, Equatable {
  public let id: Int64
  public let outboxID: String
  public let at: Int64
  public let fromState: String?
  public let toState: String
  public let note: String?

  public init(
    id: Int64,
    outboxID: String,
    at: Int64,
    fromState: String?,
    toState: String,
    note: String?
  ) {
    self.id = id
    self.outboxID = outboxID
    self.at = at
    self.fromState = fromState
    self.toState = toState
    self.note = note
  }

  public enum CodingKeys: String, CodingKey {
    case id
    case outboxID = "outbox_id"
    case at
    case fromState = "from"
    case toState = "to"
    case note
  }
}

/// Errors raised by ``OutboxStore``. Kept distinct from ``IMsgError`` so the
/// outbox stays self-contained per Wave 2c scope.
public enum OutboxStoreError: Error, Sendable, CustomStringConvertible {
  case notFound(String)
  case invalidRecipient
  case invalidTransition(from: String, to: String)

  public var description: String {
    switch self {
    case .notFound(let id): return "outbox row not found: \(id)"
    case .invalidRecipient: return "outbox row requires exactly one of to_handle or chat_id"
    case .invalidTransition(let from, let to): return "invalid state transition \(from) -> \(to)"
    }
  }
}

#endif
