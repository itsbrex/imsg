import Foundation

/// In-memory TTL cache in front of any `ContactsBridge`.
///
/// W3.C ships the in-memory variant only. The original plan called for a
/// persistent SQLite cache at
/// `~/Library/Application Support/imsg/contacts.sqlite`, but the upstream
/// `ContactResolver` already loads the full address book up front, so
/// per-handle lookups are cheap and a process-local cache is sufficient
/// for the rules engine and the `who`/`graph` commands. The cache key is
/// the raw queried handle — callers that want canonicalization should
/// normalize before calling `find(handle:)`.
public actor ContactsCache: ContactsBridge {
  private struct Entry {
    let contact: Contact?
    let timestamp: Date
  }

  public static let defaultTTL: TimeInterval = 24 * 60 * 60

  private let upstream: any ContactsBridge
  private let ttl: TimeInterval
  private let now: @Sendable () -> Date
  private var entries: [String: Entry] = [:]

  public init(
    upstream: any ContactsBridge,
    ttl: TimeInterval = ContactsCache.defaultTTL,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.upstream = upstream
    self.ttl = ttl
    self.now = now
  }

  public func find(handle: String) async throws -> Contact? {
    let current = now()
    if let entry = entries[handle], current.timeIntervalSince(entry.timestamp) < ttl {
      return entry.contact
    }
    let fresh = try await upstream.find(handle: handle)
    entries[handle] = Entry(contact: fresh, timestamp: current)
    return fresh
  }

  public func invalidate(handle: String) {
    entries.removeValue(forKey: handle)
  }

  public func invalidateAll() {
    entries.removeAll()
  }

  public var cachedHandleCount: Int {
    entries.count
  }
}
