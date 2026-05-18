import Commander
import Foundation
import IMsgCore

enum ExportCommand {
  static let spec = CommandSpec(
    name: "export",
    abstract: "Export a chat as a portable bundle, or verify/diff an existing bundle",
    discussion: """
      Subcommands are selected with --action:
        --action=export   (default)  write a new bundle to --out
        --action=verify              recompute hashes and counts in --in
        --action=diff                compare --in against --other
      See docs/export.md.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "action", names: [.long("action")], help: "export | verify | diff"),
          .make(label: "chatID", names: [.long("chat-id")], help: "Chat ROWID"),
          .make(label: "out", names: [.long("out"), .short("o")], help: "Output directory"),
          .make(label: "in", names: [.long("in")], help: "Input bundle directory"),
          .make(label: "other", names: [.long("other")], help: "Second bundle for --action=diff"),
        ]
      )
    ),
    usageExamples: [
      "imsg export --chat-id 1 --out ./bundle",
      "imsg export --action=verify --in ./bundle",
      "imsg export --action=diff --in ./a --other ./b",
    ]
  ) { values, runtime in
    let action = values.option("action") ?? "export"
    switch action {
    case "export":
      try await runExport(values: values, runtime: runtime)
    case "verify":
      try runVerify(values: values, runtime: runtime)
    case "diff":
      try runDiff(values: values, runtime: runtime)
    default:
      throw ParsedValuesError.invalidOption("action")
    }
  }

  // MARK: - export

  private static func runExport(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let chatID = values.optionInt64("chatID") else {
      throw ParsedValuesError.missingOption("chat-id")
    }
    guard let out = values.option("out") else {
      throw ParsedValuesError.missingOption("out")
    }
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let store = try MessageStore(path: dbPath)
    let source = try gatherExportSource(store: store, chatID: chatID)
    let writer = BundleWriter(imsgVersion: IMsgVersion.current)
    let manifest = try writer.write(source, to: URL(fileURLWithPath: out))
    if runtime.jsonOutput {
      try JSONLines.printObject([
        "status": "ok",
        "chat_id": manifest.source.chatId,
        "messages": manifest.counts.messages,
        "reactions": manifest.counts.reactions,
        "out": out,
      ])
    } else {
      StdoutWriter.writeLine(
        "exported chat \(chatID) (\(manifest.counts.messages) messages, "
          + "\(manifest.counts.reactions) reactions) -> \(out)"
      )
    }
  }

  // MARK: - verify

  private static func runVerify(values: ParsedValues, runtime: RuntimeOptions) throws {
    guard let path = values.option("in") else {
      throw ParsedValuesError.missingOption("in")
    }
    let report = try BundleVerifier().verify(directory: URL(fileURLWithPath: path))
    if runtime.jsonOutput {
      try JSONLines.printObject([
        "clean": report.isClean,
        "mismatched_hashes": report.mismatchedHashes,
        "missing_files": report.missingFiles,
        "unexpected_files": report.unexpectedFiles,
        "count_deltas": report.countDeltas,
      ])
    } else if report.isClean {
      StdoutWriter.writeLine("ok: bundle \(path) verifies clean")
    } else {
      StdoutWriter.writeLine("drift detected in \(path):")
      for entry in report.mismatchedHashes { StdoutWriter.writeLine("  hash mismatch: \(entry)") }
      for entry in report.missingFiles { StdoutWriter.writeLine("  missing: \(entry)") }
      for entry in report.unexpectedFiles { StdoutWriter.writeLine("  unexpected: \(entry)") }
      for entry in report.countDeltas { StdoutWriter.writeLine("  count: \(entry)") }
    }
    if !report.isClean {
      throw CommandOutputEmittedError()
    }
  }

  // MARK: - diff

  private static func runDiff(values: ParsedValues, runtime: RuntimeOptions) throws {
    guard let lhs = values.option("in") else { throw ParsedValuesError.missingOption("in") }
    guard let rhs = values.option("other") else { throw ParsedValuesError.missingOption("other") }
    let diff = try BundleDiffer().diff(URL(fileURLWithPath: lhs), URL(fileURLWithPath: rhs))
    if runtime.jsonOutput {
      try JSONLines.printObject([
        "equivalent": diff.isEmpty,
        "added": diff.addedMessages,
        "removed": diff.removedMessages,
        "edited": diff.editedMessages,
        "reactions_delta": diff.reactionDelta,
      ])
    } else if diff.isEmpty {
      StdoutWriter.writeLine("equivalent")
    } else {
      StdoutWriter.writeLine("differences:")
      for guid in diff.addedMessages { StdoutWriter.writeLine("  + \(guid)") }
      for guid in diff.removedMessages { StdoutWriter.writeLine("  - \(guid)") }
      for guid in diff.editedMessages { StdoutWriter.writeLine("  ~ \(guid)") }
      for entry in diff.reactionDelta { StdoutWriter.writeLine("  r \(entry)") }
    }
    if !diff.isEmpty {
      throw CommandOutputEmittedError()
    }
  }

  // MARK: - gathering

  private static func gatherExportSource(store: MessageStore, chatID: Int64) throws -> ExportSource
  {
    guard let chatInfo = try store.chatInfo(chatID: chatID) else {
      throw NSError(
        domain: "imsg.export", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "chat \(chatID) not found"]
      )
    }
    let participantsRaw = try store.participants(chatID: chatID)
    let participants: [ExportParticipant] = participantsRaw.enumerated().map { index, handle in
      ExportParticipant(
        contactId: String(format: "c_%04d", index + 1),
        handles: [handle],
        displayName: nil
      )
    }

    let limit = 1_000_000  // pull everything; bundles are not paginated in v1
    let messagesRaw = try store.messages(chatID: chatID, limit: limit)
    var messages: [ExportMessage] = []
    var reactions: [ExportReaction] = []
    for row in messagesRaw {
      if row.isReaction {
        if let reactedTo = row.reactedToGUID, let reactionType = row.reactionType {
          reactions.append(
            ExportReaction(
              rowid: row.rowID,
              guid: row.guid,
              targetGuid: reactedTo,
              action: (row.isReactionAdd ?? true) ? "added" : "removed",
              createdAt: row.date,
              senderHandle: row.isFromMe ? nil : row.sender,
              senderContactId: nil,
              reactionType: reactionType.name
            )
          )
        }
        continue
      }
      let attachmentMetas = (try? store.attachments(for: row.rowID)) ?? []
      let attachments = attachmentMetas.map {
        ExportAttachmentRef(
          filename: $0.transferName.isEmpty ? $0.filename : $0.transferName,
          mime: $0.mimeType,
          bytes: $0.totalBytes
        )
      }
      messages.append(
        ExportMessage(
          rowid: row.rowID,
          guid: row.guid,
          chatId: row.chatID,
          createdAt: row.date,
          senderHandle: row.isFromMe ? nil : row.sender,
          senderContactId: nil,
          fromMe: row.isFromMe,
          text: row.text.isEmpty ? nil : row.text,
          attachments: attachments,
          replyToGuid: row.replyToGUID,
          service: row.service
        )
      )
    }

    return ExportSource(
      meta: ExportChatMeta(
        chatId: chatInfo.id,
        identifier: chatInfo.identifier,
        guid: chatInfo.guid,
        displayName: chatInfo.name.isEmpty ? nil : chatInfo.name,
        isGroup: participantsRaw.count > 1,
        service: chatInfo.service
      ),
      participants: participants,
      messages: messages,
      reactions: reactions
    )
  }
}
