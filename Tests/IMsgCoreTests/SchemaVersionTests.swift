import XCTest

@testable import IMsgCore

final class SchemaVersionTests: XCTestCase {
  func testCurrentVersionIsV1() {
    XCTAssertEqual(IMsgSchema.currentVersion, "v1")
  }

  func testEffectiveVersionFallsBackToCurrent() {
    if ProcessInfo.processInfo.environment["IMSG_SCHEMA"] == nil {
      XCTAssertEqual(IMsgSchema.effectiveVersion, IMsgSchema.currentVersion)
    }
  }
}
