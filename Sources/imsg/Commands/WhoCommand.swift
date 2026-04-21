import Commander
import Foundation
import IMsgCore

enum WhoCommand {
  static let spec = CommandSpec(
    name: "who",
    abstract: "Resolve a handle to Contacts metadata (stub)",
    discussion: "See docs/contacts.md. Stub: pending W3.H1.",
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "handle", names: [.long("handle"), .short("H")], help: "Phone or email")
        ]
      )
    ),
    usageExamples: [
      "imsg who --handle +14155551212"
    ]
  ) { _, _ in
    StdoutWriter.writeLine("imsg who: not implemented yet (see TASKS.md W3.H1)")
  }
}
