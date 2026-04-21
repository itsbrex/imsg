import Commander
import Foundation
import IMsgCore

enum McpCommand {
  static let spec = CommandSpec(
    name: "mcp",
    abstract: "Run imsg as a Model Context Protocol stdio server (stub)",
    discussion: "See docs/mcp.md. Stub: pending W3.B1.",
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(options: CommandSignatures.baseOptions())
    ),
    usageExamples: [
      "imsg mcp"
    ]
  ) { _, _ in
    StdoutWriter.writeLine("imsg mcp: not implemented yet (see TASKS.md W3.B1)")
  }
}
