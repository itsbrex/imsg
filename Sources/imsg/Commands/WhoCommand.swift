import Commander
import Foundation
import IMsgCore

enum WhoCommand {
  static let spec = CommandSpec(
    name: "who",
    abstract: "Resolve a handle or chat participants to Contacts display names",
    discussion: "See docs/contacts.md.",
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "handle", names: [.long("handle"), .short("H")], help: "Phone or email"),
          .make(label: "chatID", names: [.long("chat-id")], help: "List chat participants"),
        ]
      )
    ),
    usageExamples: [
      "imsg who --handle +14155551212",
      "imsg who --chat-id 42 --json",
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
    }
  ) async throws {
    let bridge = await bridgeFactory()

    if let handle = values.option("handle") {
      let contact = try await bridge.find(handle: handle)
      try emit(records: [(handle, contact)], runtime: runtime)
      return
    }

    if let chatID = values.optionInt64("chatID") {
      let dbPath = values.option("db") ?? MessageStore.defaultPath
      let store = try storeFactory(dbPath)
      let participants = try store.participants(chatID: chatID)
      var records: [(String, Contact?)] = []
      for handle in participants {
        let contact = try await bridge.find(handle: handle)
        records.append((handle, contact))
      }
      try emit(records: records, runtime: runtime)
      return
    }

    throw ParsedValuesError.missingOption("handle")
  }

  private static func emit(records: [(String, Contact?)], runtime: RuntimeOptions) throws {
    if runtime.jsonOutput {
      let payload = records.map { (handle, contact) -> [String: Any] in
        [
          "handle": handle,
          "display_name": contact?.name as Any? ?? NSNull(),
          "source": contact == nil ? "fallback" : "contacts",
        ]
      }
      try JSONLines.printObject(["records": payload])
    } else {
      for (handle, contact) in records {
        let label = contact?.name ?? handle
        StdoutWriter.writeLine("\(label) <\(handle)>")
      }
    }
  }
}
