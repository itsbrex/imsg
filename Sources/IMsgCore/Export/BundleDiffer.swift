import Foundation

public struct BundleDiff: Equatable, Sendable {
  public var addedMessages: [String]
  public var removedMessages: [String]
  public var editedMessages: [String]
  public var reactionDelta: [String]

  public init(
    addedMessages: [String] = [],
    removedMessages: [String] = [],
    editedMessages: [String] = [],
    reactionDelta: [String] = []
  ) {
    self.addedMessages = addedMessages
    self.removedMessages = removedMessages
    self.editedMessages = editedMessages
    self.reactionDelta = reactionDelta
  }

  public var isEmpty: Bool {
    addedMessages.isEmpty && removedMessages.isEmpty
      && editedMessages.isEmpty && reactionDelta.isEmpty
  }
}

public struct BundleDiffer {
  public init() {}

  public func diff(_ a: URL, _ b: URL) throws -> BundleDiff {
    let messagesA = try loadMessages(a)
    let messagesB = try loadMessages(b)
    let reactionsA = try loadReactions(a)
    let reactionsB = try loadReactions(b)

    let aGuids = Set(messagesA.keys)
    let bGuids = Set(messagesB.keys)
    let added = bGuids.subtracting(aGuids).sorted()
    let removed = aGuids.subtracting(bGuids).sorted()

    var edited: [String] = []
    for guid in aGuids.intersection(bGuids).sorted() {
      if let lhs = messagesA[guid], let rhs = messagesB[guid], !messagesEquivalent(lhs, rhs) {
        edited.append(guid)
      }
    }

    let reactionDelta = symmetricReactionDifference(reactionsA, reactionsB)

    return BundleDiff(
      addedMessages: added,
      removedMessages: removed,
      editedMessages: edited,
      reactionDelta: reactionDelta
    )
  }

  // MARK: - Loading

  private func loadMessages(_ directory: URL) throws -> [String: [String: Any]] {
    let url = directory.appendingPathComponent("messages.jsonl")
    return try loadKeyedJSONLines(url, keyOf: messageGuid(_:))
  }

  private func loadReactions(_ directory: URL) throws -> [String: [String: Any]] {
    let url = directory.appendingPathComponent("reactions.jsonl")
    return try loadKeyedJSONLines(url, keyOf: reactionKey(_:))
  }

  private func loadKeyedJSONLines(
    _ url: URL,
    keyOf: ([String: Any]) -> String?
  ) throws -> [String: [String: Any]] {
    var out: [String: [String: Any]] = [:]
    guard FileManager.default.fileExists(atPath: url.path) else { return out }
    let data = try Data(contentsOf: url)
    for chunk in data.split(separator: 0x0A) where !chunk.isEmpty {
      if let object = try JSONSerialization.jsonObject(with: Data(chunk)) as? [String: Any],
        let key = keyOf(object)
      {
        out[key] = object
      }
    }
    return out
  }

  private func messageGuid(_ object: [String: Any]) -> String? {
    if let id = object["id"] as? [String: Any], let guid = id["guid"] as? String {
      return guid
    }
    return nil
  }

  private func reactionKey(_ object: [String: Any]) -> String? {
    // Reactions are keyed by (target_guid, action, sender) so that
    // tapback additions and removals diff symmetrically.
    guard let target = object["target_guid"] as? String,
      let action = object["action"] as? String
    else { return nil }
    let sender = (object["sender"] as? [String: Any])?["handle"] as? String ?? ""
    let type = object["reaction_type"] as? String ?? ""
    return "\(target)|\(action)|\(sender)|\(type)"
  }

  // MARK: - Equivalence

  private func messagesEquivalent(_ a: [String: Any], _ b: [String: Any]) -> Bool {
    // Compare text and attachment set. Other fields (created_at, rowid,
    // sender) are intentionally not part of edit detection so that a
    // bundle re-exported on a different machine doesn't flag every row.
    let textA = a["text"] as? String
    let textB = b["text"] as? String
    if textA != textB { return false }

    let attachmentsA = signature(of: a["attachments"] as? [[String: Any]] ?? [])
    let attachmentsB = signature(of: b["attachments"] as? [[String: Any]] ?? [])
    return attachmentsA == attachmentsB
  }

  private func signature(of attachments: [[String: Any]]) -> [String] {
    attachments
      .compactMap { entry -> String? in
        guard let filename = entry["filename"] as? String,
          let mime = entry["mime"] as? String,
          let bytes = entry["bytes"] as? NSNumber
        else { return nil }
        return "\(filename)|\(mime)|\(bytes.int64Value)"
      }
      .sorted()
  }

  private func symmetricReactionDifference(
    _ a: [String: [String: Any]],
    _ b: [String: [String: Any]]
  ) -> [String] {
    let only = Set(a.keys).symmetricDifference(Set(b.keys))
    return only.sorted()
  }
}
