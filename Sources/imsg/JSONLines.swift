import Foundation
import IMsgCore

enum JSONLines {
  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return encoder
  }()

  static func encode<T: Encodable>(_ value: T) throws -> String {
    let data = try encoder.encode(value)
    return String(data: data, encoding: .utf8) ?? ""
  }

  static func encode<T: Encodable>(_ envelope: EnvelopePayload<T>) throws -> String {
    let schema = try encode(envelope.schema)
    let kind = try encode(envelope.kind)
    let payload = try encode(envelope.data)
    return #"{"schema":\#(schema),"kind":\#(kind),"data":\#(payload)}"#
  }

  static func print<T: Encodable>(_ value: T) throws {
    let line = try encode(value)
    if !line.isEmpty {
      StdoutWriter.writeLine(line)
    }
  }

  static func printEnvelope<T: Encodable>(kind: String, data: T) throws {
    let envelope = EnvelopePayload(kind: kind, data: data)
    let line = try encode(envelope)
    if !line.isEmpty {
      StdoutWriter.writeLine(line)
    }
  }

  static func printObject(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [])
    guard let line = String(data: data, encoding: .utf8), !line.isEmpty else { return }
    StdoutWriter.writeLine(line)
  }
}
