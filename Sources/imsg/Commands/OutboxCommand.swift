#if os(macOS)
import Commander
import Foundation
import IMsgCore

enum OutboxCommand {
  static let spec = CommandSpec(
    name: "outbox",
    abstract: "Queued send with delivery verification",
    discussion: """
      Durable send queue with idempotency, retry, and chat.db delivery
      verification. See docs/outbox.md for the full design.

      Actions:
        enqueue    Add a new row (requires --to or --chat-id plus --text or --file)
        list       List rows (optionally filter by --state)
        show       Show a single row plus event log (--id <ID>)
        retry      Move a failed row back to queued (--id <ID>)
        retry-all  Move every row with --state failed back to queued
        verify     One-shot re-check of a sent row against chat.db (--id <ID>)
        drain      Block until queue empty or --timeout elapses
        watch      Stream event log entries as JSON lines
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(
            label: "action", names: [.long("action")],
            help: "enqueue|list|show|retry|retry-all|verify|drain|watch"),
          .make(label: "id", names: [.long("id")], help: "outbox row id"),
          .make(label: "to", names: [.long("to")], help: "handle to send to"),
          .make(label: "chatID", names: [.long("chat-id")], help: "chat rowid to send to"),
          .make(label: "text", names: [.long("text")], help: "message text"),
          .make(label: "file", names: [.long("file")], help: "attachment path"),
          .make(
            label: "service", names: [.long("service")],
            help: "service: imessage|sms"),
          .make(
            label: "region", names: [.long("region")],
            help: "default region for phone normalization"),
          .make(
            label: "idempotencyKey", names: [.long("idempotency-key")],
            help: "User-supplied idempotency key; defaults to sha256(to|chat|text|file|service)."),
          .make(label: "state", names: [.long("state")], help: "filter by state"),
          .make(label: "limit", names: [.long("limit")], help: "row limit"),
          .make(
            label: "timeout", names: [.long("timeout")], help: "drain timeout seconds"),
          .make(
            label: "store", names: [.long("store")],
            help: "override outbox store path "
              + "(defaults to ~/Library/Application Support/imsg/outbox.sqlite)"
          ),
        ]
      )
    ),
    usageExamples: [
      "imsg outbox --action enqueue --to +14155551212 --text 'hi'",
      "imsg outbox --action list --state queued",
      "imsg outbox --action show --id <ID>",
      "imsg outbox --action drain --timeout 60",
      "imsg outbox --action watch",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    let action = values.option("action") ?? "list"
    let store: OutboxStore
    if let path = values.option("store"), !path.isEmpty {
      store = try await OutboxStore.open(at: URL(fileURLWithPath: path))
    } else {
      store = try await OutboxStore.openDefault()
    }

    switch action {
    case "enqueue":
      try await runEnqueue(values: values, runtime: runtime, store: store)
    case "list":
      try await runList(values: values, runtime: runtime, store: store)
    case "show":
      try await runShow(values: values, runtime: runtime, store: store)
    case "retry":
      try await runRetry(values: values, runtime: runtime, store: store)
    case "retry-all":
      try await runRetryAll(values: values, runtime: runtime, store: store)
    case "verify":
      try await runVerify(values: values, runtime: runtime, store: store)
    case "drain":
      try await runDrain(values: values, runtime: runtime, store: store)
    case "watch":
      try await runWatch(values: values, runtime: runtime, store: store)
    default:
      throw ParsedValuesError.invalidOption("action")
    }
  }

  // MARK: - enqueue

  private static func runEnqueue(
    values: ParsedValues, runtime: RuntimeOptions, store: OutboxStore
  ) async throws {
    let to = values.option("to") ?? ""
    let chatID = values.optionInt64("chatID")
    let text = values.option("text")
    let file = values.option("file")
    let service = values.option("service") ?? "iMessage"
    let region = values.option("region")
    let key = values.option("idempotencyKey")

    guard !(to.isEmpty && chatID == nil) else {
      throw ParsedValuesError.missingOption("to or chat-id")
    }
    if (text ?? "").isEmpty && (file ?? "").isEmpty {
      throw ParsedValuesError.missingOption("text or file")
    }
    let recipient: OutboxRecipient
    if let chatID { recipient = .chat(chatID) } else { recipient = .handle(to) }
    let item = OutboxItem(
      recipient: recipient,
      text: text,
      filePath: file,
      service: service,
      region: region,
      idempotencyKey: key
    )
    let row = try await store.enqueue(item)
    try emit(row: row, runtime: runtime)
  }

  // MARK: - list / show

  private static func runList(
    values: ParsedValues, runtime: RuntimeOptions, store: OutboxStore
  ) async throws {
    let state = values.option("state")
    let limit = values.optionInt("limit") ?? 50
    let rows = try await store.list(state: state, limit: limit)
    if runtime.jsonOutput {
      for row in rows {
        try JSONLines.printEnvelope(kind: "outbox", data: row)
      }
    } else {
      for row in rows {
        StdoutWriter.writeLine(humanSummary(row: row))
      }
    }
  }

  private static func runShow(
    values: ParsedValues, runtime: RuntimeOptions, store: OutboxStore
  ) async throws {
    let id = try values.optionRequired("id")
    guard let row = try await store.get(id: id) else {
      throw OutboxStoreError.notFound(id)
    }
    let events = try await store.events(outboxID: id, afterEventID: 0, limit: 1000)
    if runtime.jsonOutput {
      try JSONLines.printEnvelope(
        kind: "outbox",
        data: OutboxShowPayload(row: row, events: events)
      )
    } else {
      StdoutWriter.writeLine(humanSummary(row: row))
      for e in events {
        let from = e.fromState ?? "-"
        StdoutWriter.writeLine(
          "  [\(e.at)] \(from) -> \(e.toState)\(e.note.map { ": \($0)" } ?? "")")
      }
    }
  }

  // MARK: - retry

  private static func runRetry(
    values: ParsedValues, runtime: RuntimeOptions, store: OutboxStore
  ) async throws {
    let id = try values.optionRequired("id")
    let row = try await store.retry(id: id, resetAttempts: false)
    try emit(row: row, runtime: runtime)
  }

  private static func runRetryAll(
    values: ParsedValues, runtime: RuntimeOptions, store: OutboxStore
  ) async throws {
    let state = values.option("state") ?? OutboxState.failed.rawValue
    let rows = try await store.list(state: state, limit: 1000)
    for row in rows {
      let updated = try await store.retry(id: row.id, resetAttempts: false)
      try emit(row: updated, runtime: runtime)
    }
  }

  // MARK: - verify

  private static func runVerify(
    values: ParsedValues, runtime: RuntimeOptions, store: OutboxStore
  ) async throws {
    let id = try values.optionRequired("id")
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let messageStore = try MessageStore(path: dbPath)
    let sender = OutboxMessageSender()
    let worker = OutboxWorker(store: store, sender: sender, messageStore: messageStore)
    let row = try await worker.verify(id: id)
    try emit(row: row, runtime: runtime)
  }

  // MARK: - drain

  private static func runDrain(
    values: ParsedValues, runtime: RuntimeOptions, store: OutboxStore
  ) async throws {
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let messageStore = try MessageStore(path: dbPath)
    let timeoutSeconds = values.optionInt("timeout") ?? 90
    let sender = OutboxMessageSender()
    let worker = OutboxWorker(store: store, sender: sender, messageStore: messageStore)
    do {
      try await worker.drain(timeout: .seconds(timeoutSeconds))
    } catch is OutboxWorker.DrainError {
      if runtime.jsonOutput {
        try JSONLines.printEnvelope(
          kind: "outbox", data: ["status": "timeout"])
      } else {
        StdoutWriter.writeLine("drain: timeout")
      }
      return
    }
    if runtime.jsonOutput {
      try JSONLines.printEnvelope(kind: "outbox", data: ["status": "drained"])
    } else {
      StdoutWriter.writeLine("drain: done")
    }
  }

  // MARK: - watch

  private static func runWatch(
    values: ParsedValues, runtime: RuntimeOptions, store: OutboxStore
  ) async throws {
    var cursor: Int64 = 0
    while !Task.isCancelled {
      let batch = try await store.allEvents(afterEventID: cursor, limit: 500)
      for event in batch {
        if event.id > cursor { cursor = event.id }
        if runtime.jsonOutput {
          try JSONLines.printEnvelope(kind: "outbox_event", data: event)
        } else {
          let from = event.fromState ?? "-"
          StdoutWriter.writeLine(
            "[\(event.at)] \(event.outboxID) \(from) -> \(event.toState)"
              + (event.note.map { " (\($0))" } ?? "")
          )
        }
      }
      try await Task.sleep(for: .milliseconds(250))
    }
  }

  // MARK: - helpers

  private static func emit(row: OutboxRow, runtime: RuntimeOptions) throws {
    if runtime.jsonOutput {
      try JSONLines.printEnvelope(kind: "outbox", data: row)
    } else {
      StdoutWriter.writeLine(humanSummary(row: row))
    }
  }

  private static func humanSummary(row: OutboxRow) -> String {
    let target = row.toHandle ?? row.chatID.map { "chat:\($0)" } ?? "?"
    let body = row.text ?? row.filePath ?? ""
    let preview = body.isEmpty ? "" : String(body.prefix(40))
    return "[\(row.id)] state=\(row.state) attempts=\(row.attempts) "
      + "to=\(target) text=\(preview.debugDescription)"
  }
}

struct OutboxShowPayload: Codable {
  let row: OutboxRow
  let events: [OutboxEvent]
}

#endif
