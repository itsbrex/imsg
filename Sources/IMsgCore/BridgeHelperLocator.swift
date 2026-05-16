import Foundation

public enum BridgeHelperLocator {
  public static let fileName = "imsg-bridge-helper.dylib"

  public static func searchPaths(
    executableURL: URL? = Bundle.main.executableURL,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String] {
    var paths: [String] = []
    var seen = Set<String>()

    func append(_ path: String) {
      guard !path.isEmpty, !seen.contains(path) else { return }
      seen.insert(path)
      paths.append(path)
    }

    if let executableURL {
      let executableDirectory = executableURL.deletingLastPathComponent()
      append(executableDirectory.appendingPathComponent(fileName).path)
      append(
        executableDirectory
          .deletingLastPathComponent()
          .appendingPathComponent("lib")
          .appendingPathComponent(fileName)
          .path
      )
    }

    if let prefix = environment["HOMEBREW_PREFIX"], !prefix.isEmpty {
      append(
        URL(fileURLWithPath: prefix)
          .appendingPathComponent("lib")
          .appendingPathComponent(fileName)
          .path
      )
    }

    append("/opt/homebrew/lib/\(fileName)")
    append("/usr/local/lib/\(fileName)")
    append(".build/release/\(fileName)")
    append(".build/debug/\(fileName)")

    return paths
  }

  public static func resolve(
    customPath: String? = nil,
    executableURL: URL? = Bundle.main.executableURL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> String? {
    if let customPath {
      return fileManager.fileExists(atPath: customPath) ? customPath : nil
    }

    return searchPaths(executableURL: executableURL, environment: environment)
      .first { fileManager.fileExists(atPath: $0) }
  }
}
