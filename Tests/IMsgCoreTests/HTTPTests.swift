import Foundation
import Testing

@testable import IMsgCore

// MARK: - Mock transport

private final class MockTransport: HTTPTransport, @unchecked Sendable {
  enum Step {
    case response(status: Int, body: Data, headers: [String: String])
    case failure(any Error)
  }

  private let lock = NSLock()
  private var steps: [Step]
  private(set) var recordedRequests: [URLRequest] = []

  init(_ steps: [Step]) {
    self.steps = steps
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let next = try nextStep(for: request)

    switch next {
    case .response(let status, let body, let headers):
      let response = HTTPURLResponse(
        url: request.url ?? URL(string: "https://example.invalid")!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: headers
      )!
      return (body, response)
    case .failure(let error):
      throw error
    }
  }

  private func nextStep(for request: URLRequest) throws -> Step {
    lock.lock()
    defer { lock.unlock() }
    recordedRequests.append(request)
    guard !steps.isEmpty else {
      throw NSError(domain: "MockTransport", code: -1, userInfo: nil)
    }
    return steps.removeFirst()
  }
}

private func makeHTTP(_ transport: MockTransport, timestamp: Int = 1_700_000_000) -> HTTP {
  HTTP(
    transport: transport,
    sleeper: { _ in },
    timestamp: { timestamp }
  )
}

private let fastRetry = RetryPolicy(maxAttempts: 3, baseDelay: 0, maxDelay: 0, jitter: 0)

// MARK: - Tests

@Test
func rejectsInsecureSchemeByDefault() async throws {
  let http = makeHTTP(MockTransport([]))
  let request = HTTPRequest(url: URL(string: "http://example.com/x")!)
  do {
    _ = try await http.perform(request)
    Issue.record("expected throw")
  } catch let error as HTTPError {
    #expect(error == .insecureScheme)
  }
}

@Test
func allowsHTTPWhenExplicitlyEnabled() async throws {
  let transport = MockTransport([.response(status: 200, body: Data("ok".utf8), headers: [:])])
  let http = makeHTTP(transport)
  let request = HTTPRequest(
    url: URL(string: "http://example.com/x")!,
    allowInsecureScheme: true
  )
  let response = try await http.perform(request)
  #expect(response.status == 200)
  #expect(response.body == Data("ok".utf8))
}

@Test
func returnsSuccessfulResponse() async throws {
  let body = Data(#"{"ok":true}"#.utf8)
  let transport = MockTransport([
    .response(status: 200, body: body, headers: ["Content-Type": "application/json"])
  ])
  let http = makeHTTP(transport)
  let request = HTTPRequest(url: URL(string: "https://example.com/x")!)
  let response = try await http.perform(request)
  #expect(response.status == 200)
  #expect(response.body == body)
  #expect(response.headers["Content-Type"] == "application/json")
  #expect(transport.recordedRequests.count == 1)
}

@Test
func retriesOn429ThenSucceeds() async throws {
  let transport = MockTransport([
    .response(status: 429, body: Data(), headers: [:]),
    .response(status: 200, body: Data("ok".utf8), headers: [:]),
  ])
  let http = makeHTTP(transport)
  let request = HTTPRequest(
    url: URL(string: "https://example.com/x")!,
    retryPolicy: fastRetry
  )
  let response = try await http.perform(request)
  #expect(response.status == 200)
  #expect(transport.recordedRequests.count == 2)
}

@Test
func retriesOn5xxAndReportsExhaustion() async throws {
  let transport = MockTransport([
    .response(status: 503, body: Data(), headers: [:]),
    .response(status: 502, body: Data(), headers: [:]),
    .response(status: 500, body: Data(), headers: [:]),
  ])
  let http = makeHTTP(transport)
  let request = HTTPRequest(
    url: URL(string: "https://example.com/x")!,
    retryPolicy: fastRetry
  )
  do {
    _ = try await http.perform(request)
    Issue.record("expected throw")
  } catch let error as HTTPError {
    #expect(error == .retriesExhausted(lastStatus: 500))
  }
  #expect(transport.recordedRequests.count == 3)
}

@Test
func failsImmediatelyOn4xx() async throws {
  let transport = MockTransport([
    .response(status: 404, body: Data(), headers: [:])
  ])
  let http = makeHTTP(transport)
  let request = HTTPRequest(
    url: URL(string: "https://example.com/x")!,
    retryPolicy: fastRetry
  )
  do {
    _ = try await http.perform(request)
    Issue.record("expected throw")
  } catch let error as HTTPError {
    #expect(error == .nonRetryableStatus(404))
  }
  #expect(transport.recordedRequests.count == 1)
}

@Test
func retriesTransportErrorsAndReportsLast() async throws {
  struct Boom: Error {}
  let transport = MockTransport([
    .failure(Boom()),
    .failure(Boom()),
    .failure(Boom()),
  ])
  let http = makeHTTP(transport)
  let request = HTTPRequest(
    url: URL(string: "https://example.com/x")!,
    retryPolicy: fastRetry
  )
  do {
    _ = try await http.perform(request)
    Issue.record("expected throw")
  } catch let error as HTTPError {
    if case .transport(let description) = error {
      #expect(description.contains("Boom"))
    } else {
      Issue.record("unexpected error: \(error)")
    }
  }
  #expect(transport.recordedRequests.count == 3)
}

@Test
func rejectsResponseLargerThanCap() async throws {
  let body = Data(repeating: 0x41, count: 2048)
  let transport = MockTransport([.response(status: 200, body: body, headers: [:])])
  let http = makeHTTP(transport)
  let request = HTTPRequest(
    url: URL(string: "https://example.com/x")!,
    maxResponseBytes: 1024
  )
  do {
    _ = try await http.perform(request)
    Issue.record("expected throw")
  } catch let error as HTTPError {
    #expect(error == .responseTooLarge(limit: 1024, actual: 2048))
  }
}

@Test
func signsBodyWithHMACWhenSecretProvided() async throws {
  let transport = MockTransport([.response(status: 200, body: Data(), headers: [:])])
  let http = makeHTTP(transport, timestamp: 1_700_000_000)
  let body = Data("payload".utf8)
  let secret = Data("topsecret".utf8)
  let request = HTTPRequest(
    url: URL(string: "https://example.com/x")!,
    body: body,
    hmacSecret: secret
  )
  _ = try await http.perform(request)

  let sent = try #require(transport.recordedRequests.first)
  let signature = try #require(sent.value(forHTTPHeaderField: "X-Imsg-Signature"))
  #expect(signature.hasPrefix("sha256="))
  // sha256 hex digest is 64 chars
  #expect(signature.count == "sha256=".count + 64)
  #expect(sent.value(forHTTPHeaderField: "X-Imsg-Timestamp") == "1700000000")
}

@Test
func stripsDisallowedTransportHeaders() async throws {
  let transport = MockTransport([.response(status: 200, body: Data(), headers: [:])])
  let http = makeHTTP(transport)
  let request = HTTPRequest(
    url: URL(string: "https://example.com/x")!,
    headers: [
      "Authorization": "Bearer abc",
      "Host": "evil.example",
      "Content-Length": "0",
      "Connection": "close",
      "Transfer-Encoding": "chunked",
    ]
  )
  _ = try await http.perform(request)
  let sent = try #require(transport.recordedRequests.first)
  #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
  #expect(sent.value(forHTTPHeaderField: "Host") == nil)
  #expect(sent.value(forHTTPHeaderField: "Content-Length") == nil)
  #expect(sent.value(forHTTPHeaderField: "Connection") == nil)
  #expect(sent.value(forHTTPHeaderField: "Transfer-Encoding") == nil)
}

@Test
func forwardsMethodAndBody() async throws {
  let transport = MockTransport([.response(status: 200, body: Data(), headers: [:])])
  let http = makeHTTP(transport)
  let body = Data("hello".utf8)
  let request = HTTPRequest(
    url: URL(string: "https://example.com/x")!,
    method: "PUT",
    body: body
  )
  _ = try await http.perform(request)
  let sent = try #require(transport.recordedRequests.first)
  #expect(sent.httpMethod == "PUT")
  #expect(sent.httpBody == body)
}
