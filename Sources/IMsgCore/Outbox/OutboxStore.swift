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
    if let text { hasher.update(data: Data(text.utf8)) } else { hasher.update(data: Data(nul)) }
    hasher.update(data: Data(nul))
    if let filePath { hasher.update(data: Data(filePath.utf8)) } else { hasher.update(data: Data(nul)) }
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

/// Actor-wrapped SQLite store for the outbox.
///
/// Single writer per process; the `SQLite.Connection` runs on the actor's
/// executor so we do not need additional locking. Schema migrations run on
/// open and are idempotent. See `docs/outbox.md` §Store for the full design.
public actor OutboxStore {
  private let db: Connection
  public let path: String

  private init(path: String) throws {
    self.path = path
    let conn = try Connection(path)
    self.db = conn
    try OutboxStore.applyPragmas(conn)
    try OutboxStore.migrate(conn)
  }

  /// Opens (creating if needed) the SQLite store at `url`. Parent directory
  /// is created as well so the default
  /// `~/Library/Application Support/imsg/outbox.sqlite` path Just Works.
  public static func open(at url: URL) async throws -> OutboxStore {
    let fm = FileManager.default
    let dir = url.deletingLastPathComponent()
    try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
    return try OutboxStore(path: url.path)
  }

  /// The default on-disk location: `~/Library/Application Support/imsg/outbox.sqlite`.
  public static func defaultURL() -> URL {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    return base.appendingPathComponent("imsg/outbox.sqlite")
  }

  /// Convenience: open the default store location.
  public static func openDefault() async throws -> OutboxStore {
    return try await open(at: defaultURL())
  }

  // MARK: - Schema

  private static func applyPragmas(_ db: Connection) throws {
    db.busyTimeout = 5
    try db.execute("PRAGMA journal_mode=WAL;")
    try db.execute("PRAGMA synchronous=FULL;")
    try db.execute("PRAGMA foreign_keys=ON;")
  }

  private static func migrate(_ db: Connection) throws {
    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS outbox (
        id TEXT PRIMARY KEY,
        idempotency_key TEXT UNIQUE NOT NULL,
        to_handle TEXT,
        chat_id INTEGER,
        text TEXT,
        file_path TEXT,
        service TEXT,
        region TEXT,
        state TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        next_attempt_at INTEGER,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        last_error TEXT,
        verified_guid TEXT,
        verified_rowid INTEGER,
        CHECK ((to_handle IS NULL) <> (chat_id IS NULL))
      );
      """
    )
    try db.execute(
      """
      CREATE INDEX IF NOT EXISTS outbox_state_due ON outbox(state, next_attempt_at);
      """
    )
    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS outbox_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        outbox_id TEXT NOT NULL,
        at INTEGER NOT NULL,
        from_state TEXT,
        to_state TEXT NOT NULL,
        note TEXT
      );
      """
    )
    try db.execute(
      """
      CREATE INDEX IF NOT EXISTS outbox_events_by_row ON outbox_events(outbox_id, id);
      """
    )
  }

  // MARK: - API

  /// Upserts a new row keyed by ``OutboxItem/resolvedIdempotencyKey()``.
  /// Re-enqueuing the same key is a no-op and returns the existing row with
  /// its state and attempts preserved.
  public func enqueue(_ item: OutboxItem, now: Date = Date()) throws -> OutboxRow {
    let key = item.resolvedIdempotencyKey()
    if let existing = try rowByIdempotency(key) {
      return existing
    }

    let id = OutboxStore.newID()
    let createdAt = Int64(now.timeIntervalSince1970)
    let toHandle: String?
    let chatID: Int64?
    switch item.recipient {
    case .handle(let h):
      toHandle = h
      chatID = nil
    case .chat(let c):
      toHandle = nil
      chatID = c
    }

    let bindings: [Binding?] = [
      id, key, toHandle, chatID, item.text, item.filePath, item.service, item.region,
      OutboxState.queued.rawValue, Int64(0), createdAt, createdAt, createdAt, nil, nil, nil,
    ]
    try db.run(
      """
      INSERT INTO outbox (
        id, idempotency_key, to_handle, chat_id, text, file_path, service, region,
        state, attempts, next_attempt_at, created_at, updated_at, last_error,
        verified_guid, verified_rowid
      ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      """,
      bindings
    )
    try appendEvent(
      outboxID: id, at: createdAt, from: nil, to: OutboxState.queued.rawValue, note: nil)
    guard let row = try rowByID(id) else {
      throw OutboxStoreError.notFound(id)
    }
    return row
  }

  /// Returns the oldest ready-to-send rows, capped at `limit`. A row is ready
  /// when it is in `queued` state and its `next_attempt_at <= now`.
  public func nextReady(now: Date = Date(), limit: Int = 1) throws -> [OutboxRow] {
    let ts = Int64(now.timeIntervalSince1970)
    let sql =
      """
      SELECT * FROM outbox
      WHERE state = ? AND (next_attempt_at IS NULL OR next_attempt_at <= ?)
      ORDER BY next_attempt_at ASC, created_at ASC
      LIMIT ?
      """
    let bindings: [Binding?] = [OutboxState.queued.rawValue, ts, Int64(limit)]
    var rows: [OutboxRow] = []
    for raw in try db.prepare(sql, bindings) {
      rows.append(OutboxStore.decodeRow(raw))
    }
    return rows
  }

  /// Transitions a row from `queued` to `sending`. Increments `attempts`.
  public func markSending(id: String, now: Date = Date()) throws {
    let current = try requireRow(id)
    let ts = Int64(now.timeIntervalSince1970)
    let bindings: [Binding?] = [OutboxState.sending.rawValue, ts, id]
    try db.run(
      """
      UPDATE outbox
      SET state = ?, attempts = attempts + 1, updated_at = ?
      WHERE id = ?
      """,
      bindings
    )
    try appendEvent(
      outboxID: id, at: ts, from: current.state, to: OutboxState.sending.rawValue, note: nil)
  }

  /// Transitions a row to `sent` after AppleScript dispatch succeeded.
  /// The verifier runs afterwards to confirm `chat.db` persistence.
  public func markSent(id: String, now: Date = Date()) throws {
    let current = try requireRow(id)
    let ts = Int64(now.timeIntervalSince1970)
    let bindings: [Binding?] = [OutboxState.sent.rawValue, ts, id]
    try db.run(
      "UPDATE outbox SET state = ?, updated_at = ?, last_error = NULL WHERE id = ?",
      bindings
    )
    try appendEvent(
      outboxID: id, at: ts, from: current.state, to: OutboxState.sent.rawValue, note: nil)
  }

  /// Transitions a row to `verified` and records the matching `chat.db` guid/rowid.
  public func markVerified(
    id: String, verifiedGUID: String, verifiedRowid: Int64, now: Date = Date()
  ) throws {
    let current = try requireRow(id)
    let ts = Int64(now.timeIntervalSince1970)
    let bindings: [Binding?] = [
      OutboxState.verified.rawValue, ts, verifiedGUID, verifiedRowid, id,
    ]
    try db.run(
      """
      UPDATE outbox
      SET state = ?, updated_at = ?, verified_guid = ?, verified_rowid = ?
      WHERE id = ?
      """,
      bindings
    )
    try appendEvent(
      outboxID: id,
      at: ts,
      from: current.state,
      to: OutboxState.verified.rawValue,
      note: "guid=\(verifiedGUID)"
    )
  }

  /// Transient failure: rolls the row back to `queued` with a future
  /// `next_attempt_at` so the worker picks it up after the backoff.
  public func markFailed(id: String, error: String, backoffAt: Date, now: Date = Date()) throws {
    let current = try requireRow(id)
    let ts = Int64(now.timeIntervalSince1970)
    let next = Int64(backoffAt.timeIntervalSince1970)
    let bindings: [Binding?] = [OutboxState.queued.rawValue, ts, next, error, id]
    try db.run(
      """
      UPDATE outbox
      SET state = ?, updated_at = ?, next_attempt_at = ?, last_error = ?
      WHERE id = ?
      """,
      bindings
    )
    try appendEvent(
      outboxID: id, at: ts, from: current.state, to: OutboxState.queued.rawValue, note: error)
  }

  /// Terminal failure: moves the row to `dead_letter` with the final error.
  public func markDeadLetter(id: String, error: String, now: Date = Date()) throws {
    let current = try requireRow(id)
    let ts = Int64(now.timeIntervalSince1970)
    let bindings: [Binding?] = [OutboxState.deadLetter.rawValue, ts, error, id]
    try db.run(
      """
      UPDATE outbox
      SET state = ?, updated_at = ?, last_error = ?
      WHERE id = ?
      """,
      bindings
    )
    try appendEvent(
      outboxID: id,
      at: ts,
      from: current.state,
      to: OutboxState.deadLetter.rawValue,
      note: error
    )
  }

  /// Lists rows optionally filtered by state, newest-first by `created_at`.
  public func list(state: String? = nil, limit: Int = 50) throws -> [OutboxRow] {
    var sql = "SELECT * FROM outbox"
    var bindings: [Binding?] = []
    if let state {
      sql += " WHERE state = ?"
      bindings.append(state)
    }
    sql += " ORDER BY created_at DESC LIMIT ?"
    bindings.append(Int64(limit))
    var rows: [OutboxRow] = []
    for raw in try db.prepare(sql, bindings) {
      rows.append(OutboxStore.decodeRow(raw))
    }
    return rows
  }

  /// Fetches a single row by id, returning `nil` when the id is unknown.
  public func get(id: String) throws -> OutboxRow? {
    return try rowByID(id)
  }

  /// Returns audit-log events for a row, oldest first. Used by `outbox show`
  /// and the `outbox watch` streaming poll.
  public func events(outboxID: String, afterEventID: Int64 = 0, limit: Int = 200) throws
    -> [OutboxEvent]
  {
    let sql =
      """
      SELECT id, outbox_id, at, from_state, to_state, note
      FROM outbox_events
      WHERE outbox_id = ? AND id > ?
      ORDER BY id ASC
      LIMIT ?
      """
    let bindings: [Binding?] = [outboxID, afterEventID, Int64(limit)]
    var events: [OutboxEvent] = []
    for row in try db.prepare(sql, bindings) {
      events.append(
        OutboxEvent(
          id: (row[0] as? Int64) ?? Int64((row[0] as? Int) ?? 0),
          outboxID: (row[1] as? String) ?? "",
          at: (row[2] as? Int64) ?? Int64((row[2] as? Int) ?? 0),
          fromState: row[3] as? String,
          toState: (row[4] as? String) ?? "",
          note: row[5] as? String
        )
      )
    }
    return events
  }

  /// Returns *all* events after `afterEventID` across rows. Backs `outbox watch`.
  public func allEvents(afterEventID: Int64 = 0, limit: Int = 200) throws -> [OutboxEvent] {
    let sql =
      """
      SELECT id, outbox_id, at, from_state, to_state, note
      FROM outbox_events
      WHERE id > ?
      ORDER BY id ASC
      LIMIT ?
      """
    let bindings: [Binding?] = [afterEventID, Int64(limit)]
    var events: [OutboxEvent] = []
    for row in try db.prepare(sql, bindings) {
      events.append(
        OutboxEvent(
          id: (row[0] as? Int64) ?? Int64((row[0] as? Int) ?? 0),
          outboxID: (row[1] as? String) ?? "",
          at: (row[2] as? Int64) ?? Int64((row[2] as? Int) ?? 0),
          fromState: row[3] as? String,
          toState: (row[4] as? String) ?? "",
          note: row[5] as? String
        )
      )
    }
    return events
  }

  /// Moves a `failed` or `dead_letter` row back to `queued`. Operator-driven.
  public func retry(id: String, resetAttempts: Bool = false, now: Date = Date()) throws -> OutboxRow
  {
    let current = try requireRow(id)
    let ts = Int64(now.timeIntervalSince1970)
    let attempts = resetAttempts ? 0 : current.attempts
    let bindings: [Binding?] = [
      OutboxState.queued.rawValue, ts, ts, Int64(attempts), id,
    ]
    try db.run(
      """
      UPDATE outbox
      SET state = ?, updated_at = ?, next_attempt_at = ?, attempts = ?, last_error = NULL
      WHERE id = ?
      """,
      bindings
    )
    try appendEvent(
      outboxID: id,
      at: ts,
      from: current.state,
      to: OutboxState.queued.rawValue,
      note: "manual retry"
    )
    return try requireRow(id)
  }

  // MARK: - Internals

  private func rowByID(_ id: String) throws -> OutboxRow? {
    let sql = "SELECT * FROM outbox WHERE id = ? LIMIT 1"
    for raw in try db.prepare(sql, id) {
      return OutboxStore.decodeRow(raw)
    }
    return nil
  }

  private func rowByIdempotency(_ key: String) throws -> OutboxRow? {
    let sql = "SELECT * FROM outbox WHERE idempotency_key = ? LIMIT 1"
    for raw in try db.prepare(sql, key) {
      return OutboxStore.decodeRow(raw)
    }
    return nil
  }

  private func requireRow(_ id: String) throws -> OutboxRow {
    guard let row = try rowByID(id) else { throw OutboxStoreError.notFound(id) }
    return row
  }

  private func appendEvent(
    outboxID: String, at: Int64, from: String?, to: String, note: String?
  ) throws {
    let bindings: [Binding?] = [outboxID, at, from, to, note]
    try db.run(
      """
      INSERT INTO outbox_events (outbox_id, at, from_state, to_state, note)
      VALUES (?,?,?,?,?)
      """,
      bindings
    )
  }

  private static func newID() -> String {
    // Simple time-ordered id: 10-byte unix ms + 8-byte random hex. Not a
    // strict ULID but close enough for audit ordering without new deps.
    let ms = Int64(Date().timeIntervalSince1970 * 1000)
    let rand = UInt64.random(in: 0...UInt64.max)
    return String(format: "%013X%016X", ms, rand)
  }

  private static func decodeRow(_ row: [Binding?]) -> OutboxRow {
    return OutboxRow(
      id: (row[0] as? String) ?? "",
      idempotencyKey: (row[1] as? String) ?? "",
      toHandle: row[2] as? String,
      chatID: (row[3] as? Int64) ?? (row[3] as? Int).map(Int64.init),
      text: row[4] as? String,
      filePath: row[5] as? String,
      service: (row[6] as? String) ?? "iMessage",
      region: row[7] as? String,
      state: (row[8] as? String) ?? OutboxState.queued.rawValue,
      attempts: (row[9] as? Int) ?? Int((row[9] as? Int64) ?? 0),
      nextAttemptAt: (row[10] as? Int64) ?? (row[10] as? Int).map(Int64.init),
      createdAt: (row[11] as? Int64) ?? Int64((row[11] as? Int) ?? 0),
      updatedAt: (row[12] as? Int64) ?? Int64((row[12] as? Int) ?? 0),
      lastError: row[13] as? String,
      verifiedGUID: row[14] as? String,
      verifiedRowid: (row[15] as? Int64) ?? (row[15] as? Int).map(Int64.init)
    )
  }
}

#endif
