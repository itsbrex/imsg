import Commander
import Foundation
import IMsgCore

enum GraphCommand {
  static let spec = CommandSpec(
    name: "graph",
    abstract: "Export the local (contact ↔ chat) interaction graph",
    discussion: "See docs/contacts.md.",
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chatID", names: [.long("chat-id")], help: "Limit to a single chat"),
          .make(label: "since", names: [.long("since")], help: "ISO8601 or NNd/NNw window start"),
          .make(label: "until", names: [.long("until")], help: "ISO8601 window end"),
          .make(label: "limit", names: [.long("limit")], help: "Cap messages scanned (default 50000)"),
        ],
        flags: [
          .make(label: "dot", names: [.long("dot")], help: "Emit Graphviz DOT instead of JSON")
        ]
      )
    ),
    usageExamples: [
      "imsg graph --since 30d --json",
      "imsg graph --chat-id 42 --dot > graph.dot",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    storeFactory: @escaping (String) throws -> MessageStore = { try MessageStore(path: $0) },
    bridgeFactory: @escaping () async -> any ContactsBridge = {
      ResolverContactsBridge(resolver: await ContactResolver.create())
    },
    clock: @Sendable () -> Date = { Date() }
  ) async throws {
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let chatID = values.optionInt64("chatID")
    let limit = values.optionInt("limit") ?? 50_000
    let asDOT = values.flag("dot")

    let now = clock()
    let since = try parseWindowEdge(values.option("since"), relativeTo: now)
    let until = try values.option("until").flatMap { iso -> Date? in
      guard let d = CLIISO8601.parse($0) else { throw ParsedValuesError.invalidOption("until") }
      return d
    }
    let window = GraphWindow(since: since, until: until)

    let store = try storeFactory(dbPath)
    let bridge = await bridgeFactory()

    // Fetch messages
    let chatIDsToInclude: [Int64]
    if let chatID {
      chatIDsToInclude = [chatID]
    } else {
      chatIDsToInclude = try store.listChats(limit: 1_000).map { $0.id }
    }

    var messages: [Message] = []
    var chats: [Int64: ChatInfo] = [:]
    for cid in chatIDsToInclude {
      if let info = try store.chatInfo(chatID: cid) { chats[cid] = info }
      let rows = try store.messages(chatID: cid, limit: limit)
      for message in rows {
        if let since, message.date < since { continue }
        if let until, message.date >= until { continue }
        messages.append(message)
      }
    }

    let graph = try await GraphBuilder().build(
      messages: messages,
      chats: chats,
      bridge: bridge,
      window: window,
      generatedAt: now
    )

    if asDOT {
      let dot = GraphExporter.dot(graph)
      StdoutWriter.writeLine(dot.hasSuffix("\n") ? String(dot.dropLast()) : dot)
    } else {
      let data = try GraphExporter.json(graph)
      if let text = String(data: data, encoding: .utf8) {
        StdoutWriter.writeLine(text.hasSuffix("\n") ? String(text.dropLast()) : text)
      }
    }
    _ = runtime
  }

  private static func parseWindowEdge(_ raw: String?, relativeTo now: Date) throws -> Date? {
    guard let raw, !raw.isEmpty else { return nil }
    if let relative = parseRelative(raw, now: now) { return relative }
    guard let date = CLIISO8601.parse(raw) else {
      throw ParsedValuesError.invalidOption("since")
    }
    return date
  }

  private static func parseRelative(_ value: String, now: Date) -> Date? {
    guard let suffix = value.last, suffix == "d" || suffix == "w" else { return nil }
    let digits = value.dropLast()
    guard let amount = Int(digits), amount > 0 else { return nil }
    let seconds: TimeInterval
    switch suffix {
    case "d": seconds = Double(amount) * 86_400
    case "w": seconds = Double(amount) * 86_400 * 7
    default: return nil
    }
    return now.addingTimeInterval(-seconds)
  }
}
