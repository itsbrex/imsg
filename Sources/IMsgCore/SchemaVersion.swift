import Foundation

public enum IMsgSchema {
  public static let currentVersion = "v1"

  public static var envOverride: String? {
    ProcessInfo.processInfo.environment["IMSG_SCHEMA"]
  }

  public static var effectiveVersion: String {
    envOverride ?? currentVersion
  }
}
