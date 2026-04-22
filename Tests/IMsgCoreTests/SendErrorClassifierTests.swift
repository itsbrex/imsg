import XCTest

@testable import IMsgCore

final class SendErrorClassifierTests: XCTestCase {
  private static let cases: [(String, SendErrorClass)] = [
    // Permission-denied heuristics
    ("not authorized to send Apple events", .permissionDenied),
    ("Operation not authorised", .permissionDenied),
    ("osascript: Automation policy denied", .permissionDenied),
    ("AppleScript error -1743: rejected", .permissionDenied),
    // Unknown-handle heuristics
    ("Can't get buddy \"+15551234567\"", .unknownHandle),
    ("buddy is unknown", .unknownHandle),
    // Transient fallback
    ("Messages.app timed out", .transient),
    ("", .transient),
    ("something else entirely", .transient),
  ]

  func testClassifyStringTable() {
    for (input, expected) in Self.cases {
      XCTAssertEqual(
        SendErrorClassifier.classify(message: input), expected,
        "input: \(input.debugDescription)"
      )
    }
  }

  func testClassifyNonIMsgErrorIsTransient() {
    struct Opaque: Error {}
    XCTAssertEqual(SendErrorClassifier.classify(Opaque()), .transient)
  }

  func testClassifyIMsgErrorForwardsToMessage() {
    let err = IMsgError.appleScriptFailure("not authorized: foo")
    XCTAssertEqual(SendErrorClassifier.classify(err), .permissionDenied)
  }

  func testMinusSeventeenFortyThreeMapping() {
    XCTAssertEqual(
      SendErrorClassifier.classify(message: "error -1743 AEServer"),
      .permissionDenied
    )
  }
}
