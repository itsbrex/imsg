import Foundation
import IMsgCore
import Testing

@Test
func ruleLoaderParsesRealisticConfig() throws {
  let rules = try RuleLoader.parse(
    """
    [[rule]]
    name = "deploy"
    match_text = "(?i)^deploy (.+)"
    match_chat_id = 42
    action = "exec"
    cmd = ["/bin/echo", "{{match.1}}"]
    cooldown_seconds = 10

    [[rule]]
    name = "mention"
    enabled = false
    action = "webhook"
    url = "https://example.com/hook"
    headers = { "X-Test" = "{{sender}}" }
    body_template = "{\\"text\\":\\"{{text}}\\"}"
    """
  )

  #expect(rules.rules.count == 2)
  #expect(rules.rules[0].name == "deploy")
  #expect(rules.rules[0].cmd == ["/bin/echo", "{{match.1}}"])
  #expect(rules.rules[1].enabled == false)
  #expect(rules.rules[1].headers["X-Test"] == "{{sender}}")
}

@Test
func ruleLoaderRejectsUnknownKeysAndMissingRequiredActionFields() throws {
  #expect(throws: RuleConfigError.self) {
    try RuleLoader.parse(
      """
      [[rule]]
      name = "bad"
      action = "log"
      typo = true
      """
    )
  }

  #expect(throws: RuleConfigError.self) {
    try RuleLoader.parse(
      """
      [[rule]]
      name = "bad-reply"
      action = "reply"
      """
    )
  }
}

@Test
func matcherCapturesRegexGroupsAndRendersTemplates() throws {
  let rule = Rule(
    name: "deploy",
    matchText: #"^deploy (.+)$"#,
    matchChatID: 7,
    action: .exec,
    cmd: ["/bin/echo", "{{match.1}}"]
  )
  let context = RuleMessageContext(
    message: makeRuleMessage(text: "deploy api", chatID: 7, sender: "+1555"),
    chatName: "Ops",
    chatIdentifier: "iMessage;-;7",
    chatGUID: "iMessage;-;7",
    isGroup: true
  )

  let match = try #require(try RuleMatcher.match(rule: rule, context: context))
  #expect(match.captures == ["deploy api", "api"])
  #expect(
    RuleTemplate.render("{{sender}} {{chat_name}} {{match.1}}", context: context, match: match)
      == "+1555 Ops api"
  )
}

@Test
func rulesStateDedupesAndAppliesCooldowns() async throws {
  let state = try await RulesState.open(at: tempRulesStateURL())
  let rule = Rule(
    name: "audit",
    action: .log,
    dedupeWindowSeconds: 60,
    cooldownSeconds: 10
  )
  let now = Date(timeIntervalSince1970: 1_700_000_000)

  #expect(try await state.canFire(rule: rule, messageGUID: "g1", now: now))
  try await state.recordFire(rule: rule, messageGUID: "g1", now: now)
  #expect(
    try await state.canFire(rule: rule, messageGUID: "g1", now: now.addingTimeInterval(59)) == false
  )
  #expect(try await state.canFire(rule: rule, messageGUID: "g1", now: now.addingTimeInterval(61)))
  #expect(
    try await state.canFire(rule: rule, messageGUID: "g2", now: now.addingTimeInterval(9)) == false)
  #expect(try await state.canFire(rule: rule, messageGUID: "g2", now: now.addingTimeInterval(10)))
}

@Test
func engineDryRunDoesNotPersistDedupe() async throws {
  let state = try await RulesState.open(at: tempRulesStateURL())
  let performer = RecordingRulePerformer()
  let engine = RulesEngine(state: state, performer: performer)
  let ruleSet = RuleSet(rules: [
    Rule(name: "audit", matchText: "hello", action: .log, dedupeWindowSeconds: 60)
  ])
  let context = RuleMessageContext(message: makeRuleMessage(text: "hello", guid: "dry"))

  let first = try await engine.process(context: context, ruleSet: ruleSet, dryRun: true)
  let second = try await engine.process(context: context, ruleSet: ruleSet, dryRun: true)

  #expect(first.count == 1)
  #expect(second.count == 1)
  #expect(await performer.count == 2)
}

@Test
func enginePersistsDedupeAfterRealFire() async throws {
  let state = try await RulesState.open(at: tempRulesStateURL())
  let performer = RecordingRulePerformer()
  let engine = RulesEngine(state: state, performer: performer)
  let ruleSet = RuleSet(rules: [
    Rule(name: "audit", matchText: "hello", action: .log, dedupeWindowSeconds: 60)
  ])
  let context = RuleMessageContext(message: makeRuleMessage(text: "hello", guid: "real"))

  let first = try await engine.process(context: context, ruleSet: ruleSet, dryRun: false)
  let second = try await engine.process(context: context, ruleSet: ruleSet, dryRun: false)

  #expect(first.count == 1)
  #expect(second.isEmpty)
  #expect(await performer.count == 1)
}

private actor RecordingRulePerformer: RuleActionPerforming {
  private var invocations: [RuleActionInvocation] = []

  var count: Int { invocations.count }

  func perform(match: RuleMatch, context: RuleMessageContext, dryRun: Bool) async throws
    -> RuleActionInvocation
  {
    let invocation = RuleActionInvocation(
      ruleName: match.rule.name,
      action: match.rule.action,
      messageGUID: context.message.guid,
      chatID: context.message.chatID,
      detail: dryRun ? "dry" : "real"
    )
    invocations.append(invocation)
    return invocation
  }
}

private func makeRuleMessage(
  text: String,
  chatID: Int64 = 1,
  sender: String = "+15551234567",
  guid: String = "guid-1",
  isFromMe: Bool = false
) -> Message {
  Message(
    rowID: 1,
    chatID: chatID,
    sender: sender,
    text: text,
    date: Date(timeIntervalSince1970: 1_700_000_000),
    isFromMe: isFromMe,
    service: "iMessage",
    handleID: nil,
    attachmentsCount: 0,
    guid: guid
  )
}

private func tempRulesStateURL() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("imsg-rules-\(UUID().uuidString)")
    .appendingPathComponent("rules.sqlite")
}
