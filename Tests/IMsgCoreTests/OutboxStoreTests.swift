import Foundation
import XCTest

@testable import IMsgCore

final class OutboxStoreTests: XCTestCase {
  private func makeTempStoreURL() -> URL {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp.appendingPathComponent("outbox.sqlite")
  }

  func testEnqueueInsertsRowAndDedupesByIdempotency() async throws {
    let store = try await OutboxStore.open(at: makeTempStoreURL())
    let item = OutboxItem(recipient: .handle("+15551234567"), text: "hi", service: "iMessage")
    let first = try await store.enqueue(item)
    XCTAssertEqual(first.state, OutboxState.queued.rawValue)
    XCTAssertEqual(first.toHandle, "+15551234567")
    XCTAssertEqual(first.attempts, 0)

    // Same payload, same derived key -> same row.
    let second = try await store.enqueue(item)
    XCTAssertEqual(first.id, second.id)
    XCTAssertEqual(first.idempotencyKey, second.idempotencyKey)

    // Explicit unique key bypasses dedupe.
    let custom = OutboxItem(
      recipient: .handle("+15551234567"), text: "hi", service: "iMessage",
      idempotencyKey: "explicit-key"
    )
    let third = try await store.enqueue(custom)
    XCTAssertNotEqual(first.id, third.id)
    XCTAssertEqual(third.idempotencyKey, "explicit-key")
  }

  func testStateTransitionsQueuedSendingSentVerified() async throws {
    let store = try await OutboxStore.open(at: makeTempStoreURL())
    let row = try await store.enqueue(
      OutboxItem(recipient: .handle("+15551234567"), text: "hello", service: "iMessage")
    )

    try await store.markSending(id: row.id)
    let sending = try await store.get(id: row.id)
    XCTAssertEqual(sending?.state, OutboxState.sending.rawValue)
    XCTAssertEqual(sending?.attempts, 1)

    try await store.markSent(id: row.id)
    let sent = try await store.get(id: row.id)
    XCTAssertEqual(sent?.state, OutboxState.sent.rawValue)

    try await store.markVerified(id: row.id, verifiedGUID: "ABC", verifiedRowid: 42)
    let verified = try await store.get(id: row.id)
    XCTAssertEqual(verified?.state, OutboxState.verified.rawValue)
    XCTAssertEqual(verified?.verifiedGUID, "ABC")
    XCTAssertEqual(verified?.verifiedRowid, 42)
  }

  func testListFiltersByState() async throws {
    let store = try await OutboxStore.open(at: makeTempStoreURL())
    _ = try await store.enqueue(
      OutboxItem(recipient: .handle("a@test"), text: "one", service: "iMessage"))
    let two = try await store.enqueue(
      OutboxItem(recipient: .handle("b@test"), text: "two", service: "iMessage"))
    try await store.markSending(id: two.id)
    try await store.markSent(id: two.id)

    let queued = try await store.list(state: OutboxState.queued.rawValue, limit: 10)
    XCTAssertEqual(queued.count, 1)
    XCTAssertEqual(queued.first?.toHandle, "a@test")

    let sent = try await store.list(state: OutboxState.sent.rawValue, limit: 10)
    XCTAssertEqual(sent.count, 1)
    XCTAssertEqual(sent.first?.toHandle, "b@test")
  }

  func testEventLogAppendsOnEachTransition() async throws {
    let store = try await OutboxStore.open(at: makeTempStoreURL())
    let row = try await store.enqueue(
      OutboxItem(recipient: .handle("+15551234567"), text: "hi", service: "iMessage")
    )
    try await store.markSending(id: row.id)
    try await store.markSent(id: row.id)
    try await store.markVerified(id: row.id, verifiedGUID: "G", verifiedRowid: 1)

    let events = try await store.events(outboxID: row.id, afterEventID: 0, limit: 100)
    XCTAssertEqual(events.count, 4)
    XCTAssertEqual(events.map { $0.toState }, ["queued", "sending", "sent", "verified"])
  }

  func testMarkFailedReturnsToQueuedAndRecordsError() async throws {
    let store = try await OutboxStore.open(at: makeTempStoreURL())
    let row = try await store.enqueue(
      OutboxItem(recipient: .handle("+15551234567"), text: "hi", service: "iMessage"))
    try await store.markSending(id: row.id)
    let now = Date()
    try await store.markFailed(
      id: row.id, error: "boom", backoffAt: now.addingTimeInterval(5), now: now)

    let refreshed = try await store.get(id: row.id)
    XCTAssertEqual(refreshed?.state, OutboxState.queued.rawValue)
    XCTAssertEqual(refreshed?.lastError, "boom")
    XCTAssertNotNil(refreshed?.nextAttemptAt)
  }

  func testNextReadyRespectsBackoff() async throws {
    let store = try await OutboxStore.open(at: makeTempStoreURL())
    let row = try await store.enqueue(
      OutboxItem(recipient: .handle("+15551234567"), text: "hi", service: "iMessage"))
    try await store.markSending(id: row.id)
    let soon = Date().addingTimeInterval(60)
    try await store.markFailed(id: row.id, error: "nope", backoffAt: soon)

    let readyNow = try await store.nextReady(now: Date(), limit: 10)
    XCTAssertTrue(readyNow.isEmpty)

    let readyLater = try await store.nextReady(now: soon.addingTimeInterval(1), limit: 10)
    XCTAssertEqual(readyLater.count, 1)
  }

  func testMarkDeadLetterIsTerminal() async throws {
    let store = try await OutboxStore.open(at: makeTempStoreURL())
    let row = try await store.enqueue(
      OutboxItem(recipient: .handle("+15551234567"), text: "hi", service: "iMessage"))
    try await store.markSending(id: row.id)
    try await store.markDeadLetter(id: row.id, error: "permission_denied")
    let refreshed = try await store.get(id: row.id)
    XCTAssertEqual(refreshed?.state, OutboxState.deadLetter.rawValue)
    XCTAssertEqual(refreshed?.lastError, "permission_denied")
  }

  func testIdempotencyKeyDerivationIsStable() {
    let a = OutboxItem(recipient: .handle("+1"), text: "hi", service: "iMessage")
    let b = OutboxItem(recipient: .handle("+1"), text: "hi", service: "iMessage")
    XCTAssertEqual(a.resolvedIdempotencyKey(), b.resolvedIdempotencyKey())
    XCTAssertEqual(a.resolvedIdempotencyKey().count, 64)
    let c = OutboxItem(recipient: .handle("+1"), text: "hi2", service: "iMessage")
    XCTAssertNotEqual(a.resolvedIdempotencyKey(), c.resolvedIdempotencyKey())
  }
}
