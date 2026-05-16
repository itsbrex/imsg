import Commander
import Foundation
import IMsgCore

enum ComposeCommand {
  static let spec = CommandSpec(
    name: "compose",
    abstract: "Draft a reply using a pluggable LLM provider (stub)",
    discussion: "See docs/compose.md. Stub: pending W3.I1.",
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat-id", names: [.long("chat-id")], help: "Chat ROWID"),
          .make(label: "prompt", names: [.long("prompt")], help: "Prompt text or '-' for stdin"),
          .make(
            label: "send", names: [.long("send")], help: "Send the draft immediately (default: off)"
          ),
        ]
      )
    ),
    usageExamples: [
      "imsg compose --chat-id 1 --prompt 'nudge about dinner'"
    ]
  ) { _, _ in
    StdoutWriter.writeLine("imsg compose: not implemented yet (see TASKS.md W3.I1)")
  }
}
