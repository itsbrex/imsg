import Commander
import Foundation
import IMsgCore
import Testing

@testable import imsg

@Test
func rulesValidateCommandReportsValidConfig() async throws {
  let config = try writeRulesConfig(
    """
    [[rule]]
    name = "audit"
    action = "log"
    match_text = "hello"
    """
  )
  let values = ParsedValues(
    positional: [],
    options: ["action": ["validate"], "config": [config.path]],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)

  let (output, _) = try await StdoutCapture.capture {
    try await RulesCommand.run(values: values, runtime: runtime)
  }

  let payload = try rulesJSONObject(from: output)
  #expect(payload["ok"] as? Bool == true)
  #expect(payload["rules"] as? [String] == ["audit"])
}

@Test
func rulesListCommandReportsConfiguredRules() async throws {
  let config = try writeRulesConfig(
    """
    [[rule]]
    name = "audit"
    action = "log"
    match_sender = "+1555"
    """
  )
  let state = FileManager.default.temporaryDirectory
    .appendingPathComponent("imsg-rules-command-\(UUID().uuidString)")
    .appendingPathComponent("rules.sqlite")
  let values = ParsedValues(
    positional: [],
    options: [
      "action": ["list"],
      "config": [config.path],
      "state": [state.path],
    ],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)

  let (output, _) = try await StdoutCapture.capture {
    try await RulesCommand.run(values: values, runtime: runtime)
  }

  let payload = try rulesJSONObject(from: output)
  let rules = payload["rules"] as? [[String: Any]] ?? []
  let first = rules.first ?? [:]
  #expect(first["name"] as? String == "audit")
  #expect(first["action"] as? String == "log")
}

private func writeRulesConfig(_ source: String) throws -> URL {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("imsg-rules-config-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let url = dir.appendingPathComponent("rules.toml")
  try source.write(to: url, atomically: true, encoding: .utf8)
  return url
}

private func rulesJSONObject(from output: String) throws -> [String: Any] {
  let line = output.split(separator: "\n").first.map(String.init) ?? ""
  let data = Data(line.utf8)
  return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}
