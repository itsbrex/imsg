import Foundation

public enum RuleActionType: String, CaseIterable, Sendable, Equatable {
  case exec
  case webhook
  case reply
  case log
}

public struct Rule: Sendable, Equatable {
  public let name: String
  public let enabled: Bool
  public let matchText: String?
  public let matchSender: String?
  public let matchChatID: Int64?
  public let matchIsGroup: Bool?
  public let afterTime: RuleClockTime?
  public let beforeTime: RuleClockTime?
  public let action: RuleActionType
  public let cmd: [String]
  public let url: URL?
  public let method: String
  public let headers: [String: String]
  public let bodyTemplate: String?
  public let replyText: String?
  public let dedupeWindowSeconds: Int
  public let cooldownSeconds: Int
  public let stopOnMatch: Bool

  public init(
    name: String,
    enabled: Bool = true,
    matchText: String? = nil,
    matchSender: String? = nil,
    matchChatID: Int64? = nil,
    matchIsGroup: Bool? = nil,
    afterTime: RuleClockTime? = nil,
    beforeTime: RuleClockTime? = nil,
    action: RuleActionType,
    cmd: [String] = [],
    url: URL? = nil,
    method: String = "POST",
    headers: [String: String] = [:],
    bodyTemplate: String? = nil,
    replyText: String? = nil,
    dedupeWindowSeconds: Int = 0,
    cooldownSeconds: Int = 1,
    stopOnMatch: Bool = false
  ) {
    self.name = name
    self.enabled = enabled
    self.matchText = matchText
    self.matchSender = matchSender
    self.matchChatID = matchChatID
    self.matchIsGroup = matchIsGroup
    self.afterTime = afterTime
    self.beforeTime = beforeTime
    self.action = action
    self.cmd = cmd
    self.url = url
    self.method = method
    self.headers = headers
    self.bodyTemplate = bodyTemplate
    self.replyText = replyText
    self.dedupeWindowSeconds = dedupeWindowSeconds
    self.cooldownSeconds = max(1, cooldownSeconds)
    self.stopOnMatch = stopOnMatch
  }

  public var effectiveCooldownSeconds: Int {
    action == .reply ? max(cooldownSeconds, 5) : max(cooldownSeconds, 1)
  }

  public var matchSummary: String {
    var parts: [String] = []
    if let matchText { parts.append("text=\(matchText)") }
    if let matchSender { parts.append("sender=\(matchSender)") }
    if let matchChatID { parts.append("chat_id=\(matchChatID)") }
    if let matchIsGroup { parts.append("is_group=\(matchIsGroup)") }
    if let afterTime { parts.append("after=\(afterTime)") }
    if let beforeTime { parts.append("before=\(beforeTime)") }
    return parts.isEmpty ? "all messages" : parts.joined(separator: ", ")
  }
}

public struct RuleClockTime: Sendable, Equatable, CustomStringConvertible {
  public let hour: Int
  public let minute: Int

  public init(hour: Int, minute: Int) throws {
    guard (0...23).contains(hour), (0...59).contains(minute) else {
      throw RuleConfigError.invalidValue("time must be HH:MM")
    }
    self.hour = hour
    self.minute = minute
  }

  public static func parse(_ raw: String) throws -> RuleClockTime {
    let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
      throw RuleConfigError.invalidValue("time must be HH:MM")
    }
    return try RuleClockTime(hour: hour, minute: minute)
  }

  var minutesSinceMidnight: Int { hour * 60 + minute }

  public var description: String {
    String(format: "%02d:%02d", hour, minute)
  }
}

public struct RuleSet: Sendable, Equatable {
  public let rules: [Rule]

  public init(rules: [Rule]) {
    self.rules = rules
  }
}

public struct RuleMatch: Sendable, Equatable {
  public let rule: Rule
  public let captures: [String]

  public init(rule: Rule, captures: [String]) {
    self.rule = rule
    self.captures = captures
  }
}

public struct RuleMessageContext: Sendable, Equatable {
  public let message: Message
  public let chatName: String
  public let chatIdentifier: String
  public let chatGUID: String
  public let isGroup: Bool

  public init(
    message: Message,
    chatName: String = "",
    chatIdentifier: String = "",
    chatGUID: String = "",
    isGroup: Bool = false
  ) {
    self.message = message
    self.chatName = chatName
    self.chatIdentifier = chatIdentifier
    self.chatGUID = chatGUID
    self.isGroup = isGroup
  }
}

public struct RuleActionInvocation: Sendable, Equatable {
  public let ruleName: String
  public let action: RuleActionType
  public let messageGUID: String
  public let chatID: Int64
  public let detail: String

  public init(
    ruleName: String,
    action: RuleActionType,
    messageGUID: String,
    chatID: Int64,
    detail: String
  ) {
    self.ruleName = ruleName
    self.action = action
    self.messageGUID = messageGUID
    self.chatID = chatID
    self.detail = detail
  }
}

public enum RuleConfigError: Error, Sendable, CustomStringConvertible, Equatable {
  case missingRuleArray
  case ruleNotTable(Int)
  case duplicateName(String)
  case unknownKey(rule: String, key: String)
  case missingField(rule: String, field: String)
  case invalidValue(String)
  case invalidType(rule: String, field: String, expected: String)
  case invalidRegex(rule: String, pattern: String, message: String)

  public var description: String {
    switch self {
    case .missingRuleArray:
      return "rules config must contain at least one [[rule]] table"
    case .ruleNotTable(let index):
      return "rule \(index) must be a table"
    case .duplicateName(let name):
      return "duplicate rule name: \(name)"
    case .unknownKey(let rule, let key):
      return "unknown key in rule \(rule): \(key)"
    case .missingField(let rule, let field):
      return "rule \(rule) is missing required field: \(field)"
    case .invalidValue(let message):
      return message
    case .invalidType(let rule, let field, let expected):
      return "rule \(rule) field \(field) must be \(expected)"
    case .invalidRegex(let rule, let pattern, let message):
      return "rule \(rule) has invalid match_text \(pattern): \(message)"
    }
  }
}
