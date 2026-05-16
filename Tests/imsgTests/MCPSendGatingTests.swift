import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

final class FakeSendInvoker: SendInvoker, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var sendCallCount = 0
  private(set) var lastOptions: MessageSendOptions?
  private(set) var reactionCallCount = 0
  private(set) var lastReactionChatID: Int64?
  private(set) var lastReactionValue: String?

  func sendMessage(_ options: MessageSendOptions) throws {
    lock.lock()
    defer { lock.unlock() }
    sendCallCount += 1
    lastOptions = options
  }

  func sendReaction(chatID: Int64, reaction: String, store: MessageStore) async throws {
    recordReaction(chatID: chatID, reaction: reaction)
  }

  private func recordReaction(chatID: Int64, reaction: String) {
    lock.lock()
    defer { lock.unlock() }
    reactionCallCount += 1
    lastReactionChatID = chatID
    lastReactionValue = reaction
  }
}

@Test
func mcpSendBlockedWhenAllowSendOff() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let fake = FakeSendInvoker()
  let server = MCPServer(store: store, allowSend: false, sendInvoker: fake)

  let line =
    #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"imsg.send","arguments":{"chat_id":1,"text":"hi"}}}"#
  let response = await server.handleLineForTesting(line)
  #expect(response != nil)

  let data = try MCPFraming.encode(response!)
  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  let error = json?["error"] as? [String: Any]
  #expect((error?["code"] as? Int) == -32001)
  let message = error?["message"] as? String ?? ""
  #expect(message.contains("send disabled"))
  #expect(message.contains("--allow-send"))
  #expect(fake.sendCallCount == 0)
}

@Test
func mcpSendDispatchesWhenAllowSendOn() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let fake = FakeSendInvoker()
  let server = MCPServer(store: store, allowSend: true, sendInvoker: fake)

  let line =
    #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"imsg.send","arguments":{"chat_id":1,"text":"hi"}}}"#
  let response = await server.handleLineForTesting(line)
  #expect(response != nil)

  let data = try MCPFraming.encode(response!)
  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  #expect(json?["error"] == nil)
  let result = json?["result"] as? [String: Any]
  #expect(result != nil)
  #expect(fake.sendCallCount == 1)
  #expect(fake.lastOptions?.text == "hi")
  #expect(fake.lastOptions?.chatIdentifier == "iMessage;+;chat123")
}

@Test
func mcpReactBlockedWhenAllowSendOff() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let fake = FakeSendInvoker()
  let server = MCPServer(store: store, allowSend: false, sendInvoker: fake)

  let line =
    #"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"imsg.react","arguments":{"chat_id":1,"reaction":"like"}}}"#
  let response = await server.handleLineForTesting(line)
  #expect(response != nil)

  let data = try MCPFraming.encode(response!)
  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  let error = json?["error"] as? [String: Any]
  #expect((error?["code"] as? Int) == -32001)
  #expect(fake.reactionCallCount == 0)
}

@Test
func mcpReactDispatchesWhenAllowSendOn() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let fake = FakeSendInvoker()
  let server = MCPServer(store: store, allowSend: true, sendInvoker: fake)

  let line =
    #"{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"imsg.react","arguments":{"chat_id":1,"reaction":"like"}}}"#
  let response = await server.handleLineForTesting(line)
  #expect(response != nil)

  let data = try MCPFraming.encode(response!)
  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  #expect(json?["error"] == nil)
  #expect(fake.reactionCallCount == 1)
  #expect(fake.lastReactionChatID == 1)
  #expect(fake.lastReactionValue == "like")
}

@Test
func mcpSearchReturnsMethodNotFoundUntilW3D1() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let server = MCPServer(store: store, allowSend: false)

  let line =
    #"{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"imsg.search","arguments":{"query":"hi"}}}"#
  let response = await server.handleLineForTesting(line)
  let data = try MCPFraming.encode(response!)
  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  let error = json?["error"] as? [String: Any]
  #expect((error?["code"] as? Int) == -32601)
  let message = error?["message"] as? String ?? ""
  #expect(message.contains("W3.D1"))
}
