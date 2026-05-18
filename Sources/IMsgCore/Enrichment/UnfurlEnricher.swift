import Foundation

/// Fetches every HTTPS URL in a message body and emits a compact
/// `unfurl` field with the page `title`, optional Open Graph
/// `og:title` / `og:description` / `og:image`, and the canonical URL.
/// Uses the W3.H `HTTP` helper so requests are HTTPS-only, retried,
/// size-capped, and obey the standard transport-header denylist.
public struct UnfurlEnricher: Enricher {
  public let name = "unfurl"

  private let http: HTTP
  private let maxLinks: Int

  public init(http: HTTP = HTTP(), maxLinks: Int = 3) {
    self.http = http
    self.maxLinks = maxLinks
  }

  public func enrich(_ context: EnrichmentContext) async throws -> EnrichmentResult {
    let text = context.message.text
    guard !text.isEmpty else { return EnrichmentResult() }
    let links = Self.extractHTTPSURLs(from: text).prefix(maxLinks)
    if links.isEmpty { return EnrichmentResult() }

    var unfurls: [EnrichmentValue] = []
    for url in links {
      do {
        let request = HTTPRequest(
          url: url,
          method: "GET",
          headers: ["User-Agent": "imsg-unfurl/1.0"],
          maxResponseBytes: 256 * 1024,
          retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0, jitter: 0)
        )
        let response = try await http.perform(request)
        guard let html = String(data: response.body, encoding: .utf8) else { continue }
        let parsed = HTMLMetaScraper.scrape(html)
        var entry: [String: EnrichmentValue] = ["url": .string(url.absoluteString)]
        if let title = parsed.title { entry["title"] = .string(title) }
        if let ogTitle = parsed.ogTitle { entry["og_title"] = .string(ogTitle) }
        if let ogDesc = parsed.ogDescription { entry["og_description"] = .string(ogDesc) }
        if let ogImage = parsed.ogImage { entry["og_image"] = .string(ogImage) }
        unfurls.append(.dictionary(entry))
      } catch {
        // A single failing link should not poison the chain.
        continue
      }
    }
    if unfurls.isEmpty { return EnrichmentResult() }
    return EnrichmentResult(fields: [
      EnrichmentField(key: "unfurl", value: .array(unfurls))
    ])
  }

  static func extractHTTPSURLs(from text: String) -> [URL] {
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
      guard
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
      else { return [] }
      let matches = detector.matches(
        in: text, options: [], range: NSRange(text.startIndex..., in: text))
      var seen: Set<String> = []
      var urls: [URL] = []
      for match in matches {
        guard let url = match.url else { continue }
        guard url.scheme?.lowercased() == "https" else { continue }
        let key = url.absoluteString
        if !seen.insert(key).inserted { continue }
        urls.append(url)
      }
      return urls
    #else
      // `NSDataDetector` is unavailable on swift-corelibs-foundation.
      // Fall back to a simple regex; this code path exists only so the
      // Linux build of `IMsgCore` compiles, and unfurl is not wired
      // into any Linux command surface.
      guard let regex = try? NSRegularExpression(pattern: #"https://[^\s]+"#) else { return [] }
      let nsRange = NSRange(text.startIndex..., in: text)
      var seen: Set<String> = []
      var urls: [URL] = []
      for match in regex.matches(in: text, options: [], range: nsRange) {
        guard let range = Range(match.range, in: text) else { continue }
        let candidate = String(text[range])
        guard let url = URL(string: candidate) else { continue }
        let key = url.absoluteString
        if !seen.insert(key).inserted { continue }
        urls.append(url)
      }
      return urls
    #endif
  }
}

// MARK: - Minimal HTML scraper
//
// The unfurl path only needs <title> and a handful of meta tags. Pulling
// in a third-party HTML parser for this is overkill, so we do regex-based
// extraction of exactly the fields we use. Anything fancier (proper DOM
// walking, character-set negotiation, robots.txt) is out of scope.

struct HTMLMetaResult: Equatable {
  let title: String?
  let ogTitle: String?
  let ogDescription: String?
  let ogImage: String?
}

enum HTMLMetaScraper {
  static func scrape(_ html: String) -> HTMLMetaResult {
    let title = matchTitle(html)
    let ogTitle = matchMetaContent(html, property: "og:title")
    let ogDescription = matchMetaContent(html, property: "og:description")
    let ogImage = matchMetaContent(html, property: "og:image")
    return HTMLMetaResult(
      title: title, ogTitle: ogTitle, ogDescription: ogDescription, ogImage: ogImage
    )
  }

  private static func matchTitle(_ html: String) -> String? {
    guard
      let regex = try? NSRegularExpression(
        pattern: "<title[^>]*>(.*?)</title>",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
      )
    else { return nil }
    let range = NSRange(html.startIndex..., in: html)
    guard let match = regex.firstMatch(in: html, options: [], range: range),
      let valueRange = Range(match.range(at: 1), in: html)
    else { return nil }
    return collapseWhitespace(decodeEntities(String(html[valueRange])))
  }

  private static func matchMetaContent(_ html: String, property: String) -> String? {
    // Order-independent: try property="x" content="y" and content="y" property="x".
    let pattern = #"<meta\b[^>]*?(?:property|name)=["']\#(property)["'][^>]*?content=["']([^"']*)["']"#
    let altPattern = #"<meta\b[^>]*?content=["']([^"']*)["'][^>]*?(?:property|name)=["']\#(property)["']"#
    if let value = firstCapture(in: html, pattern: pattern) { return value }
    if let value = firstCapture(in: html, pattern: altPattern) { return value }
    return nil
  }

  private static func firstCapture(in html: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else { return nil }
    let range = NSRange(html.startIndex..., in: html)
    guard let match = regex.firstMatch(in: html, options: [], range: range),
      match.numberOfRanges > 1,
      let valueRange = Range(match.range(at: 1), in: html)
    else { return nil }
    return decodeEntities(String(html[valueRange]))
  }

  private static func decodeEntities(_ string: String) -> String {
    string
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'")
      .replacingOccurrences(of: "&apos;", with: "'")
  }

  private static func collapseWhitespace(_ string: String) -> String {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    let components = trimmed.split(whereSeparator: { $0.isWhitespace })
    return components.joined(separator: " ")
  }
}
