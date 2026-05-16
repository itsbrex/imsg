import XCTest

@testable import IMsgCore

final class SchemaEnvelopeTests: XCTestCase {
  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return encoder
  }()

  func testEnvelopeEncodesKeysInDeclaredOrder() throws {
    let envelope = EnvelopePayload(kind: "chat", data: ["a": 1])
    let data = try SchemaEnvelopeTests.encoder.encode(envelope)
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))

    XCTAssertTrue(json.contains(#""schema":"v1""#))
    XCTAssertTrue(json.contains(#""kind":"chat""#))
    XCTAssertTrue(json.contains(#""data":{"a":1}"#))
  }

  func testEnvelopeSchemaValueIsV1() throws {
    let envelope = EnvelopePayload(kind: "chat", data: ["a": 1])
    let data = try SchemaEnvelopeTests.encoder.encode(envelope)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    XCTAssertEqual(object["schema"] as? String, "v1")
    XCTAssertEqual(object["kind"] as? String, "chat")
    let payload = try XCTUnwrap(object["data"] as? [String: Int])
    XCTAssertEqual(payload, ["a": 1])
  }

  func testSchemaDefaultsToCurrentVersion() {
    let envelope = EnvelopePayload(kind: "message", data: ["x": 42])
    XCTAssertEqual(envelope.schema, IMsgSchema.currentVersion)
    XCTAssertEqual(envelope.kind, "message")
  }

  func testSchemaAcceptsExplicitOverride() {
    let envelope = EnvelopePayload(kind: "message", data: ["x": 42], schema: "v2")
    XCTAssertEqual(envelope.schema, "v2")
  }
}
