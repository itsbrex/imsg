import Foundation
import IMsgCore

/// Stdio loop for imsg's MCP (Model Context Protocol) server.
///
/// Reads line-delimited JSON-RPC 2.0 requests from `FileHandle.standardInput`
/// and writes responses / notifications through `MCPFraming`, which ultimately
/// goes through `JSONLines.print(_:)` (`Sources/imsg/JSONLines.swift:15-20`).
///
/// The loop mirrors the shape of `RPCServer.run()`
/// (`Sources/imsg/RPCServer.swift:33-40`) but dispatches the MCP
/// protocol methods instead of the imsg RPC methods.
actor MCPServer {
  let allowSend: Bool
  let handlers: MCPHandlers
  private var initialized = false

  init(
    store: MessageStore,
    allowSend: Bool,
    sendInvoker: SendInvoker = DefaultSendInvoker()
  ) {
    self.allowSend = allowSend
    self.handlers = MCPHandlers(
      store: store,
      allowSend: allowSend,
      sendInvoker: sendInvoker
    )
  }

  /// Run the stdio loop until stdin is closed.
  func run() async throws {
    while let line = readLine() {
      await handle(line: line)
    }
    await handlers.cancelAllSubscriptions()
  }

  /// Dispatch a single line for test harnesses. Returns the response (if any)
  /// so tests can assert without capturing stdout.
  func handleLineForTesting(_ line: String) async -> MCPResponse? {
    return await handleAndReturn(line: line)
  }

  private func handle(line: String) async {
    guard let response = await handleAndReturn(line: line) else { return }
    try? MCPFraming.write(response: response)
  }

  private func handleAndReturn(line: String) async -> MCPResponse? {
    let request: MCPRequest?
    do {
      request = try MCPFraming.decodeRequest(line)
    } catch {
      return MCPResponse(
        id: nil,
        error: MCPErrorObject(
          code: MCPErrorCode.parseError,
          message: "Parse error",
          data: .string(error.localizedDescription)
        )
      )
    }
    guard let request else { return nil }

    if request.jsonrpc != "2.0" {
      return MCPResponse(
        id: request.id,
        error: MCPErrorObject(
          code: MCPErrorCode.invalidRequest,
          message: "jsonrpc must be 2.0"
        )
      )
    }

    return await dispatch(request: request)
  }

  private func dispatch(request: MCPRequest) async -> MCPResponse? {
    switch request.method {
    case "initialize":
      return handleInitialize(request: request)
    case "initialized", "notifications/initialized":
      // Client notification that initialization is complete. No response.
      initialized = true
      return nil
    case "tools/list":
      return handleToolsList(request: request)
    case "tools/call":
      return await handleToolsCall(request: request)
    case "resources/list":
      return handleResourcesList(request: request)
    case "ping":
      return MCPResponse(id: request.id, result: .object([:]))
    default:
      if request.method.hasPrefix("notifications/") {
        // Pass-through for other client notifications — no response.
        return nil
      }
      return MCPResponse(
        id: request.id,
        error: MCPErrorObject(
          code: MCPErrorCode.methodNotFound,
          message: "Method not found",
          data: .string(request.method)
        )
      )
    }
  }

  // MARK: - Handshake

  private func handleInitialize(request: MCPRequest) -> MCPResponse {
    let result = JSONValue.object([
      "protocolVersion": .string("2024-11-05"),
      "capabilities": .object([
        "tools": .object([:]),
        "resources": .object([:]),
        "logging": .object([:]),
      ]),
      "serverInfo": .object([
        "name": .string("imsg"),
        // `IMsgVersion.current` is declared at `Sources/imsg/Version.swift:3`.
        "version": .string(IMsgVersion.current),
      ]),
      // Single-sourced from `Sources/IMsgCore/SchemaVersion.swift:4`.
      "schema": .string(IMsgSchema.currentVersion),
    ])
    return MCPResponse(id: request.id, result: result)
  }

  private func handleToolsList(request: MCPRequest) -> MCPResponse {
    let tools = MCPToolCatalog.all.map { $0.asJSON() }
    return MCPResponse(
      id: request.id,
      result: .object(["tools": .array(tools)])
    )
  }

  private func handleResourcesList(request: MCPRequest) -> MCPResponse {
    return MCPResponse(
      id: request.id,
      result: .object(["resources": .array([])])
    )
  }

  private func handleToolsCall(request: MCPRequest) async -> MCPResponse {
    guard let params = request.params else {
      return MCPResponse(
        id: request.id,
        error: MCPErrorObject(
          code: MCPErrorCode.invalidParams,
          message: "params required"
        )
      )
    }
    guard let name = params.field("name")?.stringValue else {
      return MCPResponse(
        id: request.id,
        error: MCPErrorObject(
          code: MCPErrorCode.invalidParams,
          message: "name required"
        )
      )
    }
    let arguments = params.field("arguments")
    do {
      let payload = try await handlers.call(name: name, arguments: arguments)
      // Wrap tool return value in the MCP tools/call result envelope.
      // `content` carries the text representation; `structuredContent`
      // preserves the typed JSON payload for clients that prefer it.
      let encoded = try MCPFraming.encode(payload)
      let text = String(data: encoded, encoding: .utf8) ?? "{}"
      let result = JSONValue.object([
        "content": .array([
          .object([
            "type": .string("text"),
            "text": .string(text),
          ])
        ]),
        "structuredContent": payload,
        "isError": .bool(false),
      ])
      return MCPResponse(id: request.id, result: result)
    } catch let err as MCPToolError {
      return MCPResponse(id: request.id, error: err.asErrorObject)
    } catch let err as IMsgError {
      return MCPResponse(
        id: request.id,
        error: MCPErrorObject(
          code: MCPErrorCode.internalError,
          message: err.localizedDescription
        )
      )
    } catch {
      return MCPResponse(
        id: request.id,
        error: MCPErrorObject(
          code: MCPErrorCode.internalError,
          message: error.localizedDescription
        )
      )
    }
  }
}
