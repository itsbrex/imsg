import Foundation

public enum RuleLoader {
  private static let allowedKeys: Set<String> = [
    "name", "enabled", "match_text", "match_sender", "match_chat_id", "match_is_group",
    "after_time", "before_time", "action", "cmd", "url", "method", "headers",
    "body_template", "reply_text", "reply_with_ai", "dedupe_window_seconds",
    "cooldown_seconds", "stop_on_match",
  ]

  public static func load(path: String) throws -> RuleSet {
    let expanded = (path as NSString).expandingTildeInPath
    let source = try String(contentsOfFile: expanded, encoding: .utf8)
    return try parse(source)
  }

  public static func parse(_ source: String) throws -> RuleSet {
    let doc = try TOML.parse(source)
    guard let rawRules = doc["rule"]?.arrayValue, !rawRules.isEmpty else {
      throw RuleConfigError.missingRuleArray
    }

    var names = Set<String>()
    var rules: [Rule] = []
    for (index, raw) in rawRules.enumerated() {
      guard let table = raw.tableValue else {
        throw RuleConfigError.ruleNotTable(index + 1)
      }
      let rule = try parseRule(table, index: index + 1)
      guard names.insert(rule.name).inserted else {
        throw RuleConfigError.duplicateName(rule.name)
      }
      try validate(rule)
      rules.append(rule)
    }
    return RuleSet(rules: rules)
  }

  public static func validate(_ ruleSet: RuleSet) throws {
    var names = Set<String>()
    for rule in ruleSet.rules {
      guard names.insert(rule.name).inserted else {
        throw RuleConfigError.duplicateName(rule.name)
      }
      try validate(rule)
    }
  }

  private static func parseRule(_ table: [String: TOMLValue], index: Int) throws -> Rule {
    let preliminaryName = table["name"]?.stringValue ?? "#\(index)"
    for key in table.keys where !allowedKeys.contains(key) {
      throw RuleConfigError.unknownKey(rule: preliminaryName, key: key)
    }

    let name = try string(table, "name", rule: preliminaryName, required: true) ?? ""
    let enabled = try bool(table, "enabled", rule: name) ?? true
    let matchText = try string(table, "match_text", rule: name)
    let matchSender = try string(table, "match_sender", rule: name)
    let matchChatID = try integer(table, "match_chat_id", rule: name)
    let matchIsGroup = try bool(table, "match_is_group", rule: name)
    let afterTime = try string(table, "after_time", rule: name).map(RuleClockTime.parse)
    let beforeTime = try string(table, "before_time", rule: name).map(RuleClockTime.parse)

    guard let rawAction = try string(table, "action", rule: name, required: true),
      let action = RuleActionType(rawValue: rawAction)
    else {
      throw RuleConfigError.invalidValue("rule \(name) action must be exec, webhook, reply, or log")
    }

    let cmd = try stringArray(table, "cmd", rule: name) ?? []
    let url = try string(table, "url", rule: name).flatMap { URL(string: $0) }
    let method = (try string(table, "method", rule: name) ?? "POST").uppercased()
    let headers = try stringTable(table, "headers", rule: name) ?? [:]
    let bodyTemplate = try string(table, "body_template", rule: name)
    let replyText = try string(table, "reply_text", rule: name)
    let replyWithAI = try bool(table, "reply_with_ai", rule: name) ?? false
    guard !replyWithAI else {
      throw RuleConfigError.invalidValue("rule \(name) reply_with_ai is reserved")
    }
    let dedupeWindow = Int(try integer(table, "dedupe_window_seconds", rule: name) ?? 0)
    let cooldown = Int(try integer(table, "cooldown_seconds", rule: name) ?? 1)
    let stopOnMatch = try bool(table, "stop_on_match", rule: name) ?? false

    return Rule(
      name: name,
      enabled: enabled,
      matchText: matchText,
      matchSender: matchSender,
      matchChatID: matchChatID,
      matchIsGroup: matchIsGroup,
      afterTime: afterTime,
      beforeTime: beforeTime,
      action: action,
      cmd: cmd,
      url: url,
      method: method,
      headers: headers,
      bodyTemplate: bodyTemplate,
      replyText: replyText,
      dedupeWindowSeconds: dedupeWindow,
      cooldownSeconds: cooldown,
      stopOnMatch: stopOnMatch
    )
  }

  private static func validate(_ rule: Rule) throws {
    if rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw RuleConfigError.invalidValue("rule name cannot be empty")
    }
    if let pattern = rule.matchText {
      do {
        _ = try NSRegularExpression(pattern: pattern)
      } catch {
        throw RuleConfigError.invalidRegex(
          rule: rule.name,
          pattern: pattern,
          message: error.localizedDescription
        )
      }
    }
    if let url = rule.url, url.scheme?.lowercased() != "https" {
      throw RuleConfigError.invalidValue("rule \(rule.name) webhook url must be https")
    }
    if rule.method != "POST" && rule.method != "PUT" {
      throw RuleConfigError.invalidValue("rule \(rule.name) method must be POST or PUT")
    }
    if rule.dedupeWindowSeconds < 0 || rule.cooldownSeconds < 0 {
      throw RuleConfigError.invalidValue("rule \(rule.name) timing fields cannot be negative")
    }

    switch rule.action {
    case .exec:
      if rule.cmd.isEmpty {
        throw RuleConfigError.missingField(rule: rule.name, field: "cmd")
      }
    case .webhook:
      if rule.url == nil {
        throw RuleConfigError.missingField(rule: rule.name, field: "url")
      }
    case .reply:
      if rule.replyText == nil {
        throw RuleConfigError.missingField(rule: rule.name, field: "reply_text")
      }
    case .log:
      break
    }

    let synthetic = RuleMessageContext(
      message: Message(
        rowID: 1,
        chatID: 1,
        sender: "+15555550100",
        text: "hello",
        date: Date(timeIntervalSince1970: 1_700_000_000),
        isFromMe: false,
        service: "iMessage",
        handleID: nil,
        attachmentsCount: 0,
        guid: "synthetic-guid"
      ),
      chatName: "Synthetic",
      chatIdentifier: "iMessage;-;+15555550100",
      chatGUID: "iMessage;-;+15555550100",
      isGroup: false
    )
    let match = RuleMatch(rule: rule, captures: ["hello"])
    _ = RuleTemplate.render(rule.replyText ?? "", context: synthetic, match: match)
    _ = RuleTemplate.render(rule.bodyTemplate ?? "", context: synthetic, match: match)
    _ = rule.cmd.map { RuleTemplate.render($0, context: synthetic, match: match) }
    _ = rule.headers.mapValues { RuleTemplate.render($0, context: synthetic, match: match) }
  }

  private static func string(
    _ table: [String: TOMLValue],
    _ key: String,
    rule: String,
    required: Bool = false
  ) throws -> String? {
    guard let value = table[key] else {
      if required { throw RuleConfigError.missingField(rule: rule, field: key) }
      return nil
    }
    guard let string = value.stringValue else {
      throw RuleConfigError.invalidType(rule: rule, field: key, expected: "string")
    }
    return string
  }

  private static func integer(
    _ table: [String: TOMLValue],
    _ key: String,
    rule: String
  ) throws -> Int64? {
    guard let value = table[key] else { return nil }
    guard let integer = value.integerValue else {
      throw RuleConfigError.invalidType(rule: rule, field: key, expected: "integer")
    }
    return integer
  }

  private static func bool(
    _ table: [String: TOMLValue],
    _ key: String,
    rule: String
  ) throws -> Bool? {
    guard let value = table[key] else { return nil }
    guard let bool = value.boolValue else {
      throw RuleConfigError.invalidType(rule: rule, field: key, expected: "bool")
    }
    return bool
  }

  private static func stringArray(
    _ table: [String: TOMLValue],
    _ key: String,
    rule: String
  ) throws -> [String]? {
    guard let value = table[key] else { return nil }
    guard let array = value.arrayValue else {
      throw RuleConfigError.invalidType(rule: rule, field: key, expected: "array<string>")
    }
    return try array.map { item in
      guard let string = item.stringValue else {
        throw RuleConfigError.invalidType(rule: rule, field: key, expected: "array<string>")
      }
      return string
    }
  }

  private static func stringTable(
    _ table: [String: TOMLValue],
    _ key: String,
    rule: String
  ) throws -> [String: String]? {
    guard let value = table[key] else { return nil }
    guard let rawTable = value.tableValue else {
      throw RuleConfigError.invalidType(rule: rule, field: key, expected: "table<string,string>")
    }
    var result: [String: String] = [:]
    for (header, value) in rawTable {
      guard let string = value.stringValue else {
        throw RuleConfigError.invalidType(rule: rule, field: key, expected: "table<string,string>")
      }
      result[header] = string
    }
    return result
  }
}
