import Foundation
import Testing

@testable import IMsgCore

// MARK: - Fixture helpers

private func fixedDate(_ offset: TimeInterval) -> Date {
  Date(timeIntervalSince1970: 1_700_000_000 + offset)
}

private func temporaryDirectory(_ name: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("imsg-bundle-tests-\(UUID().uuidString)-\(name)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func fixtureSource() -> ExportSource {
  let meta = ExportChatMeta(
    chatId: 42,
    identifier: "iMessage;+;chat123",
    guid: "iMessage;+;chat123",
    displayName: "Lunch Club",
    isGroup: true,
    service: "iMessage"
  )
  let participants = [
    ExportParticipant(
      contactId: "c_0001", handles: ["+15551234567"], displayName: "Alice"),
    ExportParticipant(
      contactId: "c_0002", handles: ["+15559876543"], displayName: nil),
  ]
  let messages = [
    ExportMessage(
      rowid: 200, guid: "g-200", chatId: 42, createdAt: fixedDate(100),
      senderHandle: "+15551234567", senderContactId: "c_0001",
      fromMe: false, text: "hello",
      attachments: [], replyToGuid: nil, service: "iMessage"),
    ExportMessage(
      rowid: 100, guid: "g-100", chatId: 42, createdAt: fixedDate(50),
      senderHandle: nil, senderContactId: nil,
      fromMe: true, text: "earlier",
      attachments: [
        ExportAttachmentRef(filename: "z.jpg", mime: "image/jpeg", bytes: 99),
        ExportAttachmentRef(filename: "a.png", mime: "image/png", bytes: 17),
      ],
      replyToGuid: nil, service: "iMessage"),
  ]
  let reactions = [
    ExportReaction(
      rowid: 300, guid: "r-300", targetGuid: "g-200", action: "added",
      createdAt: fixedDate(150),
      senderHandle: "+15551234567", senderContactId: "c_0001",
      reactionType: "love")
  ]
  return ExportSource(
    meta: meta, participants: participants, messages: messages, reactions: reactions)
}

private func makeWriter() -> BundleWriter {
  BundleWriter(imsgVersion: "test", now: { fixedDate(0) })
}

// MARK: - Tests

@Test
func writerProducesExpectedFiles() throws {
  let dir = try temporaryDirectory("layout")
  let manifest = try makeWriter().write(fixtureSource(), to: dir)
  let fm = FileManager.default
  #expect(fm.fileExists(atPath: dir.appendingPathComponent("manifest.json").path))
  #expect(fm.fileExists(atPath: dir.appendingPathComponent("meta.json").path))
  #expect(fm.fileExists(atPath: dir.appendingPathComponent("participants.json").path))
  #expect(fm.fileExists(atPath: dir.appendingPathComponent("messages.jsonl").path))
  #expect(fm.fileExists(atPath: dir.appendingPathComponent("reactions.jsonl").path))
  #expect(manifest.counts.messages == 2)
  #expect(manifest.counts.reactions == 1)
  #expect(manifest.counts.attachments == 2)
  try? fm.removeItem(at: dir)
}

@Test
func messagesAreOrderedByCreatedAtThenRowid() throws {
  let dir = try temporaryDirectory("order")
  _ = try makeWriter().write(fixtureSource(), to: dir)
  let data = try Data(contentsOf: dir.appendingPathComponent("messages.jsonl"))
  let lines = String(data: data, encoding: .utf8)!.split(separator: "\n").map(String.init)
  #expect(lines.count == 2)
  #expect(lines[0].contains("\"guid\":\"g-100\""))
  #expect(lines[1].contains("\"guid\":\"g-200\""))
  try? FileManager.default.removeItem(at: dir)
}

@Test
func writerIsDeterministicByteForByte() throws {
  let a = try temporaryDirectory("det-a")
  let b = try temporaryDirectory("det-b")
  _ = try makeWriter().write(fixtureSource(), to: a)
  _ = try makeWriter().write(fixtureSource(), to: b)

  for name in [
    "manifest.json", "meta.json", "participants.json", "messages.jsonl", "reactions.jsonl",
  ] {
    let aData = try Data(contentsOf: a.appendingPathComponent(name))
    let bData = try Data(contentsOf: b.appendingPathComponent(name))
    #expect(aData == bData, "expected \(name) to be byte-identical between exports")
  }
  try? FileManager.default.removeItem(at: a)
  try? FileManager.default.removeItem(at: b)
}

@Test
func verifierReportsCleanBundle() throws {
  let dir = try temporaryDirectory("verify-ok")
  _ = try makeWriter().write(fixtureSource(), to: dir)
  let report = try BundleVerifier().verify(directory: dir)
  #expect(report.isClean)
  try? FileManager.default.removeItem(at: dir)
}

@Test
func verifierDetectsHashMismatch() throws {
  let dir = try temporaryDirectory("verify-hash")
  _ = try makeWriter().write(fixtureSource(), to: dir)
  let url = dir.appendingPathComponent("messages.jsonl")
  var data = try Data(contentsOf: url)
  data.append(0x20)  // append a space — sha breaks, also a line-count drift
  try data.write(to: url)
  let report = try BundleVerifier().verify(directory: dir)
  #expect(!report.isClean)
  #expect(report.mismatchedHashes.contains("messages.jsonl"))
  try? FileManager.default.removeItem(at: dir)
}

@Test
func verifierDetectsMissingFile() throws {
  let dir = try temporaryDirectory("verify-missing")
  _ = try makeWriter().write(fixtureSource(), to: dir)
  try FileManager.default.removeItem(at: dir.appendingPathComponent("reactions.jsonl"))
  let report = try BundleVerifier().verify(directory: dir)
  #expect(report.missingFiles.contains("reactions.jsonl"))
  try? FileManager.default.removeItem(at: dir)
}

@Test
func verifierDetectsUnexpectedFile() throws {
  let dir = try temporaryDirectory("verify-extra")
  _ = try makeWriter().write(fixtureSource(), to: dir)
  try "stray".data(using: .utf8)!
    .write(to: dir.appendingPathComponent("stray.txt"))
  let report = try BundleVerifier().verify(directory: dir)
  #expect(report.unexpectedFiles.contains("stray.txt"))
  try? FileManager.default.removeItem(at: dir)
}

@Test
func differReportsEmptyForIdenticalBundles() throws {
  let a = try temporaryDirectory("diff-id-a")
  let b = try temporaryDirectory("diff-id-b")
  _ = try makeWriter().write(fixtureSource(), to: a)
  _ = try makeWriter().write(fixtureSource(), to: b)
  let diff = try BundleDiffer().diff(a, b)
  #expect(diff.isEmpty)
  try? FileManager.default.removeItem(at: a)
  try? FileManager.default.removeItem(at: b)
}

@Test
func differDetectsAddedAndRemovedMessages() throws {
  let a = try temporaryDirectory("diff-add-a")
  let b = try temporaryDirectory("diff-add-b")
  _ = try makeWriter().write(fixtureSource(), to: a)

  let original = fixtureSource()
  let added = ExportMessage(
    rowid: 999, guid: "g-999", chatId: 42, createdAt: fixedDate(500),
    senderHandle: "+15559876543", senderContactId: "c_0002",
    fromMe: false, text: "new message",
    attachments: [], replyToGuid: nil, service: "iMessage"
  )
  let bSource = ExportSource(
    meta: original.meta,
    participants: original.participants,
    messages: (original.messages + [added]).filter { $0.guid != "g-100" },
    reactions: original.reactions
  )
  _ = try makeWriter().write(bSource, to: b)
  let diff = try BundleDiffer().diff(a, b)
  #expect(diff.addedMessages == ["g-999"])
  #expect(diff.removedMessages == ["g-100"])
  try? FileManager.default.removeItem(at: a)
  try? FileManager.default.removeItem(at: b)
}

@Test
func differDetectsEditedMessages() throws {
  let a = try temporaryDirectory("diff-edit-a")
  let b = try temporaryDirectory("diff-edit-b")
  _ = try makeWriter().write(fixtureSource(), to: a)

  let original = fixtureSource()
  let edited = ExportSource(
    meta: original.meta,
    participants: original.participants,
    messages: original.messages.map {
      $0.guid == "g-200"
        ? ExportMessage(
          rowid: $0.rowid, guid: $0.guid, chatId: $0.chatId, createdAt: $0.createdAt,
          senderHandle: $0.senderHandle, senderContactId: $0.senderContactId,
          fromMe: $0.fromMe, text: "HELLO (edited)",
          attachments: $0.attachments, replyToGuid: $0.replyToGuid, service: $0.service)
        : $0
    },
    reactions: original.reactions
  )
  _ = try makeWriter().write(edited, to: b)
  let diff = try BundleDiffer().diff(a, b)
  #expect(diff.editedMessages == ["g-200"])
  try? FileManager.default.removeItem(at: a)
  try? FileManager.default.removeItem(at: b)
}

@Test
func writerRefusesNonEmptyDirectory() throws {
  let dir = try temporaryDirectory("nonempty")
  try "occupied".data(using: .utf8)!.write(to: dir.appendingPathComponent("placeholder.txt"))
  do {
    _ = try makeWriter().write(fixtureSource(), to: dir)
    Issue.record("expected throw")
  } catch let error as BundleError {
    if case .outputDirectoryNotEmpty = error {
      // good
    } else {
      Issue.record("unexpected error: \(error)")
    }
  }
  try? FileManager.default.removeItem(at: dir)
}
