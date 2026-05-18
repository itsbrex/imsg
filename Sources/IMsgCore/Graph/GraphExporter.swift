import Foundation

public enum GraphExporter {
  /// Serialize a graph into the envelope-wrapped JSON shape documented
  /// in `docs/contacts.md`. Keys are sorted at every depth so two runs
  /// over the same input bytes match byte-for-byte.
  public static func json(_ graph: InteractionGraph) throws -> Data {
    let payload: [String: Any] = [
      "schema": "v1",
      "kind": "graph",
      "data": payload(for: graph),
    ]
    var data = try JSONSerialization.data(
      withJSONObject: payload,
      options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    )
    data.append(0x0A)
    return data
  }

  /// Render the graph as a Graphviz DOT digraph. Contacts and chats are
  /// emitted as separate node sets; edges carry the message count as a
  /// label. Output is stable and reproducible.
  public static func dot(_ graph: InteractionGraph) -> String {
    var lines: [String] = ["digraph imsg {"]
    lines.append("  rankdir=LR;")
    for node in graph.nodes where node.kind == "contact" {
      lines.append("  \"\(escape(node.id))\" [shape=ellipse,label=\"\(escape(node.displayName))\"];")
    }
    for node in graph.nodes where node.kind == "chat" {
      lines.append(
        "  \"chat:\(node.chatId ?? 0)\" [shape=box,label=\"\(escape(node.displayName))\"];"
      )
    }
    for edge in graph.edges {
      lines.append(
        "  \"\(escape(edge.fromContactId))\" -> \"chat:\(edge.toChatId)\" "
          + "[label=\"\(edge.count)\"];"
      )
    }
    lines.append("}")
    return lines.joined(separator: "\n") + "\n"
  }

  // MARK: - Helpers

  private static func payload(for graph: InteractionGraph) -> [String: Any] {
    let dateFormatter: ISO8601DateFormatter = {
      let f = ISO8601DateFormatter()
      f.formatOptions = [.withInternetDateTime]
      return f
    }()

    let windowObject: [String: Any] = [
      "since": graph.window.since.map(dateFormatter.string(from:)) as Any? ?? NSNull(),
      "until": graph.window.until.map(dateFormatter.string(from:)) as Any? ?? NSNull(),
    ]
    let nodes = graph.nodes.map { node -> [String: Any] in
      var entry: [String: Any] = [
        "id": node.id,
        "kind": node.kind,
        "display_name": node.displayName,
      ]
      if let handle = node.handle { entry["handle"] = handle }
      if let chatId = node.chatId { entry["chat_id"] = chatId }
      return entry
    }
    let edges = graph.edges.map { edge -> [String: Any] in
      return [
        "from_contact_id": edge.fromContactId,
        "to_chat_id": edge.toChatId,
        "count": edge.count,
        "inbound": edge.inbound,
        "outbound": edge.outbound,
        "last_at": dateFormatter.string(from: edge.lastAt),
      ]
    }
    return [
      "generated_at": dateFormatter.string(from: graph.generatedAt),
      "window": windowObject,
      "nodes": nodes,
      "edges": edges,
    ]
  }

  private static func escape(_ string: String) -> String {
    string.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }
}
