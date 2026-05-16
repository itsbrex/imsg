#if os(macOS)
import Foundation

// Minimal JSON value type used to pass through arbitrary JSON in JSON-RPC 2.0
// params / results / ids without losing precision for numeric `id` values.
// Matches the framing style used by `RPCServer.swift:51-77` (one JSON object
// per line, tolerant of notifications that omit `id`).
enum JSONValue: Codable, Sendable, Equatable {
  case string(String)
  case int(Int64)
  case double(Double)
  case bool(Bool)
  case array([JSONValue])
  case object([String: JSONValue])
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
      return
    }
    if let value = try? container.decode(Bool.self) {
      self = .bool(value)
      return
    }
    if let value = try? container.decode(Int64.self) {
      self = .int(value)
      return
    }
    if let value = try? container.decode(Double.self) {
      self = .double(value)
      return
    }
    if let value = try? container.decode(String.self) {
      self = .string(value)
      return
    }
    if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
      return
    }
    if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
      return
    }
    throw DecodingError.dataCorruptedError(
      in: container,
      debugDescription: "Unsupported JSON value"
    )
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .int(let value):
      try container.encode(value)
    case .double(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }

  // Convenience accessors.
  var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  var intValue: Int? {
    switch self {
    case .int(let value): return Int(value)
    case .double(let value): return Int(value)
    default: return nil
    }
  }

  var int64Value: Int64? {
    switch self {
    case .int(let value): return value
    case .double(let value): return Int64(value)
    default: return nil
    }
  }

  var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  var arrayValue: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  var objectValue: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  func field(_ key: String) -> JSONValue? {
    guard case .object(let obj) = self else { return nil }
    return obj[key]
  }
}

/// JSON-RPC 2.0 request over MCP stdio framing.
struct MCPRequest: Decodable, Sendable {
  let jsonrpc: String
  let id: JSONValue?
  let method: String
  let params: JSONValue?
}

/// JSON-RPC 2.0 error object.
struct MCPErrorObject: Encodable, Sendable {
  let code: Int
  let message: String
  let data: JSONValue?

  init(code: Int, message: String, data: JSONValue? = nil) {
    self.code = code
    self.message = message
    self.data = data
  }
}

/// JSON-RPC 2.0 response. Either `result` or `error` is non-nil, never both.
struct MCPResponse: Encodable, Sendable {
  let jsonrpc: String
  let id: JSONValue?
  let result: JSONValue?
  let error: MCPErrorObject?

  init(id: JSONValue?, result: JSONValue) {
    self.jsonrpc = "2.0"
    self.id = id ?? .null
    self.result = result
    self.error = nil
  }

  init(id: JSONValue?, error: MCPErrorObject) {
    self.jsonrpc = "2.0"
    self.id = id ?? .null
    self.result = nil
    self.error = error
  }

  private enum CodingKeys: String, CodingKey {
    case jsonrpc, id, result, error
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(jsonrpc, forKey: .jsonrpc)
    try container.encode(id, forKey: .id)
    if let result {
      try container.encode(result, forKey: .result)
    }
    if let error {
      try container.encode(error, forKey: .error)
    }
  }
}

/// JSON-RPC 2.0 notification (no `id`).
struct MCPNotification: Encodable, Sendable {
  let jsonrpc: String
  let method: String
  let params: JSONValue?

  init(method: String, params: JSONValue?) {
    self.jsonrpc = "2.0"
    self.method = method
    self.params = params
  }
}

/// Line-delimited JSON-RPC framing over stdin/stdout.
///
/// Mirrors the loop in `RPCServer.run()` (`Sources/imsg/RPCServer.swift:33-40`)
/// which reads one JSON object per line and dispatches to handlers, but uses
/// strongly-typed `Codable` values instead of `JSONSerialization`.
enum MCPFraming {
  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    return decoder
  }()

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return encoder
  }()

  /// Decode a single JSON-RPC request line. Returns nil on empty input.
  static func decodeRequest(_ line: String) throws -> MCPRequest? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    guard let data = trimmed.data(using: .utf8) else { return nil }
    return try decoder.decode(MCPRequest.self, from: data)
  }

  /// Encode a response as a single line of JSON and write to stdout via
  /// `JSONLines.print(_:)` (`Sources/imsg/JSONLines.swift:15-20`).
  static func write(response: MCPResponse) throws {
    try JSONLines.print(response)
  }

  /// Encode a notification as a single line of JSON and write to stdout.
  static func write(notification: MCPNotification) throws {
    try JSONLines.print(notification)
  }

  /// Encoder exposed for ad-hoc JSON value encoding by handlers.
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    try encoder.encode(value)
  }
}

#endif
