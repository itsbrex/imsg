import Foundation

// Container parsing (arrays + inline tables) and the nested-table
// mutation helpers used to honor `[table]` and `[[array-of-tables]]`
// headers. Kept in a separate file so `TOMLParser.swift` stays under
// the project's file-length lint cap.
extension TOMLParser {

  // MARK: Arrays

  mutating func parseArray() throws -> TOMLValue {
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

  mutating func parseInlineTable() throws -> TOMLValue {
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

  // MARK: Mutation helpers for nested tables

  mutating func createTableSlot(in root: inout [String: TOMLValue], path: [String]) throws {
    if path.isEmpty { return }
    try ensureTable(in: &root, path: path)
  }

  mutating func appendArrayOfTablesSlot(
    in root: inout [String: TOMLValue], path: [String]
  ) {
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

  mutating func insertIntoTable(
    in root: inout [String: TOMLValue], path: [String], key: String, value: TOMLValue
  ) throws {
    try mutateTable(in: &root, path: path) { table in
      if table[key] != nil {
        throw self.error("duplicate key \"\(key)\"")
      }
      table[key] = value
    }
  }

  mutating func insertIntoLastArrayTable(
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

  mutating func ensureTable(in root: inout [String: TOMLValue], path: [String]) throws {
    try mutateTable(in: &root, path: path) { _ in }
  }

  mutating func mutateTable(
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
