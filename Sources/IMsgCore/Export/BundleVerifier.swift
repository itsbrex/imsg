import Foundation

public struct BundleDriftReport: Equatable, Sendable {
  public var mismatchedHashes: [String]
  public var missingFiles: [String]
  public var unexpectedFiles: [String]
  public var countDeltas: [String]

  public init(
    mismatchedHashes: [String] = [],
    missingFiles: [String] = [],
    unexpectedFiles: [String] = [],
    countDeltas: [String] = []
  ) {
    self.mismatchedHashes = mismatchedHashes
    self.missingFiles = missingFiles
    self.unexpectedFiles = unexpectedFiles
    self.countDeltas = countDeltas
  }

  public var isClean: Bool {
    mismatchedHashes.isEmpty
      && missingFiles.isEmpty
      && unexpectedFiles.isEmpty
      && countDeltas.isEmpty
  }
}

public struct BundleVerifier {
  public init() {}

  public func verify(directory: URL) throws -> BundleDriftReport {
    let fm = FileManager.default
    let manifestURL = directory.appendingPathComponent("manifest.json")
    guard fm.fileExists(atPath: manifestURL.path) else {
      throw BundleError.missingManifest(manifestURL.path)
    }
    let manifestData = try Data(contentsOf: manifestURL)
    guard
      let manifestObject = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
    else {
      throw BundleError.malformedManifest(manifestURL.path)
    }
    guard
      let hashes = manifestObject["hashes"] as? [String: String],
      let counts = manifestObject["counts"] as? [String: Int]
    else {
      throw BundleError.malformedManifest(manifestURL.path)
    }

    var report = BundleDriftReport()

    // Hash check + missing files
    for (relativePath, expected) in hashes.sorted(by: { $0.key < $1.key }) {
      let fileURL = directory.appendingPathComponent(relativePath)
      guard fm.fileExists(atPath: fileURL.path) else {
        report.missingFiles.append(relativePath)
        continue
      }
      let data = try Data(contentsOf: fileURL)
      let actual = BundleHasher.sha256Hex(data)
      if actual != expected {
        report.mismatchedHashes.append(relativePath)
      }
    }

    // Unexpected files (anything in bundle root not in hashes, except manifest)
    let listed = try fm.contentsOfDirectory(atPath: directory.path)
    for entry in listed.sorted() {
      if entry == "manifest.json" { continue }
      var isDir: ObjCBool = false
      let entryURL = directory.appendingPathComponent(entry)
      _ = fm.fileExists(atPath: entryURL.path, isDirectory: &isDir)
      if isDir.boolValue { continue }  // attachments/ dir not part of MVP
      if hashes[entry] == nil {
        report.unexpectedFiles.append(entry)
      }
    }

    // Count check
    let messageURL = directory.appendingPathComponent("messages.jsonl")
    if fm.fileExists(atPath: messageURL.path) {
      let lines = try countLines(messageURL)
      if let expected = counts["messages"], expected != lines {
        report.countDeltas.append("messages: expected \(expected), got \(lines)")
      }
    }
    let reactionURL = directory.appendingPathComponent("reactions.jsonl")
    if fm.fileExists(atPath: reactionURL.path) {
      let lines = try countLines(reactionURL)
      if let expected = counts["reactions"], expected != lines {
        report.countDeltas.append("reactions: expected \(expected), got \(lines)")
      }
    }

    return report
  }

  private func countLines(_ url: URL) throws -> Int {
    let data = try Data(contentsOf: url)
    if data.isEmpty { return 0 }
    var count = 0
    for byte in data where byte == 0x0A {
      count += 1
    }
    return count
  }
}
