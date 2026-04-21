import Commander
import Foundation
import IMsgCore

enum OutboxCommand {
  static let spec = CommandSpec(
    name: "outbox",
    abstract: "Queued send with delivery verification (stub)",
    discussion: "See docs/outbox.md. Stub: pending W3.F1.",
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "action", names: [.long("action")], help: "enqueue|list|verify"),
          .make(label: "idempotency-key", names: [.long("idempotency-key")], help: "Unique key"),
        ]
      )
    ),
    usageExamples: [
      "imsg outbox --action list"
    ]
  ) { _, _ in
    StdoutWriter.writeLine("imsg outbox: not implemented yet (see TASKS.md W3.F1)")
  }
}
