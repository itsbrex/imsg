import Commander
import Foundation
import IMsgCore

/// Test seam for mutating tools so unit tests can avoid AppleScript execution.
/// Default production binding delegates to `MessageSender.send(_:)`
/// (`Sources/IMsgCore/MessageSender.swift:64-79`) and the `ReactCommand`
/// run path (`Sources/imsg/Commands/ReactCommand.swift:41-90`).
protocol SendInvoker: Sendable {
  func sendMessage(_ options: MessageSendOptions) throws
  func sendReaction(chatID: Int64, reaction: String, store: MessageStore) async throws
}

/// Default invoker that dispatches to the production sender / reaction path.
struct DefaultSendInvoker: SendInvoker {
  func sendMessage(_ options: MessageSendOptions) throws {
    // Mirrors `RPCServer.init(... sendMessage:)` default at
    // `Sources/imsg/RPCServer.swift:23`.
    try MessageSender().send(options)
  }

  func sendReaction(chatID: Int64, reaction: String, store: MessageStore) async throws {
    // Mirror ReactCommand.run() so we don't duplicate the React plumbing.
    // `Sources/imsg/Commands/ReactCommand.swift:41-90` is the canonical
    // implementation. We synthesize a ParsedValues with only the required
    // options; ReactCommand does not read any flag beyond chatID / reaction.
    let values = ParsedValues(
      positional: [],
      options: [
        "chatID": [String(chatID)],
        "reaction": [reaction],
      ],
      flags: []
    )
    let runtime = RuntimeOptions(parsedValues: values)
    try await ReactCommand.run(
      values: values,
      runtime: runtime,
      storeFactory: { _ in store }
    )
  }
}

/// JSON-RPC error codes used by the MCP tool handlers.
enum MCPErrorCode {
  static let parseError = -32700
  static let invalidRequest = -32600
  static let methodNotFound = -32601
  static let invalidParams = -32602
  static let internalError = -32603
  /// Send disabled (mutating tool called without `--allow-send`).
  static let sendDisabled = -32001
}

/// Dispatches MCP tool calls to the existing `MessageStore` / `MessageSender` /
/// `MessageWatcher` surfaces used by `RPCServer+Handlers.swift`.
///
/// The handler intentionally does not duplicate any JSON-RPC method body from
/// `Sources/imsg/RPCServer+Handlers.swift:5-181`; every tool routes through
/// the same underlying `MessageStore` / `MessageSender` calls.
actor MCPHandlers {
  let store: MessageStore
  let watcher: MessageWatcher
  let cache: ChatCache
  let subscriptions = SubscriptionStore()
  let allowSend: Bool
  let sendInvoker: SendInvoker

  init(
    store: MessageStore,
    allowSend: Bool,
    sendInvoker: SendInvoker = DefaultSendInvoker()
  ) {
    self.store = store
    self.watcher = MessageWatcher(store: store)
    self.cache = ChatCache(store: store)
    self.allowSend = allowSend
    self.sendInvoker = sendInvoker
  }

  /// Entry point used by `MCPServer.handle(request:)` for `tools/call`.
  ///
  /// `params` is the `{name, arguments}` object from the MCP tools/call body.
  /// Returns either a successful `{content: [...], structuredContent: ...}`
  /// payload or throws an `MCPToolError` which `MCPServer` maps to a
  /// JSON-RPC error object.
  func call(name: String, arguments: JSONValue?) async throws -> JSONValue {
    let args = arguments ?? .object([:])
    switch name {
    case MCPToolCatalog.chatsList.name:
      return try await handleChatsList(args: args)
    case MCPToolCatalog.history.name:
      return try await handleHistory(args: args)
    case MCPToolCatalog.watchSubscribe.name:
      return try await handleWatchSubscribe(args: args)
    case MCPToolCatalog.watchUnsubscribe.name:
      return try await handleWatchUnsubscribe(args: args)
    case MCPToolCatalog.send.name:
      return try await handleSend(args: args)
    case MCPToolCatalog.react.name:
      return try await handleReact(args: args)
    case MCPToolCatalog.search.name:
      throw MCPToolError(
        code: MCPErrorCode.methodNotFound,
        message: "not implemented until W3.D1"
      )
    default:
      throw MCPToolError(
        code: MCPErrorCode.methodNotFound,
        message: "unknown tool: \(name)"
      )
    }
  }

  func cancelAllSubscriptions() async {
    await subscriptions.cancelAll()
  }

  // MARK: - Tool implementations

  private func handleChatsList(args: JSONValue) async throws -> JSONValue {
    let limit = args.field("limit")?.intValue ?? 20
    // Delegates to `MessageStore.listChats(limit:)`
    // (`Sources/IMsgCore/MessageStore.swift:117`).
    let chats = try store.listChats(limit: max(limit, 1))

    var payloads: [JSONValue] = []
    payloads.reserveCapacity(chats.count)
    for chat in chats {
      let info = try await cache.info(chatID: chat.id)
      let participants = try await cache.participants(chatID: chat.id)
      let identifier = info?.identifier ?? chat.identifier
      let guid = info?.guid ?? ""
      let name =
        (info?.name.isEmpty == false ? info?.name : nil) ?? chat.name
      let service = info?.service ?? chat.service
      payloads.append(
        .object([
          "id": .int(chat.id),
          "identifier": .string(identifier),
          "guid": .string(guid),
          "name": .string(name),
          "service": .string(service),
          "last_message_at": .string(CLIISO8601.format(chat.lastMessageAt)),
          "participants": .array(participants.map { .string($0) }),
          "is_group": .bool(isGroupHandle(identifier: identifier, guid: guid)),
        ]))
    }

    return envelope(kind: "chats", data: .object(["chats": .array(payloads)]))
  }

  private func handleHistory(args: JSONValue) async throws -> JSONValue {
    guard let chatID = args.field("chat_id")?.int64Value else {
      throw MCPToolError(
        code: MCPErrorCode.invalidParams,
        message: "chat_id is required"
      )
    }
    let limit = args.field("limit")?.intValue ?? 50
    let participants = stringArray(args.field("participants"))
    let startISO = args.field("start")?.stringValue
    let endISO = args.field("end")?.stringValue
    let includeAttachments = args.field("attachments")?.boolValue ?? false

    let filter: MessageFilter
    do {
      filter = try MessageFilter.fromISO(
        participants: participants,
        startISO: startISO,
        endISO: endISO
      )
    } catch {
      throw MCPToolError(
        code: MCPErrorCode.invalidParams,
        message: error.localizedDescription
      )
    }

    // Delegates to `MessageStore.messages(chatID:limit:filter:)`
    // (`Sources/IMsgCore/MessageStore+Messages.swift:45`), matching the
    // existing RPC handler at `Sources/imsg/RPCServer+Handlers.swift:47`.
    let filtered = try store.messages(
      chatID: chatID,
      limit: max(limit, 1),
      filter: filter
    )

    var payloads: [JSONValue] = []
    payloads.reserveCapacity(filtered.count)
    for message in filtered {
      let chatInfo = try await cache.info(chatID: message.chatID)
      let participants = try await cache.participants(chatID: message.chatID)
      let attachments =
        includeAttachments ? try store.attachments(for: message.rowID) : []
      let reactions =
        includeAttachments ? try store.reactions(for: message.rowID) : []
      let payload = MessagePayload(
        message: message,
        attachments: attachments,
        reactions: reactions
      )
      var dict = try payload.asDictionary()
      dict["chat_identifier"] = chatInfo?.identifier ?? ""
      dict["chat_guid"] = chatInfo?.guid ?? ""
      dict["chat_name"] = chatInfo?.name ?? ""
      dict["participants"] = participants
      dict["is_group"] = isGroupHandle(
        identifier: chatInfo?.identifier ?? "",
        guid: chatInfo?.guid ?? ""
      )
      payloads.append(jsonValue(from: dict))
    }

    return envelope(kind: "messages", data: .object(["messages": .array(payloads)]))
  }

  private func handleWatchSubscribe(args: JSONValue) async throws -> JSONValue {
    let chatID = args.field("chat_id")?.int64Value
    let sinceRowID = args.field("since_rowid")?.int64Value
    let participants = stringArray(args.field("participants"))
    let startISO = args.field("start")?.stringValue
    let endISO = args.field("end")?.stringValue
    let includeAttachments = args.field("attachments")?.boolValue ?? false
    let includeReactions = args.field("include_reactions")?.boolValue ?? false

    let filter: MessageFilter
    do {
      filter = try MessageFilter.fromISO(
        participants: participants,
        startISO: startISO,
        endISO: endISO
      )
    } catch {
      throw MCPToolError(
        code: MCPErrorCode.invalidParams,
        message: error.localizedDescription
      )
    }

    let config = MessageWatcherConfiguration(includeReactions: includeReactions)
    let subID = await subscriptions.allocateID()

    // Mirror the stream wiring in
    // `Sources/imsg/RPCServer+Handlers.swift:64-120` but emit MCP
    // notifications via `MCPFraming` instead of the JSON-RPC writer.
    let localStore = store
    let localCache = cache
    let localWatcher = watcher
    let task = Task {
      do {
        for try await message in localWatcher.stream(
          chatID: chatID,
          sinceRowID: sinceRowID,
          configuration: config
        ) {
          if Task.isCancelled { return }
          if !filter.allows(message) { continue }
          let chatInfo = try await localCache.info(chatID: message.chatID)
          let participants = try await localCache.participants(chatID: message.chatID)
          let attachments =
            includeAttachments
            ? try localStore.attachments(for: message.rowID)
            : []
          let reactions =
            includeAttachments
            ? try localStore.reactions(for: message.rowID)
            : []
          let payload = MessagePayload(
            message: message,
            attachments: attachments,
            reactions: reactions
          )
          var dict = try payload.asDictionary()
          dict["chat_identifier"] = chatInfo?.identifier ?? ""
          dict["chat_guid"] = chatInfo?.guid ?? ""
          dict["chat_name"] = chatInfo?.name ?? ""
          dict["participants"] = participants
          dict["is_group"] = isGroupHandle(
            identifier: chatInfo?.identifier ?? "",
            guid: chatInfo?.guid ?? ""
          )
          let params = JSONValue.object([
            "subscription_id": .int(Int64(subID)),
            "message": jsonValue(from: dict),
          ])
          try? MCPFraming.write(
            notification: MCPNotification(method: "notifications/message", params: params)
          )
        }
      } catch {
        let params = JSONValue.object([
          "subscription_id": .int(Int64(subID)),
          "error": .object([
            "message": .string(String(describing: error))
          ]),
        ])
        try? MCPFraming.write(
          notification: MCPNotification(method: "notifications/error", params: params)
        )
      }
    }
    await subscriptions.insert(task, for: subID)

    return envelope(
      kind: "watch.subscription",
      data: .object(["subscription_id": .int(Int64(subID))])
    )
  }

  private func handleWatchUnsubscribe(args: JSONValue) async throws -> JSONValue {
    guard let subID = args.field("subscription_id")?.intValue else {
      throw MCPToolError(
        code: MCPErrorCode.invalidParams,
        message: "subscription_id is required"
      )
    }
    if let task = await subscriptions.remove(subID) {
      task.cancel()
    }
    return envelope(kind: "watch.unsubscribe", data: .object(["ok": .bool(true)]))
  }

  private func handleSend(args: JSONValue) async throws -> JSONValue {
    guard allowSend else {
      throw MCPToolError(
        code: MCPErrorCode.sendDisabled,
        message: "send disabled; restart imsg mcp with --allow-send"
      )
    }

    let text = args.field("text")?.stringValue ?? ""
    let file = args.field("file")?.stringValue ?? ""
    let serviceRaw = args.field("service")?.stringValue ?? "auto"
    guard let service = MessageService(rawValue: serviceRaw) else {
      throw MCPToolError(
        code: MCPErrorCode.invalidParams,
        message: "invalid service"
      )
    }
    let region = args.field("region")?.stringValue ?? "US"

    let input = ChatTargetInput(
      recipient: args.field("to")?.stringValue ?? "",
      chatID: args.field("chat_id")?.int64Value,
      chatIdentifier: args.field("chat_identifier")?.stringValue ?? "",
      chatGUID: args.field("chat_guid")?.stringValue ?? ""
    )
    // Reuse the validation from
    // `Sources/imsg/ChatTargetResolver.swift:26-37` and the resolver from
    // `ChatTargetResolver.swift:39-59`, matching the RPC send handler at
    // `Sources/imsg/RPCServer+Handlers.swift:132-180`.
    try ChatTargetResolver.validateRecipientRequirements(
      input: input,
      mixedTargetError: MCPToolError(
        code: MCPErrorCode.invalidParams,
        message: "use to or chat_*; not both"
      ),
      missingRecipientError: MCPToolError(
        code: MCPErrorCode.invalidParams,
        message: "to is required for direct sends"
      )
    )

    if text.isEmpty && file.isEmpty {
      throw MCPToolError(
        code: MCPErrorCode.invalidParams,
        message: "text or file is required"
      )
    }

    let cacheRef = cache
    let resolvedTarget = try await ChatTargetResolver.resolveChatTarget(
      input: input,
      lookupChat: { chatID in try await cacheRef.info(chatID: chatID) },
      unknownChatError: { chatID in
        MCPToolError(
          code: MCPErrorCode.invalidParams,
          message: "unknown chat_id \(chatID)"
        )
      }
    )
    if input.hasChatTarget && resolvedTarget.preferredIdentifier == nil {
      throw MCPToolError(
        code: MCPErrorCode.invalidParams,
        message: "missing chat identifier or guid"
      )
    }

    do {
      try sendInvoker.sendMessage(
        MessageSendOptions(
          recipient: input.recipient,
          text: text,
          attachmentPath: file,
          service: service,
          region: region,
          chatIdentifier: resolvedTarget.chatIdentifier,
          chatGUID: resolvedTarget.chatGUID
        )
      )
    } catch let err as IMsgError {
      switch err {
      case .invalidService, .invalidChatTarget:
        throw MCPToolError(
          code: MCPErrorCode.invalidParams,
          message: err.errorDescription ?? "invalid params"
        )
      default:
        throw MCPToolError(
          code: MCPErrorCode.internalError,
          message: err.localizedDescription
        )
      }
    } catch {
      throw MCPToolError(
        code: MCPErrorCode.internalError,
        message: error.localizedDescription
      )
    }

    return envelope(kind: "send.result", data: .object(["ok": .bool(true)]))
  }

  private func handleReact(args: JSONValue) async throws -> JSONValue {
    guard allowSend else {
      throw MCPToolError(
        code: MCPErrorCode.sendDisabled,
        message: "send disabled; restart imsg mcp with --allow-send"
      )
    }
    guard let chatID = args.field("chat_id")?.int64Value else {
      throw MCPToolError(
        code: MCPErrorCode.invalidParams,
        message: "chat_id is required"
      )
    }
    guard let reaction = args.field("reaction")?.stringValue, !reaction.isEmpty
    else {
      throw MCPToolError(
        code: MCPErrorCode.invalidParams,
        message: "reaction is required"
      )
    }

    do {
      try await sendInvoker.sendReaction(
        chatID: chatID,
        reaction: reaction,
        store: store
      )
    } catch let err as IMsgError {
      throw MCPToolError(
        code: MCPErrorCode.internalError,
        message: err.localizedDescription
      )
    } catch {
      throw MCPToolError(
        code: MCPErrorCode.internalError,
        message: error.localizedDescription
      )
    }

    return envelope(
      kind: "react.result",
      data: .object([
        "ok": .bool(true),
        "chat_id": .int(chatID),
        "reaction": .string(reaction),
      ])
    )
  }

  // MARK: - Helpers

  /// Wrap a tool's payload in the schema envelope `{schema, kind, data}`.
  /// Schema string pulled from `IMsgCore.IMsgSchema.currentVersion`
  /// (`Sources/IMsgCore/SchemaVersion.swift:4`) so bumps stay single-sourced.
  private func envelope(kind: String, data: JSONValue) -> JSONValue {
    .object([
      "schema": .string(IMsgSchema.currentVersion),
      "kind": .string(kind),
      "data": data,
    ])
  }

  private func stringArray(_ value: JSONValue?) -> [String] {
    guard let value else { return [] }
    if let items = value.arrayValue {
      return items.compactMap { $0.stringValue }
    }
    if let string = value.stringValue {
      return string
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }
    return []
  }
}

// MARK: - JSONValue <-> [String: Any] bridging

/// Convert an arbitrary `[String: Any]` dictionary (as produced by
/// `MessagePayload.asDictionary()` via `JSONSerialization`) into a `JSONValue`
/// so the MCP response can carry the payload verbatim.
func jsonValue(from any: Any) -> JSONValue {
  if any is NSNull { return .null }
  if let string = any as? String { return .string(string) }
  if let bool = any as? Bool { return .bool(bool) }
  if let number = any as? NSNumber {
    // NSNumber bridging: distinguish bool vs int vs double.
    let type = String(cString: number.objCType)
    if type == "c" || type == "B" {
      return .bool(number.boolValue)
    }
    if type == "d" || type == "f" {
      return .double(number.doubleValue)
    }
    return .int(number.int64Value)
  }
  if let int = any as? Int { return .int(Int64(int)) }
  if let int64 = any as? Int64 { return .int(int64) }
  if let double = any as? Double { return .double(double) }
  if let array = any as? [Any] {
    return .array(array.map { jsonValue(from: $0) })
  }
  if let dict = any as? [String: Any] {
    var out: [String: JSONValue] = [:]
    out.reserveCapacity(dict.count)
    for (key, value) in dict {
      out[key] = jsonValue(from: value)
    }
    return .object(out)
  }
  return .null
}

/// Thrown by MCP tool handlers; `MCPServer` maps this to a JSON-RPC error.
struct MCPToolError: Error, Sendable {
  let code: Int
  let message: String
  let data: JSONValue?

  init(code: Int, message: String, data: JSONValue? = nil) {
    self.code = code
    self.message = message
    self.data = data
  }

  var asErrorObject: MCPErrorObject {
    MCPErrorObject(code: code, message: message, data: data)
  }
}
