#if os(macOS)
import Foundation

/// Catalog entry for one MCP tool. The `inputSchema` is a JSON Schema object
/// emitted verbatim in `tools/list` responses. `requiresSend` marks tools
/// gated behind `--allow-send` (see `MCPHandlers`).
struct MCPTool: Sendable {
  let name: String
  let description: String
  let inputSchema: JSONValue
  let requiresSend: Bool
}

/// Declarative catalog of the 7 MCP tools imsg exposes. Names mirror the RPC
/// methods in `Sources/imsg/RPCServer.swift:80-93` where applicable, namespaced
/// under `imsg.*` per MCP conventions.
enum MCPToolCatalog {
  static let all: [MCPTool] = [
    chatsList,
    history,
    watchSubscribe,
    watchUnsubscribe,
    send,
    react,
    search,
  ]

  static let chatsList = MCPTool(
    name: "imsg.chats.list",
    description: "List recent iMessage / SMS conversations.",
    inputSchema: schemaObject([
      "type": .string("object"),
      "properties": .object([
        "limit": .object([
          "type": .string("integer"),
          "description": .string("Maximum number of chats to return (default 20)."),
        ])
      ]),
      "additionalProperties": .bool(false),
    ]),
    requiresSend: false
  )

  static let history = MCPTool(
    name: "imsg.history",
    description: "Fetch recent messages for a single chat.",
    inputSchema: schemaObject([
      "type": .string("object"),
      "properties": .object([
        "chat_id": .object([
          "type": .string("integer"),
          "description": .string("Chat rowid from imsg.chats.list."),
        ]),
        "limit": .object([
          "type": .string("integer"),
          "description": .string("Maximum number of messages (default 50)."),
        ]),
        "participants": .object([
          "type": .string("array"),
          "items": .object(["type": .string("string")]),
        ]),
        "start": .object([
          "type": .string("string"),
          "description": .string("ISO8601 start (inclusive)."),
        ]),
        "end": .object([
          "type": .string("string"),
          "description": .string("ISO8601 end (exclusive)."),
        ]),
        "attachments": .object([
          "type": .string("boolean"),
          "description": .string("Include attachment metadata."),
        ]),
      ]),
      "required": .array([.string("chat_id")]),
      "additionalProperties": .bool(false),
    ]),
    requiresSend: false
  )

  static let watchSubscribe = MCPTool(
    name: "imsg.watch.subscribe",
    description:
      "Subscribe to a live stream of incoming messages. Emits MCP notifications/message events.",
    inputSchema: schemaObject([
      "type": .string("object"),
      "properties": .object([
        "chat_id": .object(["type": .string("integer")]),
        "since_rowid": .object(["type": .string("integer")]),
        "participants": .object([
          "type": .string("array"),
          "items": .object(["type": .string("string")]),
        ]),
        "start": .object(["type": .string("string")]),
        "end": .object(["type": .string("string")]),
        "attachments": .object(["type": .string("boolean")]),
        "include_reactions": .object(["type": .string("boolean")]),
      ]),
      "additionalProperties": .bool(false),
    ]),
    requiresSend: false
  )

  static let watchUnsubscribe = MCPTool(
    name: "imsg.watch.unsubscribe",
    description: "Stop a previously started imsg.watch.subscribe stream.",
    inputSchema: schemaObject([
      "type": .string("object"),
      "properties": .object([
        "subscription_id": .object([
          "type": .string("integer"),
          "description": .string("Subscription id returned by imsg.watch.subscribe."),
        ])
      ]),
      "required": .array([.string("subscription_id")]),
      "additionalProperties": .bool(false),
    ]),
    requiresSend: false
  )

  static let send = MCPTool(
    name: "imsg.send",
    description: "Send a message. Requires imsg mcp --allow-send.",
    inputSchema: schemaObject([
      "type": .string("object"),
      "properties": .object([
        "to": .object(["type": .string("string")]),
        "chat_id": .object(["type": .string("integer")]),
        "chat_identifier": .object(["type": .string("string")]),
        "chat_guid": .object(["type": .string("string")]),
        "text": .object(["type": .string("string")]),
        "file": .object(["type": .string("string")]),
        "service": .object([
          "type": .string("string"),
          "enum": .array([.string("auto"), .string("imessage"), .string("sms")]),
        ]),
        "region": .object(["type": .string("string")]),
      ]),
      "additionalProperties": .bool(false),
    ]),
    requiresSend: true
  )

  static let react = MCPTool(
    name: "imsg.react",
    description:
      "Send a tapback reaction to the most recent incoming message. Requires imsg mcp --allow-send.",
    inputSchema: schemaObject([
      "type": .string("object"),
      "properties": .object([
        "chat_id": .object(["type": .string("integer")]),
        "reaction": .object([
          "type": .string("string"),
          "description": .string(
            "love|like|dislike|laugh|emphasis|question, or a single emoji."),
        ]),
      ]),
      "required": .array([.string("chat_id"), .string("reaction")]),
      "additionalProperties": .bool(false),
    ]),
    requiresSend: true
  )

  // `imsg.search` is advertised in the catalog so clients can discover it, but
  // the handler returns MCP error -32601 (method not found) until W3.D1 ships.
  static let search = MCPTool(
    name: "imsg.search",
    description: "Full-text search across conversations. Not implemented until W3.D1.",
    inputSchema: schemaObject([
      "type": .string("object"),
      "properties": .object([
        "query": .object(["type": .string("string")]),
        "limit": .object(["type": .string("integer")]),
      ]),
      "required": .array([.string("query")]),
      "additionalProperties": .bool(false),
    ]),
    requiresSend: false
  )

  // Helper so the literal entries stay readable.
  private static func schemaObject(_ entries: [String: JSONValue]) -> JSONValue {
    .object(entries)
  }
}

extension MCPTool {
  /// Serialize the tool into the JSON shape expected by MCP `tools/list`.
  func asJSON() -> JSONValue {
    .object([
      "name": .string(name),
      "description": .string(description),
      "inputSchema": inputSchema,
    ])
  }
}

#endif
