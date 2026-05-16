import Foundation

/// Envelope wrapper for versioned JSON output.
///
/// When `IMSG_SCHEMA=v1` is set, every JSON line emitted by `imsg` is wrapped
/// in this envelope so downstream tools can pin to a schema major and switch
/// on the `kind` discriminator. See `docs/SCHEMA.md` for the full contract.
///
/// `CodingKeys` is ordered `schema, kind, data` so the encoded JSON preserves
/// that field order.
public struct EnvelopePayload<T: Encodable>: Encodable {
  public let schema: String
  public let kind: String
  public let data: T

  public init(kind: String, data: T, schema: String = IMsgSchema.currentVersion) {
    self.schema = schema
    self.kind = kind
    self.data = data
  }

  private enum CodingKeys: String, CodingKey {
    case schema
    case kind
    case data
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schema, forKey: .schema)
    try container.encode(kind, forKey: .kind)
    try container.encode(data, forKey: .data)
  }
}
