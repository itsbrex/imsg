import Foundation

public protocol RuleActionPerforming: Sendable {
  func perform(match: RuleMatch, context: RuleMessageContext, dryRun: Bool) async throws
    -> RuleActionInvocation
}

public struct RulesActionRunner: RuleActionPerforming {
  public var http: HTTP
  public var sender: MessageSender
  public var logURL: URL
  public var environment: [String: String]

  public init(
    http: HTTP = HTTP(),
    sender: MessageSender = MessageSender(),
    logURL: URL = RulesActionRunner.defaultLogURL(),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.http = http
    self.sender = sender
    self.logURL = logURL
    self.environment = environment
  }

  public static func defaultLogURL() -> URL {
    let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
    return base.appendingPathComponent("Logs/imsg/rules.log")
  }

  public func perform(
    match: RuleMatch,
    context: RuleMessageContext,
    dryRun: Bool
  ) async throws -> RuleActionInvocation {
    switch match.rule.action {
    case .log:
      return try performLog(match: match, context: context, dryRun: dryRun)
    case .exec:
      return try performExec(match: match, context: context, dryRun: dryRun)
    case .webhook:
      return try await performWebhook(match: match, context: context, dryRun: dryRun)
    case .reply:
      return try performReply(match: match, context: context, dryRun: dryRun)
    }
  }

  private func performLog(
    match: RuleMatch,
    context: RuleMessageContext,
    dryRun: Bool
  ) throws -> RuleActionInvocation {
    let line = try logLine(rule: match.rule, context: context)
    if !dryRun {
      try appendLog(line)
    }
    return invocation(match: match, context: context, detail: "log \(logURL.path)")
  }

  private func performExec(
    match: RuleMatch,
    context: RuleMessageContext,
    dryRun: Bool
  ) throws -> RuleActionInvocation {
    let argv = match.rule.cmd.map { RuleTemplate.render($0, context: context, match: match) }
    let detail = argv.joined(separator: " ")
    guard !dryRun else {
      return invocation(match: match, context: context, detail: detail)
    }
    guard let executable = executableURL(for: argv[0]) else {
      throw RuleConfigError.invalidValue("rule \(match.rule.name) executable not found: \(argv[0])")
    }

    let process = Process()
    process.executableURL = executable
    process.arguments = Array(argv.dropFirst())
    process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    var env = environment
    env["IMSG_RULE_NAME"] = match.rule.name
    env["IMSG_MESSAGE_GUID"] = messageGUID(context.message)
    env["IMSG_CHAT_ID"] = String(context.message.chatID)
    env["IMSG_SENDER"] = context.message.sender
    env["IMSG_TEXT"] = String(context.message.text.prefix(4096))
    process.environment = env

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let finished = wait(process: process, timeout: 30)
    if !finished {
      process.terminate()
      Thread.sleep(forTimeInterval: 2)
      if process.isRunning { process.interrupt() }
    }
    let output =
      String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    try appendLog(
      "[\(match.rule.name)] \(messageGUID(context.message)) exec status=\(finished ? process.terminationStatus : -1)\n\(output)\(err)"
    )
    return invocation(
      match: match,
      context: context,
      detail: "\(detail) status=\(finished ? process.terminationStatus : -1)"
    )
  }

  private func performWebhook(
    match: RuleMatch,
    context: RuleMessageContext,
    dryRun: Bool
  ) async throws -> RuleActionInvocation {
    guard let url = match.rule.url else {
      throw RuleConfigError.missingField(rule: match.rule.name, field: "url")
    }
    let body = RuleTemplate.render(match.rule.bodyTemplate ?? "", context: context, match: match)
    var headers = match.rule.headers.mapValues {
      RuleTemplate.render($0, context: context, match: match)
    }
    if headers["Content-Type"] == nil && headers["content-type"] == nil {
      let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
      headers["Content-Type"] =
        (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) ? "application/json" : "text/plain"
    }
    let detail = "\(match.rule.method) \(url.absoluteString)"
    guard !dryRun else {
      return invocation(match: match, context: context, detail: detail)
    }
    let secret = environment["IMSG_RULES_SECRET"].flatMap { $0.data(using: .utf8) }
    let request = HTTPRequest(
      url: url,
      method: match.rule.method,
      headers: headers,
      body: body.data(using: .utf8),
      timeout: 10,
      retryPolicy: .default,
      hmacSecret: secret
    )
    _ = try await http.perform(request)
    return invocation(match: match, context: context, detail: detail)
  }

  private func performReply(
    match: RuleMatch,
    context: RuleMessageContext,
    dryRun: Bool
  ) throws -> RuleActionInvocation {
    let text = RuleTemplate.render(match.rule.replyText ?? "", context: context, match: match)
    let detail = "reply chat_id=\(context.message.chatID) text=\(text)"
    guard !dryRun else {
      return invocation(match: match, context: context, detail: detail)
    }
    try sender.send(
      MessageSendOptions(
        recipient: "",
        text: text,
        service: .auto,
        chatIdentifier: context.chatIdentifier,
        chatGUID: context.chatGUID
      ))
    return invocation(match: match, context: context, detail: detail)
  }

  private func logLine(rule: Rule, context: RuleMessageContext) throws -> String {
    let object: [String: Any] = [
      "ts": ISO8601DateFormatter().string(from: Date()),
      "rule": rule.name,
      "guid": messageGUID(context.message),
      "chat_id": context.message.chatID,
      "sender": context.message.sender,
      "text": context.message.text,
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(data: data, encoding: .utf8) ?? "{}"
  }

  private func appendLog(_ line: String) throws {
    try FileManager.default.createDirectory(
      at: logURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = (line.hasSuffix("\n") ? line : line + "\n").data(using: .utf8) ?? Data()
    if !FileManager.default.fileExists(atPath: logURL.path) {
      try data.write(to: logURL)
      return
    }
    let handle = try FileHandle(forWritingTo: logURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  }

  private func invocation(
    match: RuleMatch,
    context: RuleMessageContext,
    detail: String
  ) -> RuleActionInvocation {
    RuleActionInvocation(
      ruleName: match.rule.name,
      action: match.rule.action,
      messageGUID: messageGUID(context.message),
      chatID: context.message.chatID,
      detail: detail
    )
  }

  private func executableURL(for command: String) -> URL? {
    if command.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: command) {
      return URL(fileURLWithPath: command)
    }
    let path = environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
    for dir in path.split(separator: ":") {
      let candidate = "\(dir)/\(command)"
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return URL(fileURLWithPath: candidate)
      }
    }
    return nil
  }

  private func wait(process: Process, timeout: TimeInterval) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in semaphore.signal() }
    return semaphore.wait(timeout: .now() + timeout) == .success
  }
}

public struct RulesEngine<Performer: RuleActionPerforming>: Sendable {
  public let state: RulesState
  public let performer: Performer
  public var calendar: Calendar

  public init(state: RulesState, performer: Performer, calendar: Calendar = .current) {
    self.state = state
    self.performer = performer
    self.calendar = calendar
  }

  public func process(
    context: RuleMessageContext,
    ruleSet: RuleSet,
    dryRun: Bool = false,
    now: Date = Date()
  ) async throws -> [RuleActionInvocation] {
    var invocations: [RuleActionInvocation] = []
    try await state.setCursor(context.message.rowID)

    for rule in ruleSet.rules {
      if rule.action == .reply && context.message.isFromMe {
        continue
      }
      guard let match = try RuleMatcher.match(rule: rule, context: context, calendar: calendar)
      else {
        continue
      }
      let guid = messageGUID(context.message)
      guard try await state.canFire(rule: rule, messageGUID: guid, now: now) else {
        continue
      }
      let invocation = try await performer.perform(match: match, context: context, dryRun: dryRun)
      invocations.append(invocation)
      if !dryRun {
        try await state.recordFire(rule: rule, messageGUID: guid, now: now)
      }
      if rule.stopOnMatch {
        break
      }
    }

    return invocations
  }
}

func messageGUID(_ message: Message) -> String {
  message.guid.isEmpty ? "row:\(message.rowID)" : message.guid
}
