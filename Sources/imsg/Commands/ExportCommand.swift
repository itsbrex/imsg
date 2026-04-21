import Commander
import Foundation
import IMsgCore

enum ExportCommand {
  static let spec = CommandSpec(
    name: "export",
    abstract: "Export a chat as a portable bundle (stub)",
    discussion: "See docs/export.md. Stub: pending W3.J1.",
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat-id", names: [.long("chat-id")], help: "Chat ROWID"),
          .make(label: "out", names: [.long("out"), .short("o")], help: "Output directory"),
        ]
      )
    ),
    usageExamples: [
      "imsg export --chat-id 1 --out ./bundle"
    ]
  ) { _, _ in
    StdoutWriter.writeLine("imsg export: not implemented yet (see TASKS.md W3.J1)")
  }
}
