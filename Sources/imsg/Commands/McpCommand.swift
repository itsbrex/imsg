#if os(macOS)
import Commander
import Foundation
import IMsgCore

enum McpCommand {
  // Computed rather than `static let` so the closure capturing the MCPServer
  // actor isn't eagerly initialized at type load. Swift 6.2 rejects the
  // stored form as "actor-isolated default value in a nonisolated context".
  static var spec: CommandSpec {
    CommandSpec(
    name: "mcp",
    abstract: "Run a Model Context Protocol (MCP) stdio server",
    discussion: """
      Starts an MCP 2024-11-05 server on stdin/stdout, exposing iMessage
      read and watch capabilities as tools (imsg.chats.list, imsg.history,
      imsg.watch.subscribe, imsg.watch.unsubscribe, imsg.search).

      Mutating tools (imsg.send, imsg.react) are disabled by default and
      return JSON-RPC error -32001 unless the server is started with
      --allow-send.

      The server delegates to the same MessageStore / MessageSender /
      MessageWatcher surfaces used by `imsg rpc`, so behavior is
      consistent across transports.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions(),
        flags: [
          .make(
            label: "allowSend", names: [.long("allow-send")],
            help:
              "Enable mutating tools (imsg.send, imsg.react). Off by default."
          )
        ]
      )
    ),
    usageExamples: [
      "imsg mcp",
      "imsg mcp --allow-send",
      "imsg mcp --db ~/Library/Messages/chat.db",
    ]
  ) { values, runtime in
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let store = try MessageStore(path: dbPath)
    let server = MCPServer(store: store, allowSend: runtime.allowSend)
    do {
      try await server.run()
    } catch {
      // Surface the error to stderr and let CommandRouter report the non-zero
      // exit code by rethrowing (see `Sources/imsg/CommandRouter.swift:55-61`).
      FileHandle.standardError.write(
        Data(("imsg mcp: \(error)\n").utf8)
      )
      throw error
    }
  }
  }
}

#endif
