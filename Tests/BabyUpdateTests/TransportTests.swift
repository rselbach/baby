import CryptoKit
import Foundation
import Testing
import os

@testable import BabyUpdate

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
  struct Response: Sendable {
    var status: Int = 200
    var headers: [String: String] = [:]
    var redirectTo: URL?
    var body: Data = Data()
  }

  private static let handlers = OSAllocatedUnfairLock<
    [String: @Sendable (URLRequest) throws -> Response]
  >(initialState: [:])

  static func register(
    _ token: String,
    handler: @escaping @Sendable (URLRequest) throws -> Response
  ) {
    handlers.withLock { $0[token] = handler }
  }

  static func unregister(_ token: String) {
    handlers.withLock { _ = $0.removeValue(forKey: token) }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url,
      let token = request.value(forHTTPHeaderField: "User-Agent"),
      let handler = Self.handlers.withLock({ $0[token] })
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    do {
      let result = try handler(request)
      if let target = result.redirectTo {
        var headers = result.headers
        headers["Location"] = target.absoluteString
        let response = HTTPURLResponse(
          url: url, statusCode: result.status == 200 ? 302 : result.status,
          httpVersion: "HTTP/1.1", headerFields: headers)!
        var next = URLRequest(url: target)
        next.setValue(token, forHTTPHeaderField: "User-Agent")
        client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        client?.urlProtocolDidFinishLoading(self)
        return
      }
      let response = HTTPURLResponse(
        url: url, statusCode: result.status, httpVersion: "HTTP/1.1",
        headerFields: result.headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      if !result.body.isEmpty {
        client?.urlProtocol(self, didLoad: result.body)
      }
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

func makeMockTransport(
  _ token: String,
  onConfigure: (@Sendable (URLSessionConfiguration) -> Void)? = nil,
  handler: @escaping @Sendable (URLRequest) throws -> MockURLProtocol.Response
) -> Transport {
  MockURLProtocol.register(token, handler: handler)
  return Transport(userAgent: token) {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    onConfigure?(config)
    return config
  }
}

private func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@Test func downloadsAndVerifiesArtifactAndAppliesTimeouts() async throws {
  let token = "transport-\(UUID().uuidString)"
  defer { MockURLProtocol.unregister(token) }

  let payload = Data("verified-zip-bytes".utf8)
  let url = UpdateConfig.artifactPrefix + "v1.0.0/Baby-1.0.0-macos-arm64.zip"
  let artifact = Artifact(
    arch: "arm64", minimumOS: "14.0", url: url, size: Int64(payload.count),
    sha256: sha256(payload))

  let capturedDownloadConfig = OSAllocatedUnfairLock<URLSessionConfiguration?>(
    initialState: nil)
  let transport = makeMockTransport(
    token,
    onConfigure: { config in capturedDownloadConfig.withLock { $0 = config } }
  ) { _ in
    .init(body: payload)
  }

  let root = FileManager.default.temporaryDirectory
    .appending(path: "transport-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { Installer.remove(root) }

  let dest = root.appending(path: "out.zip")
  try await transport.download(artifact, to: dest)
  #expect(try Data(contentsOf: dest) == payload)
  #expect(capturedDownloadConfig.withLock { $0?.timeoutIntervalForRequest } == 60)
  #expect(capturedDownloadConfig.withLock { $0?.timeoutIntervalForResource } == 60)

  let feedPayload = Data("small-feed".utf8)
  let feedToken = "feed-\(UUID().uuidString)"
  defer { MockURLProtocol.unregister(feedToken) }
  let capturedFeedConfig = OSAllocatedUnfairLock<URLSessionConfiguration?>(initialState: nil)
  let feedTransport = makeMockTransport(
    feedToken,
    onConfigure: { config in capturedFeedConfig.withLock { $0 = config } }
  ) { _ in
    .init(body: feedPayload)
  }
  #expect(try await feedTransport.fetchFeed(timeout: 5) == feedPayload)
  #expect(capturedFeedConfig.withLock { $0?.timeoutIntervalForRequest } == 5)
  #expect(capturedFeedConfig.withLock { $0?.timeoutIntervalForResource } == 5)
}

@Test func rejectsBadDownloadsAndCleansUpDestination() async throws {
  let root = FileManager.default.temporaryDirectory
    .appending(path: "transport-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { Installer.remove(root) }

  let expected = Data("0123456789".utf8)
  let url = UpdateConfig.artifactPrefix + "v1.0.0/Baby.zip"
  let artifact = Artifact(
    arch: "arm64", minimumOS: "14.0", url: url, size: Int64(expected.count),
    sha256: sha256(expected))

  let cases: [(MockURLProtocol.Response, TransportError)] = [
    (.init(status: 503), .status(503)),
    (.init(body: Data("0123456789EXTRA".utf8)), .tooLarge),
    (.init(body: Data("0123".utf8)), .sizeMismatch),
    (.init(body: Data("abcdefghij".utf8)), .hashMismatch),
  ]

  for (response, expectedError) in cases {
    let token = "err-\(UUID().uuidString)"
    defer { MockURLProtocol.unregister(token) }
    let transport = makeMockTransport(token) { _ in response }
    let dest = root.appending(path: "attempt.zip")
    await #expect(throws: expectedError) {
      try await transport.download(artifact, to: dest)
    }
    #expect(!FileManager.default.fileExists(atPath: dest.path))
  }
}

@Test func enforcesRedirectHostSchemeAndPortPolicy() async throws {
  let payload = Data("redirected-ok".utf8)
  let url = UpdateConfig.artifactPrefix + "v1.0.0/Baby.zip"
  let artifact = Artifact(
    arch: "arm64", minimumOS: "14.0", url: url, size: Int64(payload.count),
    sha256: sha256(payload))

  let root = FileManager.default.temporaryDirectory
    .appending(path: "transport-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { Installer.remove(root) }

  let okToken = "redir-ok-\(UUID().uuidString)"
  defer { MockURLProtocol.unregister(okToken) }
  let allowedCDN = URL(string: "https://objects.githubusercontent.com/asset/1")!
  let okTransport = makeMockTransport(okToken) { req in
    if req.url == allowedCDN { return .init(body: payload) }
    return .init(status: 302, redirectTo: allowedCDN)
  }
  let okDest = root.appending(path: "ok.zip")
  try await okTransport.download(artifact, to: okDest)
  #expect(try Data(contentsOf: okDest) == payload)

  for blocked in [
    URL(string: "https://evil.example.com/asset")!,
    URL(string: "http://objects.githubusercontent.com/asset")!,
    URL(string: "https://objects.githubusercontent.com:8443/asset")!,
  ] {
    let badToken = "redir-bad-\(UUID().uuidString)"
    defer { MockURLProtocol.unregister(badToken) }
    let followedBlockedRedirect = OSAllocatedUnfairLock(initialState: false)
    let badTransport = makeMockTransport(badToken) { req in
      if req.url == blocked {
        followedBlockedRedirect.withLock { $0 = true }
        return .init(body: payload)
      }
      return .init(status: 302, redirectTo: blocked)
    }
    let badDest = root.appending(path: "bad.zip")
    await #expect(throws: (any Error).self) {
      try await badTransport.download(artifact, to: badDest)
    }
    #expect(!followedBlockedRedirect.withLock { $0 })
    #expect(!FileManager.default.fileExists(atPath: badDest.path))
  }
}
