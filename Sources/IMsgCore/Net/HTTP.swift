import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

#if canImport(CryptoKit)
  import CryptoKit
#endif

// MARK: - Public surface
//
// `HTTP` is a minimal outbound HTTP client built on top of `URLSession`.
// It exists to back the rules engine webhook action (`docs/rules.md`), the
// compose pipeline (`docs/compose.md`), and the enrichment unfurl step
// (`docs/enrichment.md`) — three call sites that all want the same
// behaviour: HTTPS-only by default, a short timeout, a small bounded
// retry policy with jitter, an upper bound on the response body size,
// a denylist of transport-control headers, and optional HMAC-SHA256
// signing of the request body.
//
// The dependency graph stays clean: stdlib `URLSession` + `CryptoKit`
// only, no third-party packages. The transport is abstracted behind
// `HTTPTransport` so tests can drive the helper without touching the
// network.

public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
  public struct URLSessionTransport: HTTPTransport, @unchecked Sendable {
    public let session: URLSession

    public init(session: URLSession = .shared) {
      self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw HTTPError.missingResponse
      }
      return (data, http)
    }
  }
#else
  /// Stub on non-Apple platforms. The Linux build of `IMsgCore` exists
  /// so the `imsg` CLI compiles; the network-using callers (rules
  /// webhook, unfurl enrichment, compose) are not wired into the Linux
  /// test surface. Calling `send` returns a `transport` error so misuse
  /// is loud rather than silent.
  public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
      _ = request
      throw HTTPError.transport("URLSessionTransport is not available on this platform")
    }
  }
#endif

public struct RetryPolicy: Sendable, Equatable {
  public var maxAttempts: Int
  public var baseDelay: TimeInterval
  public var maxDelay: TimeInterval
  public var jitter: TimeInterval

  public init(
    maxAttempts: Int = 3,
    baseDelay: TimeInterval = 1.0,
    maxDelay: TimeInterval = 8.0,
    jitter: TimeInterval = 0.25
  ) {
    self.maxAttempts = maxAttempts
    self.baseDelay = baseDelay
    self.maxDelay = maxDelay
    self.jitter = jitter
  }

  public static let `default` = RetryPolicy()
  public static let none = RetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0, jitter: 0)
}

public struct HTTPRequest: Sendable {
  public var url: URL
  public var method: String
  public var headers: [String: String]
  public var body: Data?
  public var timeout: TimeInterval
  public var maxResponseBytes: Int
  public var retryPolicy: RetryPolicy
  public var hmacSecret: Data?
  public var allowInsecureScheme: Bool

  public init(
    url: URL,
    method: String = "POST",
    headers: [String: String] = [:],
    body: Data? = nil,
    timeout: TimeInterval = 10,
    maxResponseBytes: Int = 1_048_576,
    retryPolicy: RetryPolicy = .default,
    hmacSecret: Data? = nil,
    allowInsecureScheme: Bool = false
  ) {
    self.url = url
    self.method = method
    self.headers = headers
    self.body = body
    self.timeout = timeout
    self.maxResponseBytes = maxResponseBytes
    self.retryPolicy = retryPolicy
    self.hmacSecret = hmacSecret
    self.allowInsecureScheme = allowInsecureScheme
  }
}

public struct HTTPResponse: Sendable, Equatable {
  public let status: Int
  public let headers: [String: String]
  public let body: Data

  public init(status: Int, headers: [String: String], body: Data) {
    self.status = status
    self.headers = headers
    self.body = body
  }
}

public enum HTTPError: Error, Equatable, Sendable {
  case insecureScheme
  case responseTooLarge(limit: Int, actual: Int)
  case missingResponse
  case nonRetryableStatus(Int)
  case retriesExhausted(lastStatus: Int?)
  case transport(String)
}

/// Headers that the transport layer manages itself — URLSession will
/// drop or overwrite these, so silently filtering them keeps caller
/// intent honest.
private let disallowedHeaders: Set<String> = [
  "host",
  "content-length",
  "connection",
  "transfer-encoding",
  "upgrade",
  "te",
  "trailer",
  "keep-alive",
  "proxy-connection",
  "proxy-authenticate",
  "proxy-authorization",
]

public struct HTTP: Sendable {
  private let transport: HTTPTransport
  private let sleeper: @Sendable (UInt64) async throws -> Void
  private let timestamp: @Sendable () -> Int

  public init(
    transport: HTTPTransport = URLSessionTransport(),
    sleeper: @escaping @Sendable (UInt64) async throws -> Void = { nanos in
      try await Task.sleep(nanoseconds: nanos)
    },
    timestamp: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }
  ) {
    self.transport = transport
    self.sleeper = sleeper
    self.timestamp = timestamp
  }

  public func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
    if !request.allowInsecureScheme {
      guard request.url.scheme?.lowercased() == "https" else {
        throw HTTPError.insecureScheme
      }
    }

    let urlRequest = makeURLRequest(from: request)
    var attempt = 0
    var lastStatus: Int? = nil
    let maxAttempts = max(1, request.retryPolicy.maxAttempts)

    while attempt < maxAttempts {
      attempt += 1
      do {
        let (data, http) = try await transport.send(urlRequest)
        lastStatus = http.statusCode

        if (200..<300).contains(http.statusCode) {
          if data.count > request.maxResponseBytes {
            throw HTTPError.responseTooLarge(limit: request.maxResponseBytes, actual: data.count)
          }
          return HTTPResponse(
            status: http.statusCode,
            headers: stringHeaders(from: http),
            body: data
          )
        }

        if shouldRetry(status: http.statusCode) {
          if attempt < maxAttempts {
            try await sleepBackoff(attempt: attempt, policy: request.retryPolicy)
            continue
          }
          break  // exhausted
        }
        throw HTTPError.nonRetryableStatus(http.statusCode)
      } catch let error as HTTPError {
        throw error
      } catch {
        if attempt < maxAttempts {
          try await sleepBackoff(attempt: attempt, policy: request.retryPolicy)
          continue
        }
        throw HTTPError.transport(String(describing: error))
      }
    }
    throw HTTPError.retriesExhausted(lastStatus: lastStatus)
  }

  // MARK: - Helpers

  private func makeURLRequest(from request: HTTPRequest) -> URLRequest {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method
    urlRequest.timeoutInterval = request.timeout
    urlRequest.httpBody = request.body

    for (name, value) in request.headers where !disallowedHeaders.contains(name.lowercased()) {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }

    if let secret = request.hmacSecret {
      let body = request.body ?? Data()
      let signature = hmacSHA256Hex(body: body, secret: secret)
      urlRequest.setValue("sha256=\(signature)", forHTTPHeaderField: "X-Imsg-Signature")
      urlRequest.setValue("\(timestamp())", forHTTPHeaderField: "X-Imsg-Timestamp")
    }

    return urlRequest
  }

  private func shouldRetry(status: Int) -> Bool {
    return status == 408 || status == 429 || (500..<600).contains(status)
  }

  private func sleepBackoff(attempt: Int, policy: RetryPolicy) async throws {
    let exponent = pow(2.0, Double(attempt - 1))
    let exponential = policy.baseDelay * exponent
    let capped = policy.maxDelay > 0 ? min(exponential, policy.maxDelay) : exponential
    let jitterAmount = policy.jitter > 0 ? Double.random(in: 0...policy.jitter) : 0
    let total = max(0, capped + jitterAmount)
    let nanos = UInt64(total * 1_000_000_000)
    try await sleeper(nanos)
  }

  private func stringHeaders(from response: HTTPURLResponse) -> [String: String] {
    var result: [String: String] = [:]
    for (key, value) in response.allHeaderFields {
      if let name = key as? String, let stringValue = value as? String {
        result[name] = stringValue
      }
    }
    return result
  }
}

// MARK: - HMAC

private func hmacSHA256Hex(body: Data, secret: Data) -> String {
  #if canImport(CryptoKit)
    let key = SymmetricKey(data: secret)
    let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
    return mac.map { String(format: "%02x", $0) }.joined()
  #else
    // Non-Apple platforms (CI Linux build of the package surface).
    // Rules / webhook code is gated to macOS so this branch is never
    // exercised at runtime; satisfying the compiler is enough.
    _ = body
    _ = secret
    return ""
  #endif
}
