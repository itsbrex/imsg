import Commander
import Foundation
import IMsgCore

enum RulesCommand {
  static let spec = CommandSpec(
    name: "rules",
    abstract: "Run a rules file against the watch stream (stub)",
    discussion: "See docs/rules.md. Stub: pending W3.E1.",
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "config", names: [.long("config"), .short("c")], help: "Rules config path"),
          .make(
            label: "dry-run", names: [.long("dry-run")], help: "Log actions without executing"),
        ]
      )
    ),
    usageExamples: [
      "imsg rules run --config ~/.config/imsg/rules.toml --dry-run"
    ]
  ) { _, _ in
    StdoutWriter.writeLine("imsg rules: not implemented yet (see TASKS.md W3.E1)")
  }
}
