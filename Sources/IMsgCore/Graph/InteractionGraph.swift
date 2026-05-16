import Foundation

// MARK: - Graph types
//
// The interaction graph aggregates `MessageStore` rows into per-(contact,
// chat) edges over a time window. W4.W ships the basic shape from
// `docs/contacts.md`:
//
//   * Nodes split into `contact` and `chat` kinds.
//   * Edges are directed from contact to chat (a contact participated in
//     that chat) and carry total count, inbound vs outbound message
//     counts, and the newest message timestamp inside the window.
//   * `contact_id` is the canonical handle as it appears on the message
//     row (i.e. what `Message.sender` returns) for "fallback" contacts,
//     or the resolved display name when the `ContactsBridge` produces a
//     match. The full `sha256(...)` id-synthesis pipeline from the spec
//     is deferred — the simpler scheme is sufficient for the graph
//     command's edge-aggregation use case and stays stable across runs
//     because the inputs are stable.

public struct GraphWindow: Equatable, Sendable {
  public let since: Date?
  public let until: Date?

  public init(since: Date? = nil, until: Date? = nil) {
    self.since = since
    self.until = until
  }
}

public struct GraphNode: Equatable, Sendable {
  public let id: String
  public let kind: String  // "contact" | "chat"
  public let displayName: String
  public let handle: String?
  public let chatId: Int64?

  public init(
    id: String, kind: String, displayName: String,
    handle: String? = nil, chatId: Int64? = nil
  ) {
    self.id = id
    self.kind = kind
    self.displayName = displayName
    self.handle = handle
    self.chatId = chatId
  }
}

public struct GraphEdge: Equatable, Sendable {
  public let fromContactId: String
  public let toChatId: Int64
  public let count: Int
  public let inbound: Int
  public let outbound: Int
  public let lastAt: Date

  public init(
    fromContactId: String, toChatId: Int64,
    count: Int, inbound: Int, outbound: Int, lastAt: Date
  ) {
    self.fromContactId = fromContactId
    self.toChatId = toChatId
    self.count = count
    self.inbound = inbound
    self.outbound = outbound
    self.lastAt = lastAt
  }
}

public struct InteractionGraph: Equatable, Sendable {
  public let generatedAt: Date
  public let window: GraphWindow
  public let nodes: [GraphNode]
  public let edges: [GraphEdge]

  public init(
    generatedAt: Date,
    window: GraphWindow,
    nodes: [GraphNode],
    edges: [GraphEdge]
  ) {
    self.generatedAt = generatedAt
    self.window = window
    self.nodes = nodes
    self.edges = edges
  }
}
