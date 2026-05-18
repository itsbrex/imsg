import Commander
import Foundation
import IMsgCore

enum RulesCommand {
  static let spec = CommandSpec(
    name: "rules",
    abstract: "Validate and run TOML message automation rules",
    discussion: """
      Actions are selected with --action:
        validate  Parse and typecheck --config
        list      List configured rules and recent fires
        run       Evaluate rules against the watch stream
        tail      Print the rules log
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "action", names: [.long("action")], help: "run | validate | list | tail"),
          .make(label: "config", names: [.long("config"), .short("c")], help: "Rules TOML path"),
          .make(label: "state", names: [.long("state")], help: "rules state SQLite path"),
          .make(label: "chatID", names: [.long("chat-id")], help: "limit watch to chat rowid"),
          .make(label: "since", names: [.long("since")], help: "start after message ROWID"),
          .make(label: "limit", names: [.long("limit")], help: "stop after N watched messages"),
        ],
        flags: [
          .make(label: "dryRun", names: [.long("dry-run")], help: "Log actions without executing"),
          .make(label: "follow", names: [.long("follow"), .short("f")], help: "follow rules log"),
        ]
      )
    ),
    usageExamples: [
      "imsg rules --action validate --config ~/.config/imsg/rules.toml",
      "imsg rules --action run --config ~/.config/imsg/rules.toml --dry-run",
      "imsg rules --action list --config ~/.config/imsg/rules.toml",
      "imsg rules --action tail --follow",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    switch values.option("action") ?? "list" {
    case "validate":
      try runValidate(values: values, runtime: runtime)
    case "list":
      try await runList(values: values, runtime: runtime)
    case "run":
      try await runRules(values: values, runtime: runtime)
    case "tail":
      try runTail(values: values)
    default:
      throw ParsedValuesError.invalidOption("action")
    }
  }

  private static func runValidate(values: ParsedValues, runtime: RuntimeOptions) throws {
    let config = try values.optionRequired("config")
    let rules = try RuleLoader.load(path: config)
    try validateExecutables(rules)
    if runtime.jsonOutput {
      try JSONLines.printObject([
        "ok": true,
        "rules": rules.rules.map { $0.name },
      ])
    } else {
      StdoutWriter.writeLine("ok: \(rules.rules.count) rule(s) in \(config)")
    }
  }

  private static func runList(values: ParsedValues, runtime: RuntimeOptions) async throws {
    let state = try await openState(values: values)
    let fires = try await state.listFires(limit: values.optionInt("limit") ?? 50)
    let rules = try values.option("config").map { try RuleLoader.load(path: $0) }
    if runtime.jsonOutput {
      try JSONLines.printObject([
        "rules": rules?.rules.map(ruleObject) ?? [],
        "recent_fires": fires.map(fireObject),
      ])
      return
    }
    if let rules {
      for rule in rules.rules {
        StdoutWriter.writeLine(
          "\(rule.name)\t\(rule.action.rawValue)\t\(rule.enabled ? "enabled" : "disabled")\t\(rule.matchSummary)"
        )
      }
    }
    if !fires.isEmpty {
      if rules != nil { StdoutWriter.writeLine("") }
      StdoutWriter.writeLine("recent fires:")
      for fire in fires {
        StdoutWriter.writeLine(
          "\(CLIISO8601.format(fire.firedAt))\t\(fire.ruleName)\t\(fire.messageGUID)"
        )
      }
    }
  }

  private static func runRules(values: ParsedValues, runtime: RuntimeOptions) async throws {
    let config = try values.optionRequired("config")
    let rules = try RuleLoader.load(path: config)
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let store = try MessageStore(path: dbPath)
    let watcher = MessageWatcher(store: store)
    let state = try await openState(values: values)
    let performer = RulesActionRunner()
    let engine = RulesEngine(state: state, performer: performer)
    let chatID = values.optionInt64("chatID")
    let sinceRowID = try await startingRowID(values: values, state: state, store: store)
    let limit = values.optionInt("limit")
    var seen = 0

    for try await message in watcher.stream(chatID: chatID, sinceRowID: sinceRowID) {
      seen += 1
      let context = try messageContext(message, store: store)
      let invocations = try await engine.process(
        context: context,
        ruleSet: rules,
        dryRun: values.flag("dryRun")
      )
      for invocation in invocations {
        try emit(invocation, runtime: runtime, dryRun: values.flag("dryRun"))
      }
      if let limit, seen >= limit { break }
    }
  }

  private static func runTail(values: ParsedValues) throws {
    let url = RulesActionRunner.defaultLogURL()
    if !FileManager.default.fileExists(atPath: url.path) {
      return
    }
    var offset: UInt64 = 0
    repeat {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      try handle.seek(toOffset: offset)
      let data = handle.readDataToEndOfFile()
      offset = try handle.offset()
      if let text = String(data: data, encoding: .utf8), !text.isEmpty {
        print(text, terminator: "")
      }
      if values.flag("follow") {
        Thread.sleep(forTimeInterval: 1)
      }
    } while values.flag("follow")
  }

  private static func startingRowID(
    values: ParsedValues,
    state: RulesState,
    store: MessageStore
  ) async throws -> Int64? {
    if let since = values.optionInt64("since") { return since }
    if let cursor = try await state.cursor() { return cursor }
    return try store.maxRowID()
  }

  private static func messageContext(_ message: Message, store: MessageStore) throws
    -> RuleMessageContext
  {
    let info = try store.chatInfo(chatID: message.chatID)
    let participants = (try? store.participants(chatID: message.chatID)) ?? []
    return RuleMessageContext(
      message: message,
      chatName: info?.name ?? "",
      chatIdentifier: info?.identifier ?? "",
      chatGUID: info?.guid ?? "",
      isGroup: participants.count > 1
    )
  }

  private static func openState(values: ParsedValues) async throws -> RulesState {
    if let path = values.option("state"), !path.isEmpty {
      return try await RulesState.open(at: URL(fileURLWithPath: path))
    }
    return try await RulesState.openDefault()
  }

  private static func validateExecutables(_ ruleSet: RuleSet) throws {
    let path =
      ProcessInfo.processInfo.environment["PATH"]
      ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
    for rule in ruleSet.rules where rule.action == .exec {
      guard let executable = rule.cmd.first, isExecutable(executable, path: path) else {
        throw RuleConfigError.invalidValue(
          "rule \(rule.name) executable not found: \(rule.cmd.first ?? "")"
        )
      }
    }
  }

  private static func isExecutable(_ command: String, path: String) -> Bool {
    if command.hasPrefix("/") {
      return FileManager.default.isExecutableFile(atPath: command)
    }
    for dir in path.split(separator: ":") {
      if FileManager.default.isExecutableFile(atPath: "\(dir)/\(command)") {
        return true
      }
    }
    return false
  }

  private static func emit(
    _ invocation: RuleActionInvocation,
    runtime: RuntimeOptions,
    dryRun: Bool
  ) throws {
    if runtime.jsonOutput {
      try JSONLines.printObject([
        "dry_run": dryRun,
        "rule": invocation.ruleName,
        "action": invocation.action.rawValue,
        "guid": invocation.messageGUID,
        "chat_id": invocation.chatID,
        "detail": invocation.detail,
      ])
    } else {
      let prefix = dryRun ? "[dry-run] " : ""
      StdoutWriter.writeLine(
        "\(prefix)\(invocation.ruleName) \(invocation.action.rawValue): \(invocation.detail)"
      )
    }
  }

  private static func ruleObject(_ rule: Rule) -> [String: Any] {
    [
      "name": rule.name,
      "action": rule.action.rawValue,
      "enabled": rule.enabled,
      "match": rule.matchSummary,
      "cooldown_seconds": rule.cooldownSeconds,
      "dedupe_window_seconds": rule.dedupeWindowSeconds,
    ]
  }

  private static func fireObject(_ fire: RuleFireRecord) -> [String: Any] {
    [
      "rule": fire.ruleName,
      "message_guid": fire.messageGUID,
      "fired_at": CLIISO8601.format(fire.firedAt),
    ]
  }
}
