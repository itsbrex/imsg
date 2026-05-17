import Foundation

/// A narrow protocol over per-handle contact lookup, designed so that the
/// rules engine, the `who` command, and the interaction graph can be
/// driven by an in-memory fake during tests without dragging in
/// `Contacts.framework`.
///
/// The system implementation (`ResolverContactsBridge`) wraps the
/// upstream `ContactResolving` so that the bridge layer adds no new
/// authorization surface or framework dependency — it just narrows the
/// contract to the single operation downstream callers actually need.
public protocol ContactsBridge: Sendable {
  func find(handle: String) async throws -> Contact?
}

// MARK: - Pass-through bridge backed by `ContactResolving`

public struct ResolverContactsBridge: ContactsBridge {
  private let resolver: any ContactResolving

  public init(resolver: any ContactResolving) {
    self.resolver = resolver
  }

  public func find(handle: String) async throws -> Contact? {
    guard let name = resolver.displayName(for: handle) else { return nil }
    return Contact(name: name, handle: handle)
  }
}

// MARK: - No-op bridge

public struct NoOpContactsBridge: ContactsBridge {
  public init() {}
  public func find(handle: String) async throws -> Contact? { nil }
}

// MARK: - In-memory bridge for tests

public actor InMemoryContactsBridge: ContactsBridge {
  private var records: [String: Contact]
  public private(set) var lookupCount: Int = 0

  public init(records: [String: Contact] = [:]) {
    self.records = records
  }

  public func set(_ record: Contact, for handle: String) {
    records[handle] = record
  }

  public func find(handle: String) async throws -> Contact? {
    lookupCount += 1
    return records[handle]
  }
}
