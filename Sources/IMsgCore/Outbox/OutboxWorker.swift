import Foundation

/// Retry budget for ``OutboxWorker``. Mirrors the table in `docs/outbox.md`
/// §Retry policy.
public struct OutboxRetryPolicy: Sendable {
  public var maxAttempts: Int
  public var schedule: [Duration]
  public var jitter: Duration

  public init(
    maxAttempts: Int = 5,
    schedule: [Duration] = [
      .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(32),
    ],
    jitter: Duration = .milliseconds(250)
  ) {
    self.maxAttempts = maxAttempts
    self.schedule = schedule
    self.jitter = jitter
  }

  func backoff(for attempts: Int) -> Duration {
    // `attempts` is the number of attempts already made. After the first
    // failure (`attempts == 1`) we wait `schedule[0]`.
    let idx = max(0, min(attempts - 1, schedule.count - 1))
    return schedule[idx]
  }
}

/// Abstraction over ``MessageSender`` so tests can inject a mock. We keep
/// ``MessageSender`` untouched (Wave 2c constraint) and wrap it with a tiny
/// adapter instead.
public protocol OutboxSending: Sendable {
  func send(_ options: MessageSendOptions) throws
}

/// Default adapter forwarding to ``MessageSender`` (see
/// `Sources/IMsgCore/MessageSender.swift:64`).
public struct OutboxMessageSender: OutboxSending {
  private let sender: MessageSender
  public init(sender: MessageSender = MessageSender()) { self.sender = sender }
  public func send(_ options: MessageSendOptions) throws { try sender.send(options) }
}

/// Actor that drains the outbox one row at a time, dispatching through
/// ``OutboxSending`` and verifying delivery against ``MessageStore``.
///
/// Single-flight is guaranteed by actor isolation: concurrent `processNext`
/// calls serialize on the actor executor. The underlying SQLite store is
/// already an actor, so no additional locking is needed. See
/// `docs/outbox.md` §Worker model.
public actor OutboxWorker {
  public struct DrainError: Error, Sendable { public let timeout: Duration }

  private let store: OutboxStore
  private let sender: OutboxSending
  private let messageStore: MessageStore?
  private let policy: OutboxRetryPolicy
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (Duration) async throws -> Void

  public init(
    store: OutboxStore,
    sender: OutboxSending,
    messageStore: MessageStore? = nil,
    policy: OutboxRetryPolicy = OutboxRetryPolicy(),
    now: @escaping @Sendable () -> Date = Date.init,
    sleep: (@Sendable (Duration) async throws -> Void)? = nil
  ) {
    self.store = store
    self.sender = sender
    self.messageStore = messageStore
    self.policy = policy
    self.now = now
    self.sleep = sleep ?? { duration in try await Task.sleep(for: duration) }
  }

  /// Convenience ctor matching the plan signature when callers have a
  /// concrete ``MessageSender``.
  public init(
    store: OutboxStore,
    sender: MessageSender,
    messageStore: MessageStore,
    now: @escaping @Sendable () -> Date = Date.init,
    sleep: (@Sendable (Duration) async throws -> Void)? = nil
  ) {
    self.init(
      store: store,
      sender: OutboxMessageSender(sender: sender),
      messageStore: messageStore,
      now: now,
      sleep: sleep
    )
  }

  /// Passes through to ``OutboxStore/enqueue(_:now:)`` so callers only need
  /// the worker handle.
  public func enqueue(_ item: OutboxItem) async throws -> OutboxRow {
    return try await store.enqueue(item, now: now())
  }

  /// Runs exactly one claim/dispatch/verify pass.
  ///
  /// Returns the post-transition row when a row was processed. Returns `nil`
  /// when no ready rows exist.
  @discardableResult
  public func processNext() async throws -> OutboxRow? {
    let ready = try await store.nextReady(now: now(), limit: 1)
    guard let row = ready.first else { return nil }
    try await store.markSending(id: row.id, now: now())

    let options = buildSendOptions(row: row)
    do {
      try sender.send(options)
    } catch {
      try await handleFailure(rowID: row.id, attempts: row.attempts + 1, error: error)
      return try await store.get(id: row.id)
    }

    try await store.markSent(id: row.id, now: now())
    _ = try? await verify(id: row.id)
    return try await store.get(id: row.id)
  }

  /// Drains until no more rows are ready or `timeout` elapses.
  ///
  /// Returns normally when the queue is empty. Throws ``DrainError`` when the
  /// timeout is hit while rows are still pending.
  public func drain(timeout: Duration = .seconds(90)) async throws {
    let deadline = now().addingTimeInterval(Self.durationToSeconds(timeout))
    while now() < deadline {
      let processed = try await processNext()
      if processed == nil {
        // No ready rows right now. If the store still has `queued` rows with
        // future `next_attempt_at`, sleep until the earliest is ready or the
        // deadline, whichever comes first. Otherwise we are done.
        let pending = try await store.list(state: OutboxState.queued.rawValue, limit: 1)
        guard let next = pending.first,
          let due = next.nextAttemptAt
        else {
          return
        }
        let dueDate = Date(timeIntervalSince1970: TimeInterval(due))
        let wait = min(dueDate, deadline).timeIntervalSince(now())
        if wait <= 0 { continue }
        try await sleep(.milliseconds(Int(wait * 1000)))
      }
    }
    // Deadline hit while rows were still queued.
    let stillQueued = try await store.list(state: OutboxState.queued.rawValue, limit: 1)
    if stillQueued.isEmpty { return }
    throw DrainError(timeout: timeout)
  }

  /// Polls ``MessageStore`` for a matching outgoing message and transitions
  /// to `verified` on match.
  @discardableResult
  public func verify(id: String, window: Duration = .seconds(10)) async throws -> OutboxRow {
    guard let row = try await store.get(id: id) else {
      throw OutboxStoreError.notFound(id)
    }
    guard let ms = messageStore else { return row }

    let startCursor = (try? ms.maxRowID()) ?? 0
    let deadline = now().addingTimeInterval(Self.durationToSeconds(window))
    var cursor = max(0, startCursor - 25)  // allow matching rows already flushed

    while now() < deadline {
      do {
        let batch = try ms.messagesAfter(afterRowID: cursor, chatID: row.chatID, limit: 100)
        for message in batch {
          if message.rowID > cursor { cursor = message.rowID }
          if !message.isFromMe { continue }
          if let text = row.text, !text.isEmpty {
            if matches(outboxText: text, dbText: message.text) {
              try await store.markVerified(
                id: id, verifiedGUID: message.guid, verifiedRowid: message.rowID, now: now())
              if let updated = try await store.get(id: id) { return updated }
            }
          }
          if let filePath = row.filePath, !filePath.isEmpty {
            let basename = (filePath as NSString).lastPathComponent
            let attachments = (try? ms.attachments(for: message.rowID)) ?? []
            if attachments.contains(where: {
              $0.transferName.caseInsensitiveCompare(basename) == .orderedSame
            }) {
              try await store.markVerified(
                id: id, verifiedGUID: message.guid, verifiedRowid: message.rowID, now: now())
              if let updated = try await store.get(id: id) { return updated }
            }
          }
        }
      } catch {
        // Non-fatal: leave row in `sent` state. Callers can re-run
        // `imsg outbox verify <id>` after granting FDA / restarting.
        break
      }
      try await sleep(.milliseconds(500))
    }

    return (try await store.get(id: id)) ?? row
  }

  // MARK: - Internals

  private func handleFailure(rowID: String, attempts: Int, error: Error) async throws {
    let klass = SendErrorClassifier.classify(error)
    let message = String(describing: error)

    if klass == .permissionDenied || klass == .unknownHandle {
      try await store.markDeadLetter(id: rowID, error: "\(klass.rawValue): \(message)", now: now())
      return
    }

    if attempts >= policy.maxAttempts {
      try await store.markDeadLetter(
        id: rowID, error: "max_attempts: \(message)", now: now())
      return
    }

    let base = Self.durationToSeconds(policy.backoff(for: attempts))
    let jitterSeconds = Self.durationToSeconds(policy.jitter)
    let jitter = Double.random(in: -jitterSeconds...jitterSeconds)
    let backoffAt = now().addingTimeInterval(max(0, base + jitter))
    try await store.markFailed(id: rowID, error: message, backoffAt: backoffAt, now: now())
  }

  private func buildSendOptions(row: OutboxRow) -> MessageSendOptions {
    let service: MessageService
    switch row.service.lowercased() {
    case "sms": service = .sms
    case "imessage": service = .imessage
    default: service = .auto
    }
    return MessageSendOptions(
      recipient: row.toHandle ?? "",
      text: row.text ?? "",
      attachmentPath: row.filePath ?? "",
      service: service,
      region: row.region ?? "US",
      chatIdentifier: "",
      chatGUID: ""
    )
  }

  private func matches(outboxText: String, dbText: String) -> Bool {
    return Self.normalize(outboxText) == Self.normalize(dbText)
  }

  static func normalize(_ text: String) -> String {
    let decomposed = text.precomposedStringWithCanonicalMapping
    let trimmed = decomposed.trimmingCharacters(in: .whitespacesAndNewlines)
    let collapsed = trimmed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return collapsed
  }

  private static func durationToSeconds(_ duration: Duration) -> TimeInterval {
    let components = duration.components
    return TimeInterval(components.seconds)
      + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000.0
  }
}
