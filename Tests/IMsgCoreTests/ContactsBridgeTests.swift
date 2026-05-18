import Foundation
import Testing

@testable import IMsgCore

@Test
func inMemoryBridgeReturnsConfiguredRecord() async throws {
  let bridge = InMemoryContactsBridge(records: [
    "+15551234567": Contact(name: "Alice", handle: "+15551234567")
  ])
  let resolved = try await bridge.find(handle: "+15551234567")
  #expect(resolved?.name == "Alice")
  #expect(resolved?.handle == "+15551234567")
}

@Test
func inMemoryBridgeReturnsNilForUnknownHandle() async throws {
  let bridge = InMemoryContactsBridge()
  let resolved = try await bridge.find(handle: "+10000000000")
  #expect(resolved == nil)
}

@Test
func noOpBridgeAlwaysReturnsNil() async throws {
  let bridge = NoOpContactsBridge()
  let resolved = try await bridge.find(handle: "alice@example.com")
  #expect(resolved == nil)
}

@Test
func resolverBridgeDelegatesToContactResolver() async throws {
  final class FakeResolver: ContactResolving, @unchecked Sendable {
    let contactsUnavailable = false
    var names: [String: String]
    init(_ names: [String: String]) { self.names = names }
    func displayName(for handle: String) -> String? { names[handle] }
    func displayNames(for handles: [String]) -> [String: String] {
      handles.reduce(into: [:]) { acc, h in if let n = names[h] { acc[h] = n } }
    }
    func searchByName(_ query: String) -> [ContactMatch] { [] }
  }

  let resolver = FakeResolver(["+15551234567": "Bob"])
  let bridge = ResolverContactsBridge(resolver: resolver)
  let hit = try await bridge.find(handle: "+15551234567")
  #expect(hit?.name == "Bob")
  let miss = try await bridge.find(handle: "+10000000000")
  #expect(miss == nil)
}

@Test
func cacheServesRepeatedLookupsFromMemory() async throws {
  let upstream = InMemoryContactsBridge(records: [
    "+15550000001": Contact(name: "Cached", handle: "+15550000001")
  ])
  let cache = ContactsCache(upstream: upstream, ttl: 60)

  let first = try await cache.find(handle: "+15550000001")
  let second = try await cache.find(handle: "+15550000001")
  #expect(first?.name == "Cached")
  #expect(second?.name == "Cached")
  #expect(await upstream.lookupCount == 1)
}

@Test
func cacheRespectsTTL() async throws {
  let upstream = InMemoryContactsBridge(records: [
    "+15550000002": Contact(name: "Refresh", handle: "+15550000002")
  ])
  final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func advance(by interval: TimeInterval) {
      lock.lock(); defer { lock.unlock() }
      value = value.addingTimeInterval(interval)
    }
    func snapshot() -> Date {
      lock.lock(); defer { lock.unlock() }
      return value
    }
  }
  let clock = Clock(Date(timeIntervalSince1970: 0))
  let cache = ContactsCache(
    upstream: upstream,
    ttl: 60,
    now: { clock.snapshot() }
  )

  _ = try await cache.find(handle: "+15550000002")
  #expect(await upstream.lookupCount == 1)

  clock.advance(by: 120)
  _ = try await cache.find(handle: "+15550000002")
  #expect(await upstream.lookupCount == 2)
}

@Test
func cacheNegativeHitsAreAlsoCached() async throws {
  let upstream = InMemoryContactsBridge()
  let cache = ContactsCache(upstream: upstream, ttl: 60)
  let first = try await cache.find(handle: "+15550000003")
  let second = try await cache.find(handle: "+15550000003")
  #expect(first == nil)
  #expect(second == nil)
  // Cache should remember the miss so we do not re-query upstream.
  #expect(await upstream.lookupCount == 1)
}

@Test
func cacheInvalidationForcesRefresh() async throws {
  let upstream = InMemoryContactsBridge(records: [
    "+15550000004": Contact(name: "Pre", handle: "+15550000004")
  ])
  let cache = ContactsCache(upstream: upstream, ttl: 3600)

  _ = try await cache.find(handle: "+15550000004")
  await upstream.set(Contact(name: "Post", handle: "+15550000004"), for: "+15550000004")
  // Without invalidation we still see the stale value.
  let stale = try await cache.find(handle: "+15550000004")
  #expect(stale?.name == "Pre")
  await cache.invalidate(handle: "+15550000004")
  let fresh = try await cache.find(handle: "+15550000004")
  #expect(fresh?.name == "Post")
}
