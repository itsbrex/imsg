import Foundation

/// A resolved contact record returned by a `ContactsBridge`.
///
/// W3.C intentionally keeps this minimal — a display name and the handle
/// that was queried. Richer fields (phones, emails) live inside the
/// existing `ContactResolver` already and can be promoted into this
/// type by W4.W when the interaction graph needs them.
public struct Contact: Sendable, Equatable {
  public let name: String
  public let handle: String

  public init(name: String, handle: String) {
    self.name = name
    self.handle = handle
  }
}
