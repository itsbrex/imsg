import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func mcpInitializeReturnsServerInfoAndSchema() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let server = MCPServer(store: store, allowSend: false)

  let request = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
  let response = await server.handleLineForTesting(request)
  #expect(response != nil)

  let data = try MCPFraming.encode(response!)
  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  #expect(json?["jsonrpc"] as? String == "2.0")

  let result = json?["result"] as? [String: Any]
  #expect(result != nil)
  #expect(result?["schema"] as? String == "v1")
  #expect(result?["protocolVersion"] as? String == "2024-11-05")

  let serverInfo = result?["serverInfo"] as? [String: Any]
  #expect(serverInfo?["name"] as? String == "imsg")
  #expect((serverInfo?["version"] as? String)?.isEmpty == false)

  let capabilities = result?["capabilities"] as? [String: Any]
  #expect(capabilities?["tools"] != nil)
  #expect(capabilities?["resources"] != nil)
  #expect(capabilities?["logging"] != nil)
}

@Test
func mcpInitializedNotificationYieldsNoResponse() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let server = MCPServer(store: store, allowSend: false)

  // Client -> server notification has no `id`.
  let line = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
  let response = await server.handleLineForTesting(line)
  #expect(response == nil)
}

@Test
func mcpInvalidJSONRPCVersionReturnsInvalidRequest() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let server = MCPServer(store: store, allowSend: false)

  let line = #"{"jsonrpc":"1.0","id":1,"method":"initialize"}"#
  let response = await server.handleLineForTesting(line)
  let data = try MCPFraming.encode(response!)
  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  let error = json?["error"] as? [String: Any]
  #expect((error?["code"] as? Int) == -32600)
}
