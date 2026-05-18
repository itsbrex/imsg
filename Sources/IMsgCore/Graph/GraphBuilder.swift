import Foundation

public struct GraphBuilder {
  public init() {}

  /// Build an aggregated interaction graph from a flat list of messages.
  ///
  /// - Parameters:
  ///   - messages: rows to consider (caller filters by chat / time as
  ///     needed; reactions are dropped automatically).
  ///   - chats: chat metadata keyed by `chat_id`; used for chat-node
  ///     display names. Missing entries fall back to `"chat <id>"`.
  ///   - bridge: contacts resolver. The bridge is consulted once per
  ///     unique inbound handle; the cache layer keeps this cheap.
  ///   - window: optional `since`/`until` for stamping into the output.
  ///   - generatedAt: clock for the report header.
  public func build(
    messages: [Message],
    chats: [Int64: ChatInfo],
    bridge: any ContactsBridge,
    window: GraphWindow = GraphWindow(),
    generatedAt: Date = Date()
  ) async throws -> InteractionGraph {
    // 1. Resolve unique inbound handles to display names.
    let inboundHandles: Set<String> = Set(
      messages
        .filter { !$0.isReaction && !$0.isFromMe && !$0.sender.isEmpty }
        .map { $0.sender })
    var resolved: [String: Contact] = [:]
    for handle in inboundHandles {
      if let record = try await bridge.find(handle: handle) {
        resolved[handle] = record
      }
    }

    // 2. Aggregate per-(contact, chat) edge.
    var edges: [EdgeKey: Aggregate] = [:]
    var contactDisplayNames: [String: (display: String, handle: String?)] = [:]
    var chatIDs: Set<Int64> = []

    for message in messages where !message.isReaction {
      chatIDs.insert(message.chatID)

      let contactId: String
      let displayName: String
      let handle: String?
      if message.isFromMe {
        contactId = "Me"
        displayName = "Me"
        handle = nil
      } else if message.sender.isEmpty {
        continue
      } else {
        if let record = resolved[message.sender] {
          contactId = record.name
          displayName = record.name
        } else {
          contactId = message.sender
          displayName = message.sender
        }
        handle = message.sender
      }

      contactDisplayNames[contactId] = (displayName, handle)

      let key = EdgeKey(contact: contactId, chat: message.chatID)
      var agg = edges[key] ?? Aggregate(displayName: displayName, handle: handle)
      agg.count += 1
      if message.isFromMe { agg.outbound += 1 } else { agg.inbound += 1 }
      if message.date > agg.lastAt { agg.lastAt = message.date }
      agg.displayName = displayName
      agg.handle = handle
      edges[key] = agg
    }

    // 3. Build node + edge lists in a stable order.
    var nodes: [GraphNode] = []
    for (id, info) in contactDisplayNames.sorted(by: { $0.key < $1.key }) {
      nodes.append(
        GraphNode(
          id: id, kind: "contact",
          displayName: info.display, handle: info.handle, chatId: nil
        )
      )
    }
    for chatId in chatIDs.sorted() {
      let name = chats[chatId]?.name ?? "chat \(chatId)"
      nodes.append(
        GraphNode(
          id: "chat:\(chatId)", kind: "chat",
          displayName: name.isEmpty ? "chat \(chatId)" : name,
          handle: nil, chatId: chatId
        )
      )
    }

    let sortedEdges: [GraphEdge] =
      edges
      .sorted(by: edgeOrder)
      .map { (key, agg) in
        GraphEdge(
          fromContactId: key.contact,
          toChatId: key.chat,
          count: agg.count,
          inbound: agg.inbound,
          outbound: agg.outbound,
          lastAt: agg.lastAt
        )
      }

    return InteractionGraph(
      generatedAt: generatedAt,
      window: window,
      nodes: nodes,
      edges: sortedEdges
    )
  }

  private func edgeOrder(
    _ lhs: (key: EdgeKey, value: Aggregate),
    _ rhs: (key: EdgeKey, value: Aggregate)
  ) -> Bool {
    if lhs.value.count != rhs.value.count {
      return lhs.value.count > rhs.value.count
    }
    if lhs.key.contact != rhs.key.contact {
      return lhs.key.contact < rhs.key.contact
    }
    return lhs.key.chat < rhs.key.chat
  }
}

private struct EdgeKey: Hashable {
  let contact: String
  let chat: Int64
}
private struct Aggregate {
  var count: Int = 0
  var inbound: Int = 0
  var outbound: Int = 0
  var lastAt: Date = .distantPast
  var displayName: String = ""
  var handle: String? = nil
}
