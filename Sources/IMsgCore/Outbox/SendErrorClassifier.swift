#if os(macOS)
  import Foundation

  /// Coarse classification of a ``MessageSender`` failure that the outbox
  /// worker turns into a retry decision.
  ///
  /// We keep this intentionally external to ``IMsgError`` (see the Wave 2c
  /// design note in `docs/outbox.md` and the plan audit at
  /// `docs/plans/create-and-or-review-bright-graham.md`) so the outbox stays
  /// reversible.
  public enum SendErrorClass: String, Sendable, Codable {
    /// Retryable: AppleScript timed out, Messages.app restarting, gateway blip.
    case transient
    /// Terminal: Automation or Full Disk Access not granted.
    case permissionDenied = "permission_denied"
    /// Terminal: recipient handle cannot be resolved by Messages.app.
    case unknownHandle = "unknown_handle"
  }

  /// External classifier mapping ``IMsgError/appleScriptFailure(_:)`` message
  /// strings (declared in `Sources/IMsgCore/Errors.swift`) to retry classes.
  ///
  /// The classifier inspects free-form AppleScript messages plus the well-known
  /// error number `-1743` (see `Sources/IMsgCore/MessageSender.swift:236`) that
  /// indicates the user has not granted Automation permission to the terminal.
  public enum SendErrorClassifier {
    /// Returns the retry class for `error`. Non-``IMsgError`` inputs fall back
    /// to `.transient` so callers get a safe default.
    public static func classify(_ error: Error) -> SendErrorClass {
      if let imsg = error as? IMsgError, case .appleScriptFailure(let message) = imsg {
        return classify(message: message)
      }
      return .transient
    }

    /// Classifies a raw AppleScript error message. Exposed so tests and the
    /// worker can share the same decision table.
    public static func classify(message: String) -> SendErrorClass {
      let lower = message.lowercased()

      // Permission: "not authorized" / "not authorised" / error -1743 /
      // any mention of Automation policy. The `-1743` sentinel matches the
      // osascript fallback guard at `MessageSender.swift:236`.
      if lower.contains("not authorized")
        || lower.contains("not authorised")
        || lower.contains("-1743")
        || lower.contains("automation")
      {
        return .permissionDenied
      }

      // Unknown handle: Messages.app throws "Can't get buddy ..." or
      // "... buddy ... not ..." when the recipient cannot be resolved on the
      // current service. This is a heuristic since AppleScript messages are
      // free-form; we bias toward surfacing terminal failures so the user
      // sees a meaningful dead_letter instead of 5 wasted retries.
      if lower.contains("can't get buddy") || lower.contains("cannot get buddy")
        || lower.contains("buddy") && (lower.contains("not") || lower.contains("unknown"))
      {
        return .unknownHandle
      }

      return .transient
    }
  }

#endif
