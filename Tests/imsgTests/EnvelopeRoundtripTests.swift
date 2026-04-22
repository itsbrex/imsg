import XCTest

@testable import IMsgCore
@testable import imsg

/// Round-trip tests for `JSONLines.encode` applied to an `EnvelopePayload`.
///
/// Full env-var gating (spawning `imsg` with `IMSG_SCHEMA=v1` set and
/// asserting envelope-wrapped stdout vs. bare legacy output) is covered by
/// CLI-level integration tests that run on macOS and are out of this
/// sandbox's scope. We intentionally do NOT mutate
/// `ProcessInfo.processInfo.environment` from tests — it is flaky and
/// process-wide, which contaminates parallel tests.
final class EnvelopeRoundtripTests: XCTestCase {
  private struct Probe: Decodable, Equatable {
    let schema: String
    let kind: String
    let data: [String: Int]
  }

  func testEnvelopeRoundtripsThroughJSONLinesEncode() throws {
    let envelope = EnvelopePayload(kind: "chat", data: ["a": 1, "b": 2])
    let line = try JSONLines.encode(envelope)
    XCTAssertFalse(line.isEmpty)

    let data = try XCTUnwrap(line.data(using: .utf8))
    let probe = try JSONDecoder().decode(Probe.self, from: data)

    XCTAssertEqual(probe.schema, IMsgSchema.currentVersion)
    XCTAssertEqual(probe.schema, "v1")
    XCTAssertEqual(probe.kind, "chat")
    XCTAssertEqual(probe.data, ["a": 1, "b": 2])
  }

  func testEnvelopeEncodesFieldsInDeclaredOrder() throws {
    let envelope = EnvelopePayload(kind: "message", data: ["n": 7])
    let line = try JSONLines.encode(envelope)

    let schemaIdx = try XCTUnwrap(line.range(of: "\"schema\"")).lowerBound
    let kindIdx = try XCTUnwrap(line.range(of: "\"kind\"")).lowerBound
    let dataIdx = try XCTUnwrap(line.range(of: "\"data\"")).lowerBound

    XCTAssertLessThan(schemaIdx, kindIdx)
    XCTAssertLessThan(kindIdx, dataIdx)
  }
}
