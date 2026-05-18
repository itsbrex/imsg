import Foundation

// MARK: - Supported subset
//
// `TOML` is a hand-rolled parser that covers exactly what the rules engine
// (`docs/rules.md`) needs, with no third-party dependency. The supported
// grammar is intentionally small:
//
//   * Top-level key/value lines, `[table]` headers, and `[[array-of-tables]]`
//     headers. Dotted keys are allowed only in headers (e.g. `[a.b]`), not
//     in assignments. Subsequent redefinition of the same plain `[table]` is
//     rejected.
//   * Bare keys (`[A-Za-z0-9_-]+`) and quoted keys (`"..."`).
//   * Basic strings (`"..."`) with the common escapes `\" \\ \/ \n \t \r`
//     `\b \f` and `\uXXXX`. Multi-line basic strings (`"""..."""`) follow
//     the TOML rule of trimming an immediately-following newline.
//   * Integers (decimal, optional `+`/`-`, optional `_` separators).
//   * Floats (decimal with a fractional part, an exponent, or both).
//   * Booleans (`true` / `false`).
//   * Arrays — `[ v, v, ... ]`, may span lines, trailing comma allowed.
//   * Inline tables — `{ k = v, k2 = v2 }`, single line only.
//   * `#` comments through end-of-line.
//
// Anything outside this subset is a hard error. The parser does not enforce
// "unknown key" rules itself; that responsibility belongs to the caller
// (e.g. the rules schema validator), which inspects the resulting
// `[String: TOMLValue]` tree.

// MARK: - Value model

public indirect enum TOMLValue: Equatable, Sendable {
  case string(String)
  case integer(Int64)
  case float(Double)
  case bool(Bool)
  case array([TOMLValue])
  case table([String: TOMLValue])
}

extension TOMLValue {
  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }
  public var integerValue: Int64? {
    if case .integer(let value) = self { return value }
    return nil
  }
  public var floatValue: Double? {
    if case .float(let value) = self { return value }
    if case .integer(let value) = self { return Double(value) }
    return nil
  }
  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }
  public var arrayValue: [TOMLValue]? {
    if case .array(let value) = self { return value }
    return nil
  }
  public var tableValue: [String: TOMLValue]? {
    if case .table(let value) = self { return value }
    return nil
  }
}

// MARK: - Errors

public struct TOMLError: Error, CustomStringConvertible, Equatable, Sendable {
  public let message: String
  public let line: Int
  public let column: Int

  public init(_ message: String, line: Int, column: Int) {
    self.message = message
    self.line = line
    self.column = column
  }

  public var description: String {
    "TOML error at \(line):\(column): \(message)"
  }
}

// MARK: - Public API

public enum TOML {
  public static func parse(_ source: String) throws -> [String: TOMLValue] {
    var parser = TOMLParser(source: source)
    return try parser.parseDocument()
  }
}
