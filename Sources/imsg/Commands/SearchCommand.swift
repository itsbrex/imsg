import Commander
import Foundation
import IMsgCore

enum SearchCommand {
  static let spec = CommandSpec(
    name: "search",
    abstract: "Search message history (FTS5 + embeddings) (stub)",
    discussion: "See docs/search.md. Stub: pending W3.D1.",
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "query", names: [.long("query"), .short("q")], help: "Search query"),
          .make(label: "limit", names: [.long("limit")], help: "Max results"),
        ]
      )
    ),
    usageExamples: [
      "imsg search -q 'dinner plans' --limit 20"
    ]
  ) { _, _ in
    StdoutWriter.writeLine("imsg search: not implemented yet (see TASKS.md W3.D1)")
  }
}
