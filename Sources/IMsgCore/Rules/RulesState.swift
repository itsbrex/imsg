import Foundation
import SQLite

public struct RuleFireRecord: Sendable, Equatable {
  public let ruleName: String
  public let messageGUID: String
  public let firedAt: Date

  public init(ruleName: String, messageGUID: String, firedAt: Date) {
    self.ruleName = ruleName
    self.messageGUID = messageGUID
    self.firedAt = firedAt
  }
}

public actor RulesState {
  private let db: Connection
  public let path: String

  private init(path: String) throws {
    self.path = path
    let db = try Connection(path)
    self.db = db
    try Self.applyPragmas(db)
    try Self.migrate(db)
  }

  public static func open(at url: URL) async throws -> RulesState {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    return try RulesState(path: url.path)
  }

  public static func openDefault() async throws -> RulesState {
    try await open(at: defaultURL())
  }

  public static func defaultURL() -> URL {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    return base.appendingPathComponent("imsg/rules.state.sqlite")
  }

  private static func applyPragmas(_ db: Connection) throws {
    db.busyTimeout = 5
    try db.execute("PRAGMA journal_mode=WAL;")
    try db.execute("PRAGMA synchronous=FULL;")
  }

  private static func migrate(_ db: Connection) throws {
    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS fires (
        rule_name TEXT NOT NULL,
        message_guid TEXT NOT NULL,
        fired_at INTEGER NOT NULL,
        PRIMARY KEY (rule_name, message_guid)
      );
      """
    )
    try db.execute("CREATE INDEX IF NOT EXISTS fires_by_time ON fires(fired_at);")
    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS cooldowns (
        rule_name TEXT PRIMARY KEY,
        last_fire INTEGER NOT NULL
      );
      """
    )
    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS cursor (
        k TEXT PRIMARY KEY,
        v INTEGER NOT NULL
      );
      """
    )
  }

  public func cursor(key: String = "watch.rowid") throws -> Int64? {
    for row in try db.prepare("SELECT v FROM cursor WHERE k = ?", [key]) {
      return int64(row[0])
    }
    return nil
  }

  public func setCursor(_ rowID: Int64, key: String = "watch.rowid") throws {
    try db.run(
      """
      INSERT INTO cursor (k, v) VALUES (?, ?)
      ON CONFLICT(k) DO UPDATE SET v = excluded.v
      """,
      [key, rowID]
    )
  }

  public func canFire(rule: Rule, messageGUID: String, now: Date = Date()) throws -> Bool {
    let nowSeconds = Int64(now.timeIntervalSince1970)
    if let last = try lastFire(ruleName: rule.name),
      nowSeconds - last < Int64(rule.effectiveCooldownSeconds)
    {
      return false
    }

    let dedupeWindow = Int64(rule.dedupeWindowSeconds > 0 ? rule.dedupeWindowSeconds : 86_400)
    for row in try db.prepare(
      "SELECT fired_at FROM fires WHERE rule_name = ? AND message_guid = ?",
      [rule.name, messageGUID]
    ) {
      let firedAt = int64(row[0]) ?? 0
      if nowSeconds - firedAt < dedupeWindow {
        return false
      }
    }
    return true
  }

  public func recordFire(rule: Rule, messageGUID: String, now: Date = Date()) throws {
    let nowSeconds = Int64(now.timeIntervalSince1970)
    try db.run(
      """
      INSERT INTO fires (rule_name, message_guid, fired_at) VALUES (?, ?, ?)
      ON CONFLICT(rule_name, message_guid) DO UPDATE SET fired_at = excluded.fired_at
      """,
      [rule.name, messageGUID, nowSeconds]
    )
    try db.run(
      """
      INSERT INTO cooldowns (rule_name, last_fire) VALUES (?, ?)
      ON CONFLICT(rule_name) DO UPDATE SET last_fire = excluded.last_fire
      """,
      [rule.name, nowSeconds]
    )
  }

  public func listFires(limit: Int = 50) throws -> [RuleFireRecord] {
    var records: [RuleFireRecord] = []
    for row in try db.prepare(
      """
      SELECT rule_name, message_guid, fired_at FROM fires
      ORDER BY fired_at DESC LIMIT ?
      """,
      [Int64(limit)]
    ) {
      records.append(
        RuleFireRecord(
          ruleName: (row[0] as? String) ?? "",
          messageGUID: (row[1] as? String) ?? "",
          firedAt: Date(timeIntervalSince1970: TimeInterval(int64(row[2]) ?? 0))
        ))
    }
    return records
  }

  public func prune(olderThan cutoff: Date) throws {
    try db.run(
      "DELETE FROM fires WHERE fired_at < ?",
      [Int64(cutoff.timeIntervalSince1970)]
    )
  }

  private func lastFire(ruleName: String) throws -> Int64? {
    for row in try db.prepare("SELECT last_fire FROM cooldowns WHERE rule_name = ?", [ruleName]) {
      return int64(row[0])
    }
    return nil
  }

  private func int64(_ value: Binding?) -> Int64? {
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    return nil
  }
}
