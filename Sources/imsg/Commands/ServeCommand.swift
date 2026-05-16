import Commander
import Foundation
import IMsgCore

enum ServeCommand {
  static let spec = CommandSpec(
    name: "serve",
    abstract: "Long-lived socket server with multi-client fanout (stub)",
    discussion: "See docs/serve.md. Stub: pending W3.C1.",
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "socket", names: [.long("socket")], help: "Unix socket path")
        ]
      )
    ),
    usageExamples: [
      "imsg serve --socket /tmp/imsg.sock"
    ]
  ) { _, _ in
    StdoutWriter.writeLine("imsg serve: not implemented yet (see TASKS.md W3.C1)")
  }
}
