import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func mcpToolsListReturnsAllSevenCatalogEntries() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let server = MCPServer(store: store, allowSend: false)

  let line = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
  let response = await server.handleLineForTesting(line)
  #expect(response != nil)

  let data = try MCPFraming.encode(response!)
  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  let result = json?["result"] as? [String: Any]
  let tools = result?["tools"] as? [[String: Any]] ?? []

  let names = tools.compactMap { $0["name"] as? String }
  #expect(names.count == 7)

  let expected: Set<String> = [
    "imsg.chats.list",
    "imsg.history",
    "imsg.watch.subscribe",
    "imsg.watch.unsubscribe",
    "imsg.send",
    "imsg.react",
    "imsg.search",
  ]
  #expect(Set(names) == expected)

  // The catalog's own list should match the emitted names one-for-one.
  let catalogNames = MCPToolCatalog.all.map { $0.name }
  #expect(Set(catalogNames) == expected)

  let byTool = Dictionary(
    uniqueKeysWithValues: tools.compactMap { tool -> (String, [String: Any])? in
      guard let name = tool["name"] as? String else { return nil }
      return (name, tool)
    })
  let historySchema = byTool["imsg.history"]?["inputSchema"] as? [String: Any]
  let historyProperties = historySchema?["properties"] as? [String: Any]
  #expect(historyProperties?["enrich"] != nil)

  let watchSchema = byTool["imsg.watch.subscribe"]?["inputSchema"] as? [String: Any]
  let watchProperties = watchSchema?["properties"] as? [String: Any]
  #expect(watchProperties?["enrich"] != nil)
}

@Test
func mcpToolCatalogFlagsMutatingToolsAsRequiringSend() {
  let byName = Dictionary(
    uniqueKeysWithValues: MCPToolCatalog.all.map { ($0.name, $0) }
  )
  #expect(byName["imsg.send"]?.requiresSend == true)
  #expect(byName["imsg.react"]?.requiresSend == true)
  #expect(byName["imsg.chats.list"]?.requiresSend == false)
  #expect(byName["imsg.history"]?.requiresSend == false)
  #expect(byName["imsg.watch.subscribe"]?.requiresSend == false)
  #expect(byName["imsg.watch.unsubscribe"]?.requiresSend == false)
  #expect(byName["imsg.search"]?.requiresSend == false)
}
