import Foundation
import SQLite
import Testing

@testable import IMsgCore

/// Schema helper for reply-parent enrichment tests. Mirrors the
/// reaction-test fixture but includes the optional `thread_originator_guid`
/// column so we can exercise both the Threader-reply path and the
/// non-reaction `associated_message_guid` path.
private enum ReplyContextTestDatabase {
  static func appleEpoch(_ date: Date) -> Int64 {
    let seconds = date.timeIntervalSince1970 - MessageStore.appleEpochOffset
    return Int64(seconds * 1_000_000_000)
  }

  static func makeConnection() throws -> Connection {
    let db = try Connection(.inMemory)
    try db.execute(
      """
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        handle_id INTEGER,
        text TEXT,
        guid TEXT,
        associated_message_guid TEXT,
        associated_message_type INTEGER,
        thread_originator_guid TEXT,
        date INTEGER,
        is_from_me INTEGER,
        service TEXT
      );
      """
    )
    try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
    try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);")
    try db.execute(
      "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);")
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123'), (2, '+456')")
    return db
  }

  static func insertMessage(
    _ db: Connection,
    rowID: Int64,
    handleID: Int64,
    text: String,
    guid: String,
    date: Date,
    isFromMe: Bool = false,
    associatedGuid: String? = nil,
    associatedType: Int? = nil,
    threadOriginatorGuid: String? = nil,
    chatID: Int64 = 1
  ) throws {
    let bindings: [Binding?] = [
      rowID,
      handleID,
      text,
      guid,
      associatedGuid,
      associatedType.map { Int64($0) },
      threadOriginatorGuid,
      appleEpoch(date),
      isFromMe ? Int64(1) : Int64(0),
    ]
    try db.run(
      """
      INSERT INTO message(
        ROWID, handle_id, text, guid,
        associated_message_guid, associated_message_type, thread_originator_guid,
        date, is_from_me, service
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'iMessage')
      """,
      bindings
    )
    try db.run(
      "INSERT INTO chat_message_join(chat_id, message_id) VALUES (?, ?)", chatID, rowID)
  }
}

@Test
func messagesEnrichesThreaderReplyParent() throws {
  let db = try ReplyContextTestDatabase.makeConnection()
  let now = Date()
  try ReplyContextTestDatabase.insertMessage(
    db,
    rowID: 1,
    handleID: 1,
    text: "Should I lead with calendar, family, or email?",
    guid: "parent-guid",
    date: now.addingTimeInterval(-60)
  )
  try ReplyContextTestDatabase.insertMessage(
    db,
    rowID: 2,
    handleID: 2,
    text: "Calendar",
    guid: "reply-guid",
    date: now,
    threadOriginatorGuid: "parent-guid"
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messages(chatID: 1, limit: 10)
  let reply = try #require(messages.first { $0.rowID == 2 })

  #expect(reply.threadOriginatorGUID == "parent-guid")
  #expect(reply.replyToText == "Should I lead with calendar, family, or email?")
  #expect(reply.replyToSender == "+123")
}

@Test
func messagesAfterEnrichesAssociatedReplyParent() throws {
  let db = try ReplyContextTestDatabase.makeConnection()
  let now = Date()
  try ReplyContextTestDatabase.insertMessage(
    db,
    rowID: 1,
    handleID: 1,
    text: "Original photo caption",
    guid: "parent-guid",
    date: now.addingTimeInterval(-60)
  )
  // Sticker / non-reaction association — associated_message_type < 2000.
  try ReplyContextTestDatabase.insertMessage(
    db,
    rowID: 2,
    handleID: 2,
    text: "Cool",
    guid: "reply-guid",
    date: now,
    associatedGuid: "p:0/parent-guid",
    associatedType: 1
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messagesAfter(afterRowID: 0, chatID: 1, limit: 10)
  let reply = try #require(messages.first { $0.rowID == 2 })

  #expect(reply.replyToGUID == "parent-guid")
  #expect(reply.replyToText == "Original photo caption")
  #expect(reply.replyToSender == "+123")
}

@Test
func threadOriginatorWinsWhenBothReplyReferencesExist() throws {
  let db = try ReplyContextTestDatabase.makeConnection()
  let now = Date()
  try ReplyContextTestDatabase.insertMessage(
    db,
    rowID: 1,
    handleID: 1,
    text: "Associated parent",
    guid: "associated-parent",
    date: now.addingTimeInterval(-90)
  )
  try ReplyContextTestDatabase.insertMessage(
    db,
    rowID: 2,
    handleID: 2,
    text: "Thread parent",
    guid: "thread-parent",
    date: now.addingTimeInterval(-60)
  )
  try ReplyContextTestDatabase.insertMessage(
    db,
    rowID: 3,
    handleID: 2,
    text: "Reply",
    guid: "reply-guid",
    date: now,
    associatedGuid: "p:0/associated-parent",
    associatedType: 1,
    threadOriginatorGuid: "thread-parent"
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messagesAfter(afterRowID: 0, chatID: 1, limit: 10)
  let reply = try #require(messages.first { $0.rowID == 3 })

  #expect(reply.replyToGUID == "associated-parent")
  #expect(reply.threadOriginatorGUID == "thread-parent")
  #expect(reply.replyToText == "Thread parent")
  #expect(reply.replyToSender == "+456")
}

@Test
func reactionsDoNotProduceReplyContext() throws {
  let db = try ReplyContextTestDatabase.makeConnection()
  let now = Date()
  try ReplyContextTestDatabase.insertMessage(
    db,
    rowID: 1,
    handleID: 1,
    text: "Original message",
    guid: "parent-guid",
    date: now.addingTimeInterval(-60)
  )
  // Love reaction. `messages()` filters reactions out entirely; this test
  // confirms reactions reaching `messagesAfter(includeReactions: true)`
  // don't get flagged as a reply.
  try ReplyContextTestDatabase.insertMessage(
    db,
    rowID: 2,
    handleID: 2,
    text: "",
    guid: "reaction-guid",
    date: now,
    associatedGuid: "p:0/parent-guid",
    associatedType: 2000,
    threadOriginatorGuid: "parent-guid"
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let allMessages = try store.messagesAfter(
    afterRowID: 0, chatID: 1, limit: 10, includeReactions: true)
  let reaction = try #require(allMessages.first { $0.rowID == 2 })

  #expect(reaction.isReaction)
  #expect(reaction.replyToGUID == nil)
  #expect(reaction.threadOriginatorGUID == nil)
  #expect(reaction.replyToText == nil)
  #expect(reaction.replyToSender == nil)
}

@Test
func replyParentMissingFromChatDbLeavesContextNil() throws {
  let db = try ReplyContextTestDatabase.makeConnection()
  let now = Date()
  // Reply references a parent that was purged / never landed locally.
  try ReplyContextTestDatabase.insertMessage(
    db,
    rowID: 1,
    handleID: 2,
    text: "Calendar",
    guid: "reply-guid",
    date: now,
    threadOriginatorGuid: "missing-parent-guid"
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messages(chatID: 1, limit: 10)
  let reply = try #require(messages.first { $0.rowID == 1 })

  #expect(reply.threadOriginatorGUID == "missing-parent-guid")
  #expect(reply.replyToText == nil)
  #expect(reply.replyToSender == nil)
}

@Test
func multipleRepliesShareCachedParent() throws {
  // Two distinct replies pointing at the same parent should both surface
  // the parent's body + sender. The implementation memoizes parent
  // lookups per query loop; this test pins the behavioural contract
  // (two enrichments, identical text/sender) without reaching into the
  // cache directly.
  let db = try ReplyContextTestDatabase.makeConnection()
  let now = Date()
  try ReplyContextTestDatabase.insertMessage(
    db,
    rowID: 1,
    handleID: 1,
    text: "Parent message body",
    guid: "parent-guid",
    date: now.addingTimeInterval(-300)
  )
  try ReplyContextTestDatabase.insertMessage(
    db,
    rowID: 2,
    handleID: 2,
    text: "Reply A",
    guid: "reply-a",
    date: now.addingTimeInterval(-200),
    threadOriginatorGuid: "parent-guid"
  )
  try ReplyContextTestDatabase.insertMessage(
    db,
    rowID: 3,
    handleID: 2,
    text: "Reply B",
    guid: "reply-b",
    date: now.addingTimeInterval(-100),
    threadOriginatorGuid: "parent-guid"
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messages(chatID: 1, limit: 10)
  let replyA = try #require(messages.first { $0.rowID == 2 })
  let replyB = try #require(messages.first { $0.rowID == 3 })

  #expect(replyA.replyToText == "Parent message body")
  #expect(replyA.replyToSender == "+123")
  #expect(replyB.replyToText == "Parent message body")
  #expect(replyB.replyToSender == "+123")
}

@Test
func nonReplyMessagesLeaveContextNil() throws {
  let db = try ReplyContextTestDatabase.makeConnection()
  let now = Date()
  try ReplyContextTestDatabase.insertMessage(
    db,
    rowID: 1,
    handleID: 1,
    text: "Just a regular message",
    guid: "guid-1",
    date: now
  )

  let store = try MessageStore(connection: db, path: ":memory:")
  let messages = try store.messages(chatID: 1, limit: 10)
  let message = try #require(messages.first)

  #expect(message.replyToGUID == nil)
  #expect(message.threadOriginatorGUID == nil)
  #expect(message.replyToText == nil)
  #expect(message.replyToSender == nil)
}
