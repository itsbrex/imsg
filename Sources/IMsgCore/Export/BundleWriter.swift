import Foundation

// MARK: - Source data passed to the writer
//
// The writer takes already-fetched data so it can be unit-tested without
// a real `MessageStore`. The `imsg export` command is responsible for
// gathering this from the store and passing it in.

public struct ExportChatMeta: Equatable, Sendable {
  public let chatId: Int64
  public let identifier: String
  public let guid: String
  public let displayName: String?
  public let isGroup: Bool
  public let service: String

  public init(
    chatId: Int64,
    identifier: String,
    guid: String,
    displayName: String?,
    isGroup: Bool,
    service: String
  ) {
    self.chatId = chatId
    self.identifier = identifier
    self.guid = guid
    self.displayName = displayName
    self.isGroup = isGroup
    self.service = service
  }
}

public struct ExportParticipant: Equatable, Sendable {
  public let contactId: String
  public let handles: [String]
  public let displayName: String?

  public init(contactId: String, handles: [String], displayName: String?) {
    self.contactId = contactId
    self.handles = handles
    self.displayName = displayName
  }
}

public struct ExportAttachmentRef: Equatable, Sendable {
  public let filename: String
  public let mime: String
  public let bytes: Int64

  public init(filename: String, mime: String, bytes: Int64) {
    self.filename = filename
    self.mime = mime
    self.bytes = bytes
  }
}

public struct ExportMessage: Equatable, Sendable {
  public let rowid: Int64
  public let guid: String
  public let chatId: Int64
  public let createdAt: Date
  public let senderHandle: String?
  public let senderContactId: String?
  public let fromMe: Bool
  public let text: String?
  public let attachments: [ExportAttachmentRef]
  public let replyToGuid: String?
  public let service: String

  public init(
    rowid: Int64,
    guid: String,
    chatId: Int64,
    createdAt: Date,
    senderHandle: String?,
    senderContactId: String?,
    fromMe: Bool,
    text: String?,
    attachments: [ExportAttachmentRef],
    replyToGuid: String?,
    service: String
  ) {
    self.rowid = rowid
    self.guid = guid
    self.chatId = chatId
    self.createdAt = createdAt
    self.senderHandle = senderHandle
    self.senderContactId = senderContactId
    self.fromMe = fromMe
    self.text = text
    self.attachments = attachments
    self.replyToGuid = replyToGuid
    self.service = service
  }
}

public struct ExportReaction: Equatable, Sendable {
  public let rowid: Int64
  public let guid: String
  public let targetGuid: String
  public let action: String  // "added" | "removed"
  public let createdAt: Date
  public let senderHandle: String?
  public let senderContactId: String?
  public let reactionType: String

  public init(
    rowid: Int64,
    guid: String,
    targetGuid: String,
    action: String,
    createdAt: Date,
    senderHandle: String?,
    senderContactId: String?,
    reactionType: String
  ) {
    self.rowid = rowid
    self.guid = guid
    self.targetGuid = targetGuid
    self.action = action
    self.createdAt = createdAt
    self.senderHandle = senderHandle
    self.senderContactId = senderContactId
    self.reactionType = reactionType
  }
}

public struct ExportSource: Equatable, Sendable {
  public let meta: ExportChatMeta
  public let participants: [ExportParticipant]
  public let messages: [ExportMessage]
  public let reactions: [ExportReaction]

  public init(
    meta: ExportChatMeta,
    participants: [ExportParticipant],
    messages: [ExportMessage],
    reactions: [ExportReaction]
  ) {
    self.meta = meta
    self.participants = participants
    self.messages = messages
    self.reactions = reactions
  }
}

// MARK: - Writer

public struct BundleWriter {
  public static let schemaVersion = "v1"

  private let imsgVersion: String
  private let now: @Sendable () -> Date

  public init(
    imsgVersion: String,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.imsgVersion = imsgVersion
    self.now = now
  }

  /// Write a bundle to `directory`. The directory must either not exist
  /// or be empty. Returns the serialized manifest.
  @discardableResult
  public func write(_ source: ExportSource, to directory: URL) throws -> BundleManifest {
    let fm = FileManager.default
    if fm.fileExists(atPath: directory.path) {
      let entries = try fm.contentsOfDirectory(atPath: directory.path)
      if !entries.isEmpty {
        throw BundleError.outputDirectoryNotEmpty(directory.path)
      }
    } else {
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    let sortedMessages = source.messages.sorted {
      if $0.createdAt == $1.createdAt { return $0.rowid < $1.rowid }
      return $0.createdAt < $1.createdAt
    }
    let sortedReactions = source.reactions.sorted {
      if $0.createdAt == $1.createdAt { return $0.rowid < $1.rowid }
      return $0.createdAt < $1.createdAt
    }
    let sortedParticipants = source.participants.sorted { $0.contactId < $1.contactId }

    let metaData = try jsonPretty(metaPayload(source.meta))
    let participantsData = try jsonPretty(participantsPayload(sortedParticipants))
    let messagesData = try jsonLines(sortedMessages.map(messagePayload(_:)))
    let reactionsData = try jsonLines(sortedReactions.map(reactionPayload(_:)))

    try metaData.write(to: directory.appendingPathComponent("meta.json"))
    try participantsData.write(to: directory.appendingPathComponent("participants.json"))
    try messagesData.write(to: directory.appendingPathComponent("messages.jsonl"))
    try reactionsData.write(to: directory.appendingPathComponent("reactions.jsonl"))

    let attachmentCount = sortedMessages.reduce(0) { $0 + $1.attachments.count }

    let hashes: [String: String] = [
      "meta.json": BundleHasher.sha256Hex(metaData),
      "participants.json": BundleHasher.sha256Hex(participantsData),
      "messages.jsonl": BundleHasher.sha256Hex(messagesData),
      "reactions.jsonl": BundleHasher.sha256Hex(reactionsData),
    ]

    let manifest = BundleManifest(
      schema: BundleWriter.schemaVersion,
      createdAt: BundleWriter.iso8601(now()),
      imsgVersion: imsgVersion,
      source: BundleSource(chatId: source.meta.chatId, guid: source.meta.guid),
      counts: BundleCounts(
        messages: sortedMessages.count,
        attachments: attachmentCount,
        reactions: sortedReactions.count
      ),
      hashes: hashes
    )

    let manifestData = try jsonPretty(manifestPayload(manifest))
    try manifestData.write(to: directory.appendingPathComponent("manifest.json"))
    return manifest
  }

  // MARK: - Payload builders

  private func metaPayload(_ meta: ExportChatMeta) -> [String: Any] {
    return [
      "chat_id": meta.chatId,
      "identifier": meta.identifier,
      "guid": meta.guid,
      "display_name": meta.displayName as Any? ?? NSNull(),
      "is_group": meta.isGroup,
      "service": meta.service,
    ]
  }

  private func participantsPayload(_ participants: [ExportParticipant]) -> [String: Any] {
    return [
      "participants": participants.map { p in
        [
          "contact_id": p.contactId,
          "handles": p.handles.sorted(),
          "display_name": p.displayName as Any? ?? NSNull(),
        ] as [String: Any]
      }
    ]
  }

  private func messagePayload(_ message: ExportMessage) -> [String: Any] {
    let attachments = message.attachments.sorted { $0.filename < $1.filename }.map { a in
      [
        "filename": a.filename,
        "mime": a.mime,
        "bytes": a.bytes,
      ] as [String: Any]
    }
    let sender: [String: Any] = [
      "contact_id": message.senderContactId as Any? ?? NSNull(),
      "handle": message.senderHandle as Any? ?? NSNull(),
    ]
    return [
      "schema": BundleWriter.schemaVersion,
      "type": "message",
      "id": [
        "guid": message.guid,
        "rowid": message.rowid,
      ] as [String: Any],
      "chat_id": message.chatId,
      "created_at": BundleWriter.iso8601(message.createdAt),
      "from_me": message.fromMe,
      "sender": sender,
      "text": message.text as Any? ?? NSNull(),
      "attachments": attachments,
      "reply_to": message.replyToGuid as Any? ?? NSNull(),
      "service": message.service,
    ]
  }

  private func reactionPayload(_ reaction: ExportReaction) -> [String: Any] {
    return [
      "schema": BundleWriter.schemaVersion,
      "type": "reaction",
      "id": [
        "guid": reaction.guid,
        "rowid": reaction.rowid,
      ] as [String: Any],
      "target_guid": reaction.targetGuid,
      "action": reaction.action,
      "created_at": BundleWriter.iso8601(reaction.createdAt),
      "sender": [
        "contact_id": reaction.senderContactId as Any? ?? NSNull(),
        "handle": reaction.senderHandle as Any? ?? NSNull(),
      ] as [String: Any],
      "reaction_type": reaction.reactionType,
    ]
  }

  private func manifestPayload(_ manifest: BundleManifest) -> [String: Any] {
    return [
      "schema": manifest.schema,
      "created_at": manifest.createdAt,
      "imsg_version": manifest.imsgVersion,
      "source": [
        "chat_id": manifest.source.chatId,
        "guid": manifest.source.guid,
      ] as [String: Any],
      "counts": [
        "messages": manifest.counts.messages,
        "attachments": manifest.counts.attachments,
        "reactions": manifest.counts.reactions,
      ] as [String: Any],
      "hashes": manifest.hashes,
      "redactions": manifest.redactions,
    ]
  }

  // MARK: - Serialization

  private func jsonPretty(_ object: Any) throws -> Data {
    var data = try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    )
    // Pretty output already has no trailing newline. Spec requires one.
    data.append(0x0A)
    return data
  }

  private func jsonLines(_ objects: [Any]) throws -> Data {
    var out = Data()
    for object in objects {
      let line = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
      )
      out.append(line)
      out.append(0x0A)
    }
    return out
  }

  // MARK: - Time

  /// ISO-8601 UTC with `Z` suffix; second precision unless the date
  /// carries non-zero subsecond resolution, in which case three
  /// fractional digits.
  static func iso8601(_ date: Date) -> String {
    let interval = date.timeIntervalSince1970
    let whole = floor(interval)
    let fractional = interval - whole
    let millis = Int((fractional * 1000).rounded())

    let formatter: DateFormatter = {
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.timeZone = TimeZone(secondsFromGMT: 0)
      return f
    }()

    if millis == 0 {
      formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
      return formatter.string(from: Date(timeIntervalSince1970: whole))
    } else {
      formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
      let base = formatter.string(from: Date(timeIntervalSince1970: whole))
      return String(format: "%@.%03dZ", base, millis)
    }
  }
}

// MARK: - Errors

public enum BundleError: Error, Equatable, Sendable {
  case outputDirectoryNotEmpty(String)
  case missingManifest(String)
  case malformedManifest(String)
  case hashMismatch(path: String, expected: String, actual: String)
  case missingFile(path: String)
  case unexpectedFile(path: String)
  case countMismatch(field: String, expected: Int, actual: Int)
}
