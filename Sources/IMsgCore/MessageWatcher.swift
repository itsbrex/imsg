import Foundation

#if os(macOS)
  import Darwin
#endif

public struct MessageWatcherConfiguration: Sendable, Equatable {
  public var debounceInterval: TimeInterval
  public var fallbackPollInterval: TimeInterval?
  public var batchLimit: Int
  /// When true, reaction events (tapback add/remove) are included in the stream
  public var includeReactions: Bool

  public init(
    debounceInterval: TimeInterval = 0.25,
    fallbackPollInterval: TimeInterval? = 5,
    batchLimit: Int = 100,
    includeReactions: Bool = false
  ) {
    self.debounceInterval = debounceInterval
    self.fallbackPollInterval = fallbackPollInterval
    self.batchLimit = batchLimit
    self.includeReactions = includeReactions
  }
}

/// Multi-consumer message watcher.
///
/// `MessageWatcher` is an actor that fans out a single shared file-system
/// observation of `chat.db` to N independent `AsyncThrowingStream` consumers.
/// Each consumer owns its own cursor (so a slow consumer cannot starve a fast
/// one), and cancellation of any single consumer leaves the others running.
public actor MessageWatcher {
  private let store: MessageStore

  private struct Subscriber {
    let id: UUID
    let chatID: Int64?
    var cursor: Int64
    let configuration: MessageWatcherConfiguration
    let continuation: AsyncThrowingStream<Message, Error>.Continuation
  }

  private var subscribers: [UUID: Subscriber] = [:]
  private var cancelledBeforeAdd: Set<UUID> = []
  private var fileObserver: FileObserver?
  private var fallbackTask: Task<Void, Never>?
  private var debounceTask: Task<Void, Never>?

  public init(store: MessageStore) {
    self.store = store
  }

  /// Subscribe to incoming messages. Returns a stream that finishes when the
  /// caller breaks the iteration or cancels the consuming Task. Multiple
  /// concurrent subscribers are supported and share the underlying watcher.
  public nonisolated func stream(
    chatID: Int64? = nil,
    sinceRowID: Int64? = nil,
    configuration: MessageWatcherConfiguration = MessageWatcherConfiguration()
  ) -> AsyncThrowingStream<Message, Error> {
    let (stream, continuation) = AsyncThrowingStream<Message, Error>.makeStream(of: Message.self)
    let id = UUID()
    continuation.onTermination = { [weak self] _ in
      guard let self else { return }
      Task { await self.removeSubscriber(id: id) }
    }
    Task {
      await self.addSubscriber(
        id: id,
        chatID: chatID,
        sinceRowID: sinceRowID,
        configuration: configuration,
        continuation: continuation
      )
    }
    return stream
  }

  // MARK: - Subscriber lifecycle

  private func addSubscriber(
    id: UUID,
    chatID: Int64?,
    sinceRowID: Int64?,
    configuration: MessageWatcherConfiguration,
    continuation: AsyncThrowingStream<Message, Error>.Continuation
  ) {
    if cancelledBeforeAdd.remove(id) != nil {
      return
    }
    let cursor: Int64
    if let provided = sinceRowID, provided != 0 {
      cursor = provided
    } else {
      do {
        cursor = try store.maxRowID()
      } catch {
        continuation.finish(throwing: error)
        return
      }
    }

    let subscriber = Subscriber(
      id: id,
      chatID: chatID,
      cursor: cursor,
      configuration: configuration,
      continuation: continuation
    )
    subscribers[id] = subscriber

    ensureObservation()
    pollSubscriber(id: id)
  }

  private func removeSubscriber(id: UUID) {
    if subscribers.removeValue(forKey: id) == nil {
      cancelledBeforeAdd.insert(id)
      return
    }
    if subscribers.isEmpty {
      tearDownObservation()
    } else {
      reconfigureFallback()
    }
  }

  // MARK: - Observation

  private func ensureObservation() {
    #if os(macOS)
      if fileObserver == nil {
        let paths = [store.path, store.path + "-wal", store.path + "-shm"]
        fileObserver = FileObserver(paths: paths) { [weak self] in
          guard let self else { return }
          Task { await self.fileEventDidFire() }
        }
      }
    #endif
    reconfigureFallback()
  }

  private func tearDownObservation() {
    fileObserver?.cancel()
    fileObserver = nil
    fallbackTask?.cancel()
    fallbackTask = nil
    debounceTask?.cancel()
    debounceTask = nil
  }

  private func reconfigureFallback() {
    fallbackTask?.cancel()
    let intervals = subscribers.values
      .compactMap { $0.configuration.fallbackPollInterval }
      .filter { $0 > 0 }
    guard let minInterval = intervals.min() else {
      fallbackTask = nil
      return
    }
    let nanos = UInt64(max(minInterval, 0.001) * 1_000_000_000)
    fallbackTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: nanos)
        if Task.isCancelled { return }
        await self?.pollAllSubscribers()
      }
    }
  }

  private func fileEventDidFire() {
    debounceTask?.cancel()
    let debounces = subscribers.values.map { $0.configuration.debounceInterval }
    let minDebounce = debounces.min() ?? 0.25
    let nanos = UInt64(max(minDebounce, 0) * 1_000_000_000)
    debounceTask = Task { [weak self] in
      if nanos > 0 {
        try? await Task.sleep(nanoseconds: nanos)
      }
      if Task.isCancelled { return }
      await self?.pollAllSubscribers()
    }
  }

  // MARK: - Polling

  private func pollAllSubscribers() {
    for id in Array(subscribers.keys) {
      pollSubscriber(id: id)
    }
  }

  private func pollSubscriber(id: UUID) {
    guard var subscriber = subscribers[id] else { return }
    do {
      let messages = try store.messagesAfter(
        afterRowID: subscriber.cursor,
        chatID: subscriber.chatID,
        limit: subscriber.configuration.batchLimit,
        includeReactions: subscriber.configuration.includeReactions
      )
      for message in messages {
        subscriber.continuation.yield(message)
        if message.rowID > subscriber.cursor {
          subscriber.cursor = message.rowID
        }
      }
      subscribers[id] = subscriber
    } catch {
      subscriber.continuation.finish(throwing: error)
      subscribers.removeValue(forKey: id)
      if subscribers.isEmpty {
        tearDownObservation()
      }
    }
  }
}

// MARK: - File observation

/// Wraps the `DispatchSourceFileSystemObject` machinery so the actor can
/// install / tear down file-system observation without touching dispatch
/// queue state directly.
private final class FileObserver: @unchecked Sendable {
  private let queue = DispatchQueue(label: "imsg.watch.fileobserver", qos: .userInitiated)
  private var sources: [DispatchSourceFileSystemObject] = []

  init(paths: [String], onChange: @escaping @Sendable () -> Void) {
    #if os(macOS)
      queue.sync {
        for path in paths {
          let fd = open(path, O_EVTONLY)
          guard fd >= 0 else { continue }
          let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
          )
          source.setEventHandler { onChange() }
          source.setCancelHandler { close(fd) }
          source.resume()
          sources.append(source)
        }
      }
    #endif
  }

  func cancel() {
    queue.sync {
      for source in sources {
        source.cancel()
      }
      sources.removeAll()
    }
  }
}
