import Foundation

public enum RuleMatcher {
  public static func match(
    rule: Rule,
    context: RuleMessageContext,
    calendar: Calendar = .current
  ) throws -> RuleMatch? {
    guard rule.enabled else { return nil }
    if let sender = rule.matchSender, sender != context.message.sender {
      return nil
    }
    if let chatID = rule.matchChatID, chatID != context.message.chatID {
      return nil
    }
    if let isGroup = rule.matchIsGroup, isGroup != context.isGroup {
      return nil
    }
    if !matchesTimeWindow(rule: rule, date: context.message.date, calendar: calendar) {
      return nil
    }
    if let pattern = rule.matchText {
      let regex = try NSRegularExpression(pattern: pattern)
      let text = context.message.text
      let range = NSRange(text.startIndex..<text.endIndex, in: text)
      guard let match = regex.firstMatch(in: text, range: range) else { return nil }
      var captures: [String] = []
      captures.reserveCapacity(match.numberOfRanges)
      for index in 0..<match.numberOfRanges {
        let captureRange = match.range(at: index)
        guard captureRange.location != NSNotFound,
          let range = Range(captureRange, in: text)
        else {
          captures.append("")
          continue
        }
        captures.append(String(text[range]))
      }
      return RuleMatch(rule: rule, captures: captures)
    }
    return RuleMatch(rule: rule, captures: [])
  }

  private static func matchesTimeWindow(
    rule: Rule,
    date: Date,
    calendar: Calendar
  ) -> Bool {
    guard rule.afterTime != nil || rule.beforeTime != nil else { return true }
    let components = calendar.dateComponents([.hour, .minute], from: date)
    let current = (components.hour ?? 0) * 60 + (components.minute ?? 0)
    let start = rule.afterTime?.minutesSinceMidnight
    let end = rule.beforeTime?.minutesSinceMidnight

    switch (start, end) {
    case (let start?, let end?):
      if start <= end {
        return current >= start && current < end
      }
      return current >= start || current < end
    case (let start?, nil):
      return current >= start
    case (nil, let end?):
      return current < end
    case (nil, nil):
      return true
    }
  }
}

public enum RuleTemplate {
  public static func render(
    _ template: String,
    context: RuleMessageContext,
    match: RuleMatch
  ) -> String {
    let escapedOpen = "\u{0}IMSG_ESCAPED_OPEN\u{0}"
    var rendered = template.replacingOccurrences(
      of: #"\\\{\{"#, with: escapedOpen, options: .regularExpression)
    let pattern = #"\{\{\s*([A-Za-z0-9_.-]+)\s*\}\}"#
    let regex = try? NSRegularExpression(pattern: pattern)
    let nsRange = NSRange(rendered.startIndex..<rendered.endIndex, in: rendered)
    let matches = regex?.matches(in: rendered, range: nsRange) ?? []
    for result in matches.reversed() {
      guard result.numberOfRanges >= 2,
        let whole = Range(result.range(at: 0), in: rendered),
        let keyRange = Range(result.range(at: 1), in: rendered)
      else { continue }
      let key = String(rendered[keyRange])
      rendered.replaceSubrange(whole, with: value(for: key, context: context, match: match))
    }
    return rendered.replacingOccurrences(of: escapedOpen, with: "{{")
  }

  private static func value(
    for key: String,
    context: RuleMessageContext,
    match: RuleMatch
  ) -> String {
    switch key {
    case "text":
      return context.message.text
    case "sender":
      return context.message.sender
    case "chat_id":
      return String(context.message.chatID)
    case "chat_name":
      if !context.chatName.isEmpty { return context.chatName }
      return context.message.sender
    case "created_at":
      return ISO8601DateFormatter().string(from: context.message.date)
    default:
      if key.hasPrefix("match."),
        let index = Int(key.dropFirst("match.".count)),
        match.captures.indices.contains(index)
      {
        return match.captures[index]
      }
      return ""
    }
  }
}
