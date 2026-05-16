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

public extension TOMLValue {
  var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }
  var integerValue: Int64? {
    if case .integer(let value) = self { return value }
    return nil
  }
  var floatValue: Double? {
    if case .float(let value) = self { return value }
    if case .integer(let value) = self { return Double(value) }
    return nil
  }
  var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }
  var arrayValue: [TOMLValue]? {
    if case .array(let value) = self { return value }
    return nil
  }
  var tableValue: [String: TOMLValue]? {
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

// MARK: - Parser

private struct TOMLParser {
  private let scalars: [Unicode.Scalar]
  private var index: Int = 0
  private var line: Int = 1
  private var column: Int = 1

  init(source: String) {
    self.scalars = Array(source.unicodeScalars)
  }

  // MARK: Cursor

  private var isEOF: Bool { index >= scalars.count }

  private func peek(offset: Int = 0) -> Unicode.Scalar? {
    let i = index + offset
    return i < scalars.count ? scalars[i] : nil
  }

  @discardableResult
  private mutating func advance() -> Unicode.Scalar? {
    guard index < scalars.count else { return nil }
    let scalar = scalars[index]
    index += 1
    if scalar == "\n" {
      line += 1
      column = 1
    } else {
      column += 1
    }
    return scalar
  }

  private func error(_ message: String) -> TOMLError {
    TOMLError(message, line: line, column: column)
  }

  // MARK: Whitespace + comments

  private mutating func skipInlineWhitespace() {
    while let c = peek(), c == " " || c == "\t" {
      advance()
    }
  }

  /// Skip whitespace, comments, and (optionally) newlines.
  private mutating func skip(allowNewlines: Bool) {
    while let c = peek() {
      if c == " " || c == "\t" {
        advance()
      } else if c == "\r" || c == "\n" {
        if allowNewlines {
          advance()
        } else {
          return
        }
      } else if c == "#" {
        while let cc = peek(), cc != "\n" { advance() }
      } else {
        return
      }
    }
  }

  // MARK: Document

  mutating func parseDocument() throws -> [String: TOMLValue] {
    var root: [String: TOMLValue] = [:]
    // currentPath is the dotted path of the active `[table]` or
    // `[[array-of-tables]]` header.
    var currentPath: [String] = []
    var currentIsArray = false
    // Track which plain `[table]` headers we've already opened so we can
    // reject duplicate definitions.
    var seenTableHeaders: Set<String> = []

    while true {
      skip(allowNewlines: true)
      if isEOF { break }

      // Header?
      if peek() == "[" {
        let isArrayHeader = peek(offset: 1) == "["
        if isArrayHeader { advance(); advance() } else { advance() }
        skipInlineWhitespace()
        let path = try parseHeaderKey()
        skipInlineWhitespace()
        try expect("]")
        if isArrayHeader { try expect("]") }
        skipInlineWhitespace()
        try expectEndOfLine()

        currentPath = path
        currentIsArray = isArrayHeader

        if isArrayHeader {
          appendArrayOfTablesSlot(in: &root, path: path)
        } else {
          let key = path.joined(separator: ".")
          if !seenTableHeaders.insert(key).inserted {
            throw error("duplicate table header [\(key)]")
          }
          try createTableSlot(in: &root, path: path)
        }
        continue
      }

      // Key / value
      let key = try parseKey()
      skipInlineWhitespace()
      try expect("=")
      skipInlineWhitespace()
      let value = try parseValue()
      skipInlineWhitespace()
      try expectEndOfLine()

      if currentPath.isEmpty {
        if root[key] != nil {
          throw error("duplicate key \"\(key)\" at top level")
        }
        root[key] = value
      } else if currentIsArray {
        try insertIntoLastArrayTable(in: &root, path: currentPath, key: key, value: value)
      } else {
        try insertIntoTable(in: &root, path: currentPath, key: key, value: value)
      }
    }

    return root
  }

  // MARK: Header / key parsing

  private mutating func parseHeaderKey() throws -> [String] {
    var parts: [String] = []
    parts.append(try parseKey())
    while true {
      skipInlineWhitespace()
      if peek() == "." {
        advance()
        skipInlineWhitespace()
        parts.append(try parseKey())
      } else {
        break
      }
    }
    return parts
  }

  private mutating func parseKey() throws -> String {
    if peek() == "\"" {
      return try parseBasicString(allowMultiline: false)
    }
    var key = ""
    while let c = peek(), isBareKeyScalar(c) {
      key.append(Character(c))
      advance()
    }
    if key.isEmpty {
      throw error("expected key")
    }
    return key
  }

  private func isBareKeyScalar(_ c: Unicode.Scalar) -> Bool {
    if c >= "A" && c <= "Z" { return true }
    if c >= "a" && c <= "z" { return true }
    if c >= "0" && c <= "9" { return true }
    return c == "_" || c == "-"
  }

  // MARK: Values

  private mutating func parseValue() throws -> TOMLValue {
    guard let c = peek() else { throw error("expected value, found end of input") }
    switch c {
    case "\"":
      let multi = peek(offset: 1) == "\"" && peek(offset: 2) == "\""
      let str = try parseBasicString(allowMultiline: multi)
      return .string(str)
    case "[":
      return try parseArray()
    case "{":
      return try parseInlineTable()
    case "t", "f":
      return try parseBool()
    case "+", "-":
      return try parseNumber()
    case "0"..."9":
      return try parseNumber()
    default:
      throw error("unexpected character '\(Character(c))' while parsing value")
    }
  }

  private mutating func parseBool() throws -> TOMLValue {
    if matchKeyword("true") { return .bool(true) }
    if matchKeyword("false") { return .bool(false) }
    throw error("expected boolean")
  }

  private mutating func matchKeyword(_ keyword: String) -> Bool {
    let keyScalars = Array(keyword.unicodeScalars)
    guard index + keyScalars.count <= scalars.count else { return false }
    for (i, ks) in keyScalars.enumerated() where scalars[index + i] != ks {
      return false
    }
    // Make sure the keyword isn't a prefix of an identifier.
    if let next = peek(offset: keyScalars.count), isBareKeyScalar(next) {
      return false
    }
    for _ in 0..<keyScalars.count { advance() }
    return true
  }

  private mutating func parseNumber() throws -> TOMLValue {
    let startLine = line
    let startCol = column

    var text = ""
    if let c = peek(), c == "+" || c == "-" {
      text.append(Character(c))
      advance()
    }
    var sawDigit = false
    while let c = peek() {
      if (c >= "0" && c <= "9") || c == "_" {
        if c != "_" { sawDigit = true; text.append(Character(c)) }
        advance()
      } else {
        break
      }
    }

    var isFloat = false
    if peek() == "." {
      isFloat = true
      text.append(".")
      advance()
      while let c = peek(), (c >= "0" && c <= "9") || c == "_" {
        if c != "_" { text.append(Character(c)) }
        advance()
      }
    }
    if let c = peek(), c == "e" || c == "E" {
      isFloat = true
      text.append("e")
      advance()
      if let s = peek(), s == "+" || s == "-" {
        text.append(Character(s))
        advance()
      }
      while let cc = peek(), (cc >= "0" && cc <= "9") || cc == "_" {
        if cc != "_" { text.append(Character(cc)) }
        advance()
      }
    }

    guard sawDigit else {
      throw TOMLError("invalid number", line: startLine, column: startCol)
    }

    if isFloat {
      guard let value = Double(text) else {
        throw TOMLError("invalid float \"\(text)\"", line: startLine, column: startCol)
      }
      return .float(value)
    } else {
      guard let value = Int64(text) else {
        throw TOMLError("invalid integer \"\(text)\"", line: startLine, column: startCol)
      }
      return .integer(value)
    }
  }

  // MARK: Strings

  private mutating func parseBasicString(allowMultiline: Bool) throws -> String {
    try expect("\"")
    if allowMultiline {
      try expect("\"")
      try expect("\"")
      // TOML: a newline immediately after the opening `"""` is trimmed.
      if peek() == "\r" { advance() }
      if peek() == "\n" { advance() }
      return try parseStringBody(multiline: true)
    } else {
      return try parseStringBody(multiline: false)
    }
  }

  private mutating func parseStringBody(multiline: Bool) throws -> String {
    var result = ""
    while true {
      guard let c = peek() else {
        throw error("unterminated string")
      }
      if c == "\"" {
        if multiline {
          if peek(offset: 1) == "\"" && peek(offset: 2) == "\"" {
            advance(); advance(); advance()
            // Allow up to two additional trailing quotes to be folded into
            // the string content per the TOML spec.
            if peek() == "\"" {
              result.append("\"")
              advance()
              if peek() == "\"" {
                result.append("\"")
                advance()
              }
            }
            return result
          } else {
            result.append("\"")
            advance()
            continue
          }
        } else {
          advance()
          return result
        }
      }
      if c == "\n" && !multiline {
        throw error("unterminated single-line string")
      }
      if c == "\\" {
        advance()
        guard let esc = peek() else { throw error("dangling escape at end of string") }
        switch esc {
        case "\"": result.append("\""); advance()
        case "\\": result.append("\\"); advance()
        case "/": result.append("/"); advance()
        case "b": result.append("\u{08}"); advance()
        case "f": result.append("\u{0C}"); advance()
        case "n": result.append("\n"); advance()
        case "r": result.append("\r"); advance()
        case "t": result.append("\t"); advance()
        case "u":
          advance()
          result.unicodeScalars.append(try parseUnicodeEscape(length: 4))
        case "U":
          advance()
          result.unicodeScalars.append(try parseUnicodeEscape(length: 8))
        case "\n", "\r":
          if multiline {
            // Line-ending backslash: consume whitespace through the next
            // non-whitespace character.
            advance()
            while let cc = peek(), cc == " " || cc == "\t" || cc == "\n" || cc == "\r" {
              advance()
            }
          } else {
            throw error("invalid escape in single-line string")
          }
        default:
          throw error("invalid escape character '\\\(Character(esc))'")
        }
        continue
      }
      result.append(Character(c))
      advance()
    }
  }

  private mutating func parseUnicodeEscape(length: Int) throws -> Unicode.Scalar {
    var hex = ""
    for _ in 0..<length {
      guard let c = peek(), isHex(c) else {
        throw error("invalid \\u escape")
      }
      hex.append(Character(c))
      advance()
    }
    guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
      throw error("invalid unicode scalar \\u\(hex)")
    }
    return scalar
  }

  private func isHex(_ c: Unicode.Scalar) -> Bool {
    if c >= "0" && c <= "9" { return true }
    if c >= "a" && c <= "f" { return true }
    if c >= "A" && c <= "F" { return true }
    return false
  }

  // MARK: Arrays

  private mutating func parseArray() throws -> TOMLValue {
    try expect("[")
    var values: [TOMLValue] = []
    skip(allowNewlines: true)
    if peek() == "]" {
      advance()
      return .array(values)
    }
    while true {
      skip(allowNewlines: true)
      let value = try parseValue()
      values.append(value)
      skip(allowNewlines: true)
      if peek() == "," {
        advance()
        skip(allowNewlines: true)
        if peek() == "]" {
          advance()
          return .array(values)
        }
        continue
      }
      if peek() == "]" {
        advance()
        return .array(values)
      }
      throw error("expected ',' or ']' in array")
    }
  }

  // MARK: Inline tables

  private mutating func parseInlineTable() throws -> TOMLValue {
    try expect("{")
    skipInlineWhitespace()
    var table: [String: TOMLValue] = [:]
    if peek() == "}" {
      advance()
      return .table(table)
    }
    while true {
      skipInlineWhitespace()
      let key = try parseKey()
      skipInlineWhitespace()
      try expect("=")
      skipInlineWhitespace()
      let value = try parseValue()
      if table[key] != nil {
        throw error("duplicate key \"\(key)\" in inline table")
      }
      table[key] = value
      skipInlineWhitespace()
      if peek() == "," {
        advance()
        continue
      }
      if peek() == "}" {
        advance()
        return .table(table)
      }
      throw error("expected ',' or '}' in inline table")
    }
  }

  // MARK: Cursor helpers

  private mutating func expect(_ scalar: Unicode.Scalar) throws {
    guard let c = peek() else {
      throw error("expected '\(Character(scalar))', found end of input")
    }
    if c != scalar {
      throw error("expected '\(Character(scalar))', found '\(Character(c))'")
    }
    advance()
  }

  private mutating func expectEndOfLine() throws {
    skipInlineWhitespace()
    if isEOF { return }
    if peek() == "#" {
      while let c = peek(), c != "\n" { advance() }
      return
    }
    if peek() == "\n" || peek() == "\r" {
      advance()
      return
    }
    throw error("expected end of line, found '\(Character(peek()!))'")
  }

  // MARK: Mutation helpers for nested tables

  private mutating func createTableSlot(in root: inout [String: TOMLValue], path: [String]) throws
  {
    if path.isEmpty { return }
    try ensureTable(in: &root, path: path)
  }

  private mutating func appendArrayOfTablesSlot(
    in root: inout [String: TOMLValue], path: [String]
  ) {
    // Walk down to the parent, then append an empty table to the array at
    // `path.last`. Create intermediate tables as needed.
    var path = path
    let last = path.removeLast()
    var current = root
    var stack: [[String: TOMLValue]] = []
    var keys: [String] = []
    for segment in path {
      let existing = current[segment]
      var next: [String: TOMLValue]
      if let existing {
        if case .table(let t) = existing { next = t } else { next = [:] }
      } else {
        next = [:]
      }
      stack.append(current)
      keys.append(segment)
      current = next
    }

    var array: [TOMLValue] = []
    if case .array(let existing) = current[last] {
      array = existing
    }
    array.append(.table([:]))
    current[last] = .array(array)

    while let parent = stack.popLast(), let key = keys.popLast() {
      var mutable = parent
      mutable[key] = .table(current)
      current = mutable
    }
    root = current
  }

  private mutating func insertIntoTable(
    in root: inout [String: TOMLValue], path: [String], key: String, value: TOMLValue
  ) throws {
    try mutateTable(in: &root, path: path) { table in
      if table[key] != nil {
        throw self.error("duplicate key \"\(key)\"")
      }
      table[key] = value
    }
  }

  private mutating func insertIntoLastArrayTable(
    in root: inout [String: TOMLValue], path: [String], key: String, value: TOMLValue
  ) throws {
    var path = path
    let last = path.removeLast()
    try mutateTable(in: &root, path: path) { parent in
      guard case .array(var array) = parent[last], !array.isEmpty else {
        throw self.error("array of tables \"\(last)\" missing slot")
      }
      guard case .table(var table) = array.last! else {
        throw self.error("expected table in array of tables \"\(last)\"")
      }
      if table[key] != nil {
        throw self.error("duplicate key \"\(key)\"")
      }
      table[key] = value
      array[array.count - 1] = .table(table)
      parent[last] = .array(array)
    }
  }

  private mutating func ensureTable(in root: inout [String: TOMLValue], path: [String]) throws {
    try mutateTable(in: &root, path: path) { _ in }
  }

  private mutating func mutateTable(
    in root: inout [String: TOMLValue],
    path: [String],
    body: (inout [String: TOMLValue]) throws -> Void
  ) throws {
    if path.isEmpty {
      try body(&root)
      return
    }
    let head = path.first!
    var rest = path
    rest.removeFirst()

    var child: [String: TOMLValue]
    switch root[head] {
    case .none:
      child = [:]
    case .some(.table(let existing)):
      child = existing
    case .some(.array(let existing)):
      // Header walks into the last table of an array-of-tables.
      if rest.isEmpty {
        throw error("cannot redefine array-of-tables \"\(head)\" as table")
      }
      guard case .table(let last) = existing.last ?? .table([:]) else {
        throw error("malformed array-of-tables \"\(head)\"")
      }
      var copy = existing
      var modified = last
      try mutateTable(in: &modified, path: rest, body: body)
      copy[copy.count - 1] = .table(modified)
      root[head] = .array(copy)
      return
    default:
      throw error("path segment \"\(head)\" is not a table")
    }

    try mutateTable(in: &child, path: rest, body: body)
    root[head] = .table(child)
  }
}
