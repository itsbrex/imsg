import Foundation
import Testing

@testable import IMsgCore

@Test
func parsesTopLevelScalars() throws {
  let doc = try TOML.parse(
    #"""
    title = "imsg"
    enabled = true
    count = 42
    rate = 3.14
    """#
  )
  #expect(doc["title"]?.stringValue == "imsg")
  #expect(doc["enabled"]?.boolValue == true)
  #expect(doc["count"]?.integerValue == 42)
  #expect(doc["rate"]?.floatValue == 3.14)
}

@Test
func ignoresCommentsAndBlankLines() throws {
  let doc = try TOML.parse(
    """
    # a leading comment
    name = "deploy"   # trailing comment

    enabled = false
    """
  )
  #expect(doc["name"]?.stringValue == "deploy")
  #expect(doc["enabled"]?.boolValue == false)
}

@Test
func parsesEscapesInBasicString() throws {
  let doc = try TOML.parse(
    #"text = "line1\nline2\t\"q\"\\é""#
  )
  #expect(doc["text"]?.stringValue == "line1\nline2\t\"q\"\\é")
}

@Test
func parsesTripleQuotedStringTrimsLeadingNewline() throws {
  let source = """
    body = \"\"\"
    hello
    {{world}}
    \"\"\"
    """
  let doc = try TOML.parse(source)
  #expect(doc["body"]?.stringValue == "hello\n{{world}}\n")
}

@Test
func parsesNumbersWithSignAndUnderscores() throws {
  let doc = try TOML.parse(
    """
    a = +42
    b = -7
    c = 1_000_000
    d = -1.5
    e = 6.022e23
    """
  )
  #expect(doc["a"]?.integerValue == 42)
  #expect(doc["b"]?.integerValue == -7)
  #expect(doc["c"]?.integerValue == 1_000_000)
  #expect(doc["d"]?.floatValue == -1.5)
  #expect(doc["e"]?.floatValue == 6.022e23)
}

@Test
func parsesArrayOnSingleAndMultipleLines() throws {
  let doc = try TOML.parse(
    """
    one = [1, 2, 3]
    words = [
      "alpha",
      "beta",
      "gamma",
    ]
    """
  )
  #expect(doc["one"]?.arrayValue?.compactMap { $0.integerValue } == [1, 2, 3])
  #expect(doc["words"]?.arrayValue?.compactMap { $0.stringValue } == ["alpha", "beta", "gamma"])
}

@Test
func parsesInlineTable() throws {
  let doc = try TOML.parse(
    #"headers = { "Content-Type" = "application/json", "X-Token" = "abc" }"#
  )
  let table = try #require(doc["headers"]?.tableValue)
  #expect(table["Content-Type"]?.stringValue == "application/json")
  #expect(table["X-Token"]?.stringValue == "abc")
}

@Test
func parsesTableHeader() throws {
  let doc = try TOML.parse(
    """
    [server]
    host = "localhost"
    port = 8080
    """
  )
  let server = try #require(doc["server"]?.tableValue)
  #expect(server["host"]?.stringValue == "localhost")
  #expect(server["port"]?.integerValue == 8080)
}

@Test
func parsesArrayOfTables() throws {
  let doc = try TOML.parse(
    """
    [[rule]]
    name = "one"
    enabled = true

    [[rule]]
    name = "two"
    enabled = false
    """
  )
  let rules = try #require(doc["rule"]?.arrayValue)
  #expect(rules.count == 2)
  #expect(rules[0].tableValue?["name"]?.stringValue == "one")
  #expect(rules[0].tableValue?["enabled"]?.boolValue == true)
  #expect(rules[1].tableValue?["name"]?.stringValue == "two")
  #expect(rules[1].tableValue?["enabled"]?.boolValue == false)
}

@Test
func parsesRealisticRulesFixture() throws {
  let source = """
    # mention bridge
    [[rule]]
    name = "deploy-mentions"
    match_text = "(?i)^deploy (.+)"
    match_chat_id = 42
    action = "exec"
    cmd = ["/usr/local/bin/deploy", "{{match.1}}"]
    dedupe_window_seconds = 30

    [[rule]]
    name = "mention-webhook"
    match_text = "@team"
    action = "webhook"
    url = "https://hooks.slack.com/services/T000/B000/xxx"
    method = "POST"
    headers = { "Content-Type" = "application/json" }
    body_template = \"\"\"
    {"text":"{{sender}} in {{chat_name}}: {{text}}"}
    \"\"\"
    """
  let doc = try TOML.parse(source)
  let rules = try #require(doc["rule"]?.arrayValue)
  #expect(rules.count == 2)

  let deploy = try #require(rules[0].tableValue)
  #expect(deploy["name"]?.stringValue == "deploy-mentions")
  #expect(deploy["action"]?.stringValue == "exec")
  #expect(deploy["dedupe_window_seconds"]?.integerValue == 30)
  let cmd = try #require(deploy["cmd"]?.arrayValue)
  #expect(cmd.compactMap { $0.stringValue } == ["/usr/local/bin/deploy", "{{match.1}}"])

  let webhook = try #require(rules[1].tableValue)
  #expect(webhook["url"]?.stringValue == "https://hooks.slack.com/services/T000/B000/xxx")
  let headers = try #require(webhook["headers"]?.tableValue)
  #expect(headers["Content-Type"]?.stringValue == "application/json")
  let body = try #require(webhook["body_template"]?.stringValue)
  #expect(body.contains("{{sender}}"))
  #expect(body.hasSuffix("\n"))
}

@Test
func rejectsUnterminatedString() {
  #expect(throws: TOMLError.self) {
    try TOML.parse(#"name = "missing"#)
  }
}

@Test
func rejectsDuplicateTopLevelKey() {
  #expect(throws: TOMLError.self) {
    try TOML.parse(
      """
      a = 1
      a = 2
      """
    )
  }
}

@Test
func rejectsDuplicateTableHeader() {
  #expect(throws: TOMLError.self) {
    try TOML.parse(
      """
      [a]
      x = 1

      [a]
      y = 2
      """
    )
  }
}

@Test
func rejectsInvalidEscape() {
  #expect(throws: TOMLError.self) {
    try TOML.parse(#"text = "bad \q escape""#)
  }
}

@Test
func rejectsNewlineInsideSingleLineString() {
  #expect(throws: TOMLError.self) {
    try TOML.parse(
      """
      bad = "first
      second"
      """
    )
  }
}

@Test
func errorReportsLineAndColumn() {
  do {
    _ = try TOML.parse(
      """
      a = 1
      b = ?
      """
    )
    Issue.record("expected throw")
  } catch let err as TOMLError {
    #expect(err.line == 2)
  } catch {
    Issue.record("unexpected error: \(error)")
  }
}
