import Commander
import Foundation
import IMsgCore

enum SendCommand {
  static let spec = CommandSpec(
    name: "send",
    abstract: "Send a message (text and/or attachment)",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "to", names: [.long("to")], help: "phone number or email"),
          .make(label: "chatID", names: [.long("chat-id")], help: "chat rowid"),
          .make(
            label: "chatIdentifier", names: [.long("chat-identifier")],
            help: "chat identifier (e.g. iMessage;+;chat...)"),
          .make(label: "chatGUID", names: [.long("chat-guid")], help: "chat guid"),
          .make(label: "text", names: [.long("text")], help: "message body"),
          .make(label: "file", names: [.long("file")], help: "path to attachment"),
          .make(
            label: "service", names: [.long("service")], help: "service to use: imessage|sms|auto"),
          .make(
            label: "region", names: [.long("region")],
            help: "default region for phone normalization"),
          .make(
            label: "idempotencyKey", names: [.long("idempotency-key")],
            help: "User-supplied idempotency key; defaults to sha256(to|chat|text|file|service)."),
        ],
        flags: [
          .make(
            label: "viaOutbox", names: [.long("via-outbox")],
            help: "Enqueue via outbox and wait for delivery verification."
          )
        ]
      )
    ),
    usageExamples: [
      "imsg send --to +14155551212 --text \"hi\"",
      "imsg send --to +14155551212 --text \"hi\" --file ~/Desktop/pic.jpg --service imessage",
      "imsg send --chat-id 1 --text \"hi\"",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    sendMessage: @escaping (MessageSendOptions) throws -> Void = { try MessageSender().send($0) },
    storeFactory: @escaping (String) throws -> MessageStore = { try MessageStore(path: $0) }
  ) async throws {
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let input = ChatTargetInput(
      recipient: values.option("to") ?? "",
      chatID: values.optionInt64("chatID"),
      chatIdentifier: values.option("chatIdentifier") ?? "",
      chatGUID: values.option("chatGUID") ?? ""
    )
    try ChatTargetResolver.validateRecipientRequirements(
      input: input,
      mixedTargetError: ParsedValuesError.invalidOption("to"),
      missingRecipientError: ParsedValuesError.missingOption("to")
    )

    let text = values.option("text") ?? ""
    let file = values.option("file") ?? ""
    if text.isEmpty && file.isEmpty {
      throw ParsedValuesError.missingOption("text or file")
    }
    let serviceRaw = values.option("service") ?? "auto"
    guard let service = MessageService(rawValue: serviceRaw) else {
      throw IMsgError.invalidService(serviceRaw)
    }
    let region = values.option("region") ?? "US"

    let resolvedTarget = try await ChatTargetResolver.resolveChatTarget(
      input: input,
      lookupChat: { chatID in
        let store = try storeFactory(dbPath)
        return try store.chatInfo(chatID: chatID)
      },
      unknownChatError: { chatID in
        IMsgError.invalidChatTarget("Unknown chat id \(chatID)")
      }
    )
    if input.hasChatTarget && resolvedTarget.preferredIdentifier == nil {
      throw IMsgError.invalidChatTarget("Missing chat identifier or guid")
    }

    if values.flag("viaOutbox") {
      try await runViaOutbox(
        values: values,
        runtime: runtime,
        input: input,
        text: text,
        file: file,
        service: service,
        region: region,
        dbPath: dbPath
      )
      return
    }

    try sendMessage(
      MessageSendOptions(
        recipient: input.recipient,
        text: text,
        attachmentPath: file,
        service: service,
        region: region,
        chatIdentifier: resolvedTarget.chatIdentifier,
        chatGUID: resolvedTarget.chatGUID
      ))

    if runtime.jsonOutput {
      try StdoutWriter.writeJSONLine(["status": "sent"])
    } else {
      StdoutWriter.writeLine("sent")
    }
  }

  static func runViaOutbox(
    values: ParsedValues,
    runtime: RuntimeOptions,
    input: ChatTargetInput,
    text: String,
    file: String,
    service: MessageService,
    region: String,
    dbPath: String
  ) async throws {
    let recipient: OutboxRecipient
    if let chatID = input.chatID {
      recipient = .chat(chatID)
    } else {
      recipient = .handle(input.recipient)
    }
    let serviceString: String
    switch service {
    case .sms: serviceString = "SMS"
    case .imessage, .auto: serviceString = "iMessage"
    }
    let item = OutboxItem(
      recipient: recipient,
      text: text.isEmpty ? nil : text,
      filePath: file.isEmpty ? nil : file,
      service: serviceString,
      region: region,
      idempotencyKey: values.option("idempotencyKey")
    )

    let store = try await OutboxStore.openDefault()
    let messageStore = try MessageStore(path: dbPath)
    let sender = OutboxMessageSender()
    let worker = OutboxWorker(store: store, sender: sender, messageStore: messageStore)
    let enqueued = try await worker.enqueue(item)
    do {
      try await worker.drain(timeout: .seconds(90))
    } catch is OutboxWorker.DrainError {
      // Timed out waiting — fall through; the row may still be sent/verified later.
    }
    let final = (try await store.get(id: enqueued.id)) ?? enqueued

    if runtime.jsonOutput {
      try JSONLines.printEnvelope(kind: "outbox", data: final)
    } else {
      StdoutWriter.writeLine(
        "outbox id=\(final.id) state=\(final.state) attempts=\(final.attempts)"
      )
    }

    switch final.state {
    case OutboxState.verified.rawValue, OutboxState.sent.rawValue:
      return
    default:
      // Terminal failure path: surface the classified error so operators can act.
      let detail = final.lastError ?? "outbox \(final.state)"
      throw IMsgError.appleScriptFailure("outbox \(final.state): \(detail)")
    }
  }
}
