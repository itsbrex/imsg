import Foundation
import Testing

@testable import IMsgCore

private func makeMessage(
  rowID: Int64,
  chatID: Int64,
  sender: String,
  isFromMe: Bool,
  date: Date,
  isReaction: Bool = false
) -> Message {
  Message(
    rowID: rowID,
    chatID: chatID,
    sender: sender,
    text: isReaction ? "" : "hi",
    date: date,
    isFromMe: isFromMe,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 0,
    guid: "g-\(rowID)",
    isReaction: isReaction
  )
}

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@Test
func graphAggregatesPerContactPerChat() async throws {
  let messages: [Message] = [
    makeMessage(rowID: 1, chatID: 1, sender: "+555a", isFromMe: false, date: t0),
    makeMessage(rowID: 2, chatID: 1, sender: "", isFromMe: true, date: t0.addingTimeInterval(60)),
    makeMessage(rowID: 3, chatID: 1, sender: "+555a", isFromMe: false, date: t0.addingTimeInterval(120)),
    makeMessage(rowID: 4, chatID: 2, sender: "+555b", isFromMe: false, date: t0.addingTimeInterval(180)),
    makeMessage(rowID: 5, chatID: 2, sender: "", isFromMe: true, date: t0.addingTimeInterval(200)),
  ]
  let bridge = InMemoryContactsBridge(records: [
    "+555a": Contact(name: "Alice", handle: "+555a"),
    "+555b": Contact(name: "Bob", handle: "+555b"),
  ])
  let graph = try await GraphBuilder().build(
    messages: messages, chats: [:], bridge: bridge,
    generatedAt: t0.addingTimeInterval(1000)
  )

  // Expect edges: Alice->1 (count=2), Me->1 (1), Bob->2 (1), Me->2 (1).
  let edgeMap = Dictionary(uniqueKeysWithValues: graph.edges.map {
    ("\($0.fromContactId)|\($0.toChatId)", $0)
  })
  #expect(edgeMap["Alice|1"]?.count == 2)
  #expect(edgeMap["Alice|1"]?.inbound == 2)
  #expect(edgeMap["Alice|1"]?.outbound == 0)
  #expect(edgeMap["Me|1"]?.count == 1)
  #expect(edgeMap["Me|1"]?.outbound == 1)
  #expect(edgeMap["Bob|2"]?.count == 1)
  #expect(edgeMap["Me|2"]?.count == 1)

  // Newest message in window is t0 + 200 for Me->2.
  let me2 = edgeMap["Me|2"]
  #expect(me2?.lastAt == t0.addingTimeInterval(200))
}

@Test
func graphSkipsReactionRows() async throws {
  let reaction = makeMessage(
    rowID: 1, chatID: 1, sender: "+555a", isFromMe: false, date: t0, isReaction: true)
  let bridge = NoOpContactsBridge()
  let graph = try await GraphBuilder().build(
    messages: [reaction], chats: [:], bridge: bridge, generatedAt: t0
  )
  #expect(graph.edges.isEmpty)
}

@Test
func graphFallsBackToHandleWhenContactMissing() async throws {
  let message = makeMessage(rowID: 1, chatID: 5, sender: "+1234567890", isFromMe: false, date: t0)
  let graph = try await GraphBuilder().build(
    messages: [message], chats: [:], bridge: NoOpContactsBridge(),
    generatedAt: t0.addingTimeInterval(1)
  )
  #expect(graph.edges.count == 1)
  #expect(graph.edges.first?.fromContactId == "+1234567890")
  let contactNode = graph.nodes.first { $0.kind == "contact" }
  #expect(contactNode?.displayName == "+1234567890")
  #expect(contactNode?.handle == "+1234567890")
}

@Test
func graphEdgesAreOrderedByCountDescending() async throws {
  var messages: [Message] = []
  // contact A: 3 messages in chat 1
  for i in 0..<3 {
    messages.append(makeMessage(
      rowID: Int64(i + 1), chatID: 1, sender: "+a",
      isFromMe: false, date: t0.addingTimeInterval(Double(i))
    ))
  }
  // contact B: 1 message in chat 1
  messages.append(makeMessage(rowID: 10, chatID: 1, sender: "+b", isFromMe: false, date: t0))
  let bridge = InMemoryContactsBridge(records: [
    "+a": Contact(name: "AAA", handle: "+a"),
    "+b": Contact(name: "BBB", handle: "+b"),
  ])
  let graph = try await GraphBuilder().build(
    messages: messages, chats: [:], bridge: bridge, generatedAt: t0
  )
  #expect(graph.edges.first?.fromContactId == "AAA")
  #expect(graph.edges.first?.count == 3)
}

@Test
func jsonExporterProducesSchemaEnvelope() async throws {
  let message = makeMessage(rowID: 1, chatID: 7, sender: "+x", isFromMe: false, date: t0)
  let graph = try await GraphBuilder().build(
    messages: [message], chats: [:],
    bridge: InMemoryContactsBridge(records: ["+x": Contact(name: "Xena", handle: "+x")]),
    window: GraphWindow(since: t0, until: t0.addingTimeInterval(3600)),
    generatedAt: t0.addingTimeInterval(120)
  )
  let data = try GraphExporter.json(graph)
  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  #expect(object?["schema"] as? String == "v1")
  #expect(object?["kind"] as? String == "graph")
  let payload = try #require(object?["data"] as? [String: Any])
  let nodes = try #require(payload["nodes"] as? [[String: Any]])
  #expect(nodes.contains { ($0["display_name"] as? String) == "Xena" })
  let edges = try #require(payload["edges"] as? [[String: Any]])
  #expect(edges.first?["from_contact_id"] as? String == "Xena")
  #expect(edges.first?["to_chat_id"] as? Int == 7)
}

@Test
func dotExporterRendersNodesAndEdges() async throws {
  let message = makeMessage(rowID: 1, chatID: 9, sender: "+y", isFromMe: false, date: t0)
  let graph = try await GraphBuilder().build(
    messages: [message],
    chats: [9: ChatInfo(
      id: 9, identifier: "iMessage;-;9", guid: "iMessage;-;9",
      name: "Lunch", service: "iMessage",
      accountID: nil, accountLogin: nil, lastAddressedHandle: nil)],
    bridge: InMemoryContactsBridge(records: ["+y": Contact(name: "Yves", handle: "+y")]),
    generatedAt: t0
  )
  let dot = GraphExporter.dot(graph)
  #expect(dot.contains("digraph imsg"))
  #expect(dot.contains("\"Yves\""))
  #expect(dot.contains("\"Lunch\""))
  #expect(dot.contains("\"Yves\" -> \"chat:9\""))
}
