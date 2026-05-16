import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

private struct RecordingSender: OutboxSending {
  final class State: @unchecked Sendable {
    var calls: Int = 0
    let lock = NSLock()
  }

  let state: State
  let script: [Result<Void, Error>]

  init(_ script: [Result<Void, Error>]) {
    self.state = State()
    self.script = script
  }

  func send(_ options: MessageSendOptions) throws {
    state.lock.lock()
    let idx = state.calls
    state.calls += 1
    state.lock.unlock()
    let outcome = script[min(idx, script.count - 1)]
    switch outcome {
    case .success: return
    case .failure(let err): throw err
    }
  }
}

private func makeTempStorePath() -> String {
  let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
  return tmp.appendingPathComponent("outbox.sqlite").path
}

@Test
func outboxWorkerRetriesTransientFailureThenSucceeds() async throws {
  let store = try await OutboxStore.open(at: URL(fileURLWithPath: makeTempStorePath()))
  let sender = RecordingSender([
    .failure(IMsgError.appleScriptFailure("Messages.app timed out")),
    .success(()),
  ])
  // No MessageStore injection -> worker skips verification but still transitions.
  let fastSleep: @Sendable (Duration) async throws -> Void = { _ in }
  let worker = OutboxWorker(
    store: store,
    sender: sender,
    messageStore: nil,
    policy: OutboxRetryPolicy(
      maxAttempts: 5,
      schedule: [.milliseconds(1), .milliseconds(1), .milliseconds(1)],
      jitter: .milliseconds(0)
    ),
    now: Date.init,
    sleep: fastSleep
  )

  let enqueued = try await worker.enqueue(
    OutboxItem(
      recipient: .handle("+15551234567"),
      text: "hello world",
      service: "iMessage",
      idempotencyKey: "test-retry-ok"
    )
  )
  #expect(enqueued.state == OutboxState.queued.rawValue)

  // First processNext: sender throws transient -> row returns to queued.
  let first = try await worker.processNext()
  #expect(first?.state == OutboxState.queued.rawValue)
  #expect(first?.attempts == 1)

  // Wait past the 1ms backoff window (plus a small buffer) so the row is
  // eligible again on the next pass.
  try await Task.sleep(for: .milliseconds(50))

  // Second processNext: sender succeeds -> row becomes sent (no verifier).
  let second = try await worker.processNext()
  #expect(second?.state == OutboxState.sent.rawValue)
  #expect(sender.state.calls == 2)
}

@Test
func outboxWorkerDeadLettersPermissionErrors() async throws {
  let store = try await OutboxStore.open(at: URL(fileURLWithPath: makeTempStorePath()))
  let sender = RecordingSender([
    .failure(IMsgError.appleScriptFailure("not authorized"))
  ])
  let worker = OutboxWorker(
    store: store,
    sender: sender,
    messageStore: nil,
    policy: OutboxRetryPolicy(
      maxAttempts: 5, schedule: [.milliseconds(1)], jitter: .milliseconds(0)
    ),
    now: Date.init,
    sleep: { _ in }
  )
  _ = try await worker.enqueue(
    OutboxItem(
      recipient: .handle("+15551234567"), text: "hi", service: "iMessage",
      idempotencyKey: "test-perm")
  )
  let row = try await worker.processNext()
  #expect(row?.state == OutboxState.deadLetter.rawValue)
}

@Test
func outboxCommandListEmitsEnvelopeWhenJsonRequested() async throws {
  let storePath = makeTempStorePath()
  // Seed a row so `list` has something to render.
  let store = try await OutboxStore.open(at: URL(fileURLWithPath: storePath))
  _ = try await store.enqueue(
    OutboxItem(
      recipient: .handle("+15551234567"),
      text: "envelope roundtrip",
      service: "iMessage",
      idempotencyKey: "cmdtest-\(UUID().uuidString)"
    )
  )

  let values = ParsedValues(
    positional: [],
    options: [
      "action": ["list"],
      "limit": ["5"],
      "store": [storePath],
    ],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let captured = try await StdoutCapture.capture {
    try await OutboxCommand.spec.run(values, runtime)
  }
  #expect(captured.output.contains("\"schema\":\"v1\""))
  #expect(captured.output.contains("\"kind\":\"outbox\""))
}

@Test
func outboxCommandEnqueueRoundTrip() async throws {
  let storePath = makeTempStorePath()
  let values = ParsedValues(
    positional: [],
    options: [
      "action": ["enqueue"],
      "to": ["+15551234567"],
      "text": ["round-trip"],
      "idempotencyKey": ["cmd-enqueue-\(UUID().uuidString)"],
      "store": [storePath],
    ],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)
  let captured = try await StdoutCapture.capture {
    try await OutboxCommand.spec.run(values, runtime)
  }
  #expect(captured.output.contains("\"state\":\"queued\""))
}
