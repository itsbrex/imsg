import Foundation
import Testing

@testable import IMsgCore

@Test
func bridgeHelperLocatorIncludesHomebrewAndSourcePaths() {
  let paths = BridgeHelperLocator.searchPaths(
    executableURL: URL(fileURLWithPath: "/opt/homebrew/Cellar/imsg/1.2.3/libexec/imsg"),
    environment: ["HOMEBREW_PREFIX": "/custom/brew"]
  )

  #expect(
    paths == [
      "/opt/homebrew/Cellar/imsg/1.2.3/libexec/imsg-bridge-helper.dylib",
      "/opt/homebrew/Cellar/imsg/1.2.3/lib/imsg-bridge-helper.dylib",
      "/custom/brew/lib/imsg-bridge-helper.dylib",
      "/opt/homebrew/lib/imsg-bridge-helper.dylib",
      "/usr/local/lib/imsg-bridge-helper.dylib",
      ".build/release/imsg-bridge-helper.dylib",
      ".build/debug/imsg-bridge-helper.dylib",
    ])
}

@Test
func bridgeHelperLocatorDeduplicatesPaths() {
  let paths = BridgeHelperLocator.searchPaths(
    executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/imsg"),
    environment: ["HOMEBREW_PREFIX": "/opt/homebrew"]
  )

  #expect(paths.count == Set(paths).count)
}
