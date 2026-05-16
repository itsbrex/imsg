import Foundation
import Testing

@testable import IMsgCore

// MARK: - Chain

private struct StubEnricher: Enricher {
  let name: String
  let fields: [EnrichmentField]
  func enrich(_ context: EnrichmentContext) async throws -> EnrichmentResult {
    EnrichmentResult(fields: fields)
  }
}

private struct ThrowingEnricher: Enricher {
  let name: String
  struct Boom: Error {}
  func enrich(_ context: EnrichmentContext) async throws -> EnrichmentResult {
    throw Boom()
  }
}

private let sampleMessage = Message(
  rowID: 1, chatID: 1, sender: "+555", text: "hello",
  date: Date(timeIntervalSince1970: 1_700_000_000),
  isFromMe: false, service: "iMessage", handleID: nil, attachmentsCount: 0
)

@Test
func chainMergesResultsInOrder() async throws {
  let chain = EnrichmentChain([
    StubEnricher(name: "a", fields: [EnrichmentField(key: "x", value: .string("1"))]),
    StubEnricher(name: "b", fields: [EnrichmentField(key: "y", value: .string("2"))]),
  ])
  let result = await chain.run(EnrichmentContext(message: sampleMessage))
  #expect(result.fields.map(\.key) == ["x", "y"])
}

@Test
func chainSkipsFailingEnrichers() async throws {
  let chain = EnrichmentChain([
    StubEnricher(name: "a", fields: [EnrichmentField(key: "x", value: .string("1"))]),
    ThrowingEnricher(name: "b"),
    StubEnricher(name: "c", fields: [EnrichmentField(key: "z", value: .string("3"))]),
  ])
  var captured: [String] = []
  let lock = NSLock()
  let result = await chain.run(EnrichmentContext(message: sampleMessage)) { name, _ in
    lock.lock(); defer { lock.unlock() }
    captured.append(name)
  }
  #expect(result.fields.map(\.key) == ["x", "z"])
  #expect(captured == ["b"])
}

// MARK: - Unfurl + HTML scraper

@Test
func htmlScraperExtractsTitleAndOGFields() {
  let html = """
    <!doctype html>
    <html><head>
      <title>  Hello   World  </title>
      <meta property="og:title" content="Welcome &amp; Hello" />
      <meta name="og:description" content="The page about hello" />
      <meta content="https://img.example.com/x.png" property="og:image" />
    </head></html>
    """
  let result = HTMLMetaScraper.scrape(html)
  #expect(result.title == "Hello World")
  #expect(result.ogTitle == "Welcome & Hello")
  #expect(result.ogDescription == "The page about hello")
  #expect(result.ogImage == "https://img.example.com/x.png")
}

@Test
func htmlScraperReturnsNilsWhenAbsent() {
  let result = HTMLMetaScraper.scrape("<html><body>no head here</body></html>")
  #expect(result.title == nil)
  #expect(result.ogTitle == nil)
}

@Test
func unfurlExtractorPicksOnlyHTTPSURLs() {
  let text = """
    visit https://example.com/a and http://insecure.test/b
    or https://example.com/c?q=1#frag
    """
  let urls = UnfurlEnricher.extractHTTPSURLs(from: text)
  let strings = urls.map { $0.absoluteString }
  #expect(strings.contains("https://example.com/a"))
  #expect(strings.contains("https://example.com/c?q=1#frag"))
  #expect(!strings.contains { $0.hasPrefix("http://") })
}

// MARK: - Unfurl over a fake HTTP transport

private final class FakeUnfurlTransport: HTTPTransport, @unchecked Sendable {
  enum Step: Sendable {
    case ok(Data)
    case fail(Error)
  }
  private let lock = NSLock()
  private var responses: [URL: Step] = [:]
  init(_ map: [URL: Step]) { self.responses = map }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    lock.lock(); defer { lock.unlock() }
    let url = request.url!
    guard let step = responses[url] else {
      throw NSError(domain: "FakeUnfurl", code: 404)
    }
    switch step {
    case .ok(let data):
      let response = HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "text/html"]
      )!
      return (data, response)
    case .fail(let error):
      throw error
    }
  }
}

@Test
func unfurlProducesEntryForResolvedLink() async throws {
  let url = URL(string: "https://example.com/post")!
  let html = """
    <html><head><title>Sample Page</title>
    <meta property="og:title" content="OG Sample"></head></html>
    """
  let transport = FakeUnfurlTransport([url: .ok(Data(html.utf8))])
  let http = HTTP(transport: transport, sleeper: { _ in })
  let enricher = UnfurlEnricher(http: http)

  let message = Message(
    rowID: 2, chatID: 1, sender: "+555",
    text: "check this https://example.com/post",
    date: Date(), isFromMe: false, service: "iMessage",
    handleID: nil, attachmentsCount: 0
  )
  let result = try await enricher.enrich(EnrichmentContext(message: message))
  let dict = result.toDictionary()
  guard case .array(let entries) = dict["unfurl"] else {
    Issue.record("expected unfurl array")
    return
  }
  #expect(entries.count == 1)
  guard case .dictionary(let entry) = entries.first! else {
    Issue.record("expected entry dict")
    return
  }
  #expect(entry["title"] == .string("Sample Page"))
  #expect(entry["og_title"] == .string("OG Sample"))
}

@Test
func unfurlReturnsEmptyWhenNoLinks() async throws {
  let enricher = UnfurlEnricher(http: HTTP(transport: FakeUnfurlTransport([:]), sleeper: { _ in }))
  let message = Message(
    rowID: 3, chatID: 1, sender: "+555", text: "no links",
    date: Date(), isFromMe: false, service: "iMessage",
    handleID: nil, attachmentsCount: 0
  )
  let result = try await enricher.enrich(EnrichmentContext(message: message))
  #expect(result.fields.isEmpty)
}

// MARK: - Transcript

@Test
func transcriptEnricherEmitsFieldWhenProviderHasContent() async throws {
  let enricher = TranscriptEnricher { _ in "hello voice memo" }
  let message = Message(
    rowID: 4, chatID: 1, sender: "+555", text: "",
    date: Date(), isFromMe: false, service: "iMessage",
    handleID: nil, attachmentsCount: 1
  )
  let result = try await enricher.enrich(EnrichmentContext(message: message))
  #expect(result.fields.first?.key == "transcript")
  #expect(result.fields.first?.value == .string("hello voice memo"))
}

@Test
func transcriptEnricherSkipsMessagesWithoutAttachments() async throws {
  let enricher = TranscriptEnricher { _ in "would be unused" }
  let message = Message(
    rowID: 5, chatID: 1, sender: "+555", text: "",
    date: Date(), isFromMe: false, service: "iMessage",
    handleID: nil, attachmentsCount: 0
  )
  let result = try await enricher.enrich(EnrichmentContext(message: message))
  #expect(result.fields.isEmpty)
}

@Test
func transcriptEnricherTreatsEmptyStringAsAbsent() async throws {
  let enricher = TranscriptEnricher { _ in "" }
  let message = Message(
    rowID: 6, chatID: 1, sender: "+555", text: "",
    date: Date(), isFromMe: false, service: "iMessage",
    handleID: nil, attachmentsCount: 1
  )
  let result = try await enricher.enrich(EnrichmentContext(message: message))
  #expect(result.fields.isEmpty)
}
