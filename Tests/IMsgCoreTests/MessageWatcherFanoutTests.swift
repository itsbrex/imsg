import Foundation
import SQLite
import Testing

@testable import IMsgCore

private struct FanoutFixture {
  let store: MessageStore
  let insertMessage: (Int64, String) throws -> Void
}

private enum FanoutDatabase {
  static func appleEpoch(_ date: Date) -> Int64 {
    let seconds = date.timeIntervalSince1970 - MessageStore.appleEpochOffset
    return Int64(seconds * 1_000_000_000)
  }

  static func make() throws -> FanoutFixture {
    let db = try Connection(.inMemory)
    try db.execute(
      """
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        handle_id INTEGER,
        text TEXT,
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
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+555')")

    let store = try MessageStore(
      connection: db, path: ":memory:", hasAttributedBody: false, hasReactionColumns: false)
    return FanoutFixture(
      store: store,
      insertMessage: { rowID, text in
        try store.withConnection { db in
          try db.run(
            """
            INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
            VALUES (?, 1, ?, ?, 0, 'iMessage')
            """,
            rowID,
            text,
            appleEpoch(Date())
          )
          try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, ?)", rowID)
        }
      }
    )
  }
}

@Test
func twoSubscribersEachReceiveEveryRowExactlyOnce() async throws {
  let fixture = try FanoutDatabase.make()
  let watcher = MessageWatcher(store: fixture.store)
  let config = MessageWatcherConfiguration(
    debounceInterval: 0.01,
    fallbackPollInterval: 0.01,
    batchLimit: 10
  )

  let streamA = watcher.stream(chatID: nil, sinceRowID: -1, configuration: config)
  let streamB = watcher.stream(chatID: nil, sinceRowID: -1, configuration: config)

  let taskA = Task { () -> [Int64] in
    var seen: [Int64] = []
    for try await message in streamA {
      seen.append(message.rowID)
      if seen.count == 3 { break }
    }
    return seen
  }
  let taskB = Task { () -> [Int64] in
    var seen: [Int64] = []
    for try await message in streamB {
      seen.append(message.rowID)
      if seen.count == 3 { break }
    }
    return seen
  }

  try await Task.sleep(nanoseconds: 30_000_000)
  try fixture.insertMessage(1, "one")
  try await Task.sleep(nanoseconds: 30_000_000)
  try fixture.insertMessage(2, "two")
  try await Task.sleep(nanoseconds: 30_000_000)
  try fixture.insertMessage(3, "three")

  let seenA = try await taskA.value
  let seenB = try await taskB.value
  #expect(seenA == [1, 2, 3])
  #expect(seenB == [1, 2, 3])
}

@Test
func cancellingOneSubscriberDoesNotAffectAnother() async throws {
  let fixture = try FanoutDatabase.make()
  let watcher = MessageWatcher(store: fixture.store)
  let config = MessageWatcherConfiguration(
    debounceInterval: 0.01,
    fallbackPollInterval: 0.01,
    batchLimit: 10
  )

  let streamA = watcher.stream(chatID: nil, sinceRowID: -1, configuration: config)
  let streamB = watcher.stream(chatID: nil, sinceRowID: -1, configuration: config)

  // A consumes one message, then cancels.
  let taskA = Task { () -> Int64? in
    var iterator = streamA.makeAsyncIterator()
    let first = try await iterator.next()
    return first?.rowID
  }
  let taskB = Task { () -> [Int64] in
    var seen: [Int64] = []
    for try await message in streamB {
      seen.append(message.rowID)
      if seen.count == 2 { break }
    }
    return seen
  }

  try await Task.sleep(nanoseconds: 30_000_000)
  try fixture.insertMessage(10, "alpha")
  let firstA = try await taskA.value
  #expect(firstA == 10)

  // After A has finished, B should still receive subsequent messages.
  try await Task.sleep(nanoseconds: 30_000_000)
  try fixture.insertMessage(11, "beta")

  let seenB = try await taskB.value
  #expect(seenB == [10, 11])
}

@Test
func perSubscriberChatFilterIsIndependent() async throws {
  let fixture = try FanoutDatabase.make()
  // Add a second chat_message_join target so chat-filtered subscribers diverge.
  try fixture.store.withConnection { db in
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
      VALUES (100, 1, 'chat-one', ?, 0, 'iMessage')
      """,
      FanoutDatabase.appleEpoch(Date())
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 100)")
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
      VALUES (101, 1, 'chat-two', ?, 0, 'iMessage')
      """,
      FanoutDatabase.appleEpoch(Date())
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (2, 101)")
  }

  let watcher = MessageWatcher(store: fixture.store)
  let config = MessageWatcherConfiguration(
    debounceInterval: 0.01,
    fallbackPollInterval: 0.01,
    batchLimit: 10
  )

  let streamOne = watcher.stream(chatID: 1, sinceRowID: -1, configuration: config)
  let streamTwo = watcher.stream(chatID: 2, sinceRowID: -1, configuration: config)

  let taskOne = Task { () -> Int64? in
    var iterator = streamOne.makeAsyncIterator()
    return try await iterator.next()?.rowID
  }
  let taskTwo = Task { () -> Int64? in
    var iterator = streamTwo.makeAsyncIterator()
    return try await iterator.next()?.rowID
  }

  let rowOne = try await taskOne.value
  let rowTwo = try await taskTwo.value
  #expect(rowOne == 100)
  #expect(rowTwo == 101)
}
