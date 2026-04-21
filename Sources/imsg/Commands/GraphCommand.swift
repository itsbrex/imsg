import Commander
import Foundation
import IMsgCore

enum GraphCommand {
  static let spec = CommandSpec(
    name: "graph",
    abstract: "Export local interaction graph (stub)",
    discussion: "See docs/contacts.md. Stub: pending W3.H1.",
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(options: CommandSignatures.baseOptions())
    ),
    usageExamples: [
      "imsg graph --json"
    ]
  ) { _, _ in
    StdoutWriter.writeLine("imsg graph: not implemented yet (see TASKS.md W3.H1)")
  }
}
