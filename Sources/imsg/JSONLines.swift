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

  static func print<T: Encodable>(_ value: T) throws {
    let line = try encode(value)
    if !line.isEmpty {
      StdoutWriter.writeLine(line)
    }
  }

  static func printEnvelope<T: Encodable>(kind: String, data: T) throws {
    let envelope = EnvelopePayload(kind: kind, data: data)
    try print(envelope)
  }
}
