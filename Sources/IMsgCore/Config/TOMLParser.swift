import Foundation

/// Recursive-descent parser for the TOML subset documented in `TOML.swift`.
/// Splits across two files (this one + `TOMLParser+Mutation.swift`) to keep
/// each file under the project's file-length lint cap.
struct TOMLParser {
  let scalars: [Unicode.Scalar]
  var index: Int = 0
  var line: Int = 1
  var column: Int = 1

  init(source: String) {
    self.scalars = Array(source.unicodeScalars)
  }

  // MARK: Cursor

  var isEOF: Bool { index >= scalars.count }

  func peek(offset: Int = 0) -> Unicode.Scalar? {
    let i = index + offset
    return i < scalars.count ? scalars[i] : nil
  }

  @discardableResult
  mutating func advance() -> Unicode.Scalar? {
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

  func error(_ message: String) -> TOMLError {
    TOMLError(message, line: line, column: column)
  }

  // MARK: Whitespace + comments

  mutating func skipInlineWhitespace() {
    while let c = peek(), c == " " || c == "\t" {
      advance()
    }
  }

  /// Skip whitespace, comments, and (optionally) newlines.
  mutating func skip(allowNewlines: Bool) {
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
    var currentPath: [String] = []
    var currentIsArray = false
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

  mutating func parseHeaderKey() throws -> [String] {
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

  mutating func parseKey() throws -> String {
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

  func isBareKeyScalar(_ c: Unicode.Scalar) -> Bool {
    if c >= "A" && c <= "Z" { return true }
    if c >= "a" && c <= "z" { return true }
    if c >= "0" && c <= "9" { return true }
    return c == "_" || c == "-"
  }

  // MARK: Value dispatch + scalars

  mutating func parseValue() throws -> TOMLValue {
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

  mutating func parseBool() throws -> TOMLValue {
    if matchKeyword("true") { return .bool(true) }
    if matchKeyword("false") { return .bool(false) }
    throw error("expected boolean")
  }

  mutating func matchKeyword(_ keyword: String) -> Bool {
    let keyScalars = Array(keyword.unicodeScalars)
    guard index + keyScalars.count <= scalars.count else { return false }
    for (i, ks) in keyScalars.enumerated() where scalars[index + i] != ks {
      return false
    }
    if let next = peek(offset: keyScalars.count), isBareKeyScalar(next) {
      return false
    }
    for _ in 0..<keyScalars.count { advance() }
    return true
  }

  mutating func parseNumber() throws -> TOMLValue {
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

  mutating func parseBasicString(allowMultiline: Bool) throws -> String {
    try expect("\"")
    if allowMultiline {
      try expect("\"")
      try expect("\"")
      if peek() == "\r" { advance() }
      if peek() == "\n" { advance() }
      return try parseStringBody(multiline: true)
    } else {
      return try parseStringBody(multiline: false)
    }
  }

  mutating func parseStringBody(multiline: Bool) throws -> String {
    var result = ""
    while true {
      guard let c = peek() else { throw error("unterminated string") }
      if c == "\"" {
        if multiline {
          if peek(offset: 1) == "\"" && peek(offset: 2) == "\"" {
            advance(); advance(); advance()
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

  mutating func parseUnicodeEscape(length: Int) throws -> Unicode.Scalar {
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

  func isHex(_ c: Unicode.Scalar) -> Bool {
    if c >= "0" && c <= "9" { return true }
    if c >= "a" && c <= "f" { return true }
    if c >= "A" && c <= "F" { return true }
    return false
  }

  // MARK: Cursor helpers

  mutating func expect(_ scalar: Unicode.Scalar) throws {
    guard let c = peek() else {
      throw error("expected '\(Character(scalar))', found end of input")
    }
    if c != scalar {
      throw error("expected '\(Character(scalar))', found '\(Character(c))'")
    }
    advance()
  }

  mutating func expectEndOfLine() throws {
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
}
