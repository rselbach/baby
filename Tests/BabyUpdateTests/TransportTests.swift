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
    var chunks: [Data]? = nil
    var suspendAfterBody: (@Sendable () -> Void)? = nil
    var onStop: (@Sendable () -> Void)? = nil
  }

  private static let handlers = OSAllocatedUnfairLock<
    [String: @Sendable (URLRequest) throws -> Response]
  >(initialState: [:])
  private let onStop = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

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
      if let stop = result.onStop {
        onStop.withLock { $0 = stop }
      }
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
      if let chunks = result.chunks {
        for chunk in chunks where !chunk.isEmpty {
          client?.urlProtocol(self, didLoad: chunk)
        }
      } else if !result.body.isEmpty {
        client?.urlProtocol(self, didLoad: result.body)
      }
      if let onSuspended = result.suspendAfterBody {
        onSuspended()
        return
      }
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {
    let stop = onStop.withLock { cb -> (@Sendable () -> Void)? in
      let current = cb
      cb = nil
      return current
    }
    stop?()
  }
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
  // a stalled download fails after a minute; a slow one gets 15 minutes
  #expect(capturedDownloadConfig.withLock { $0?.timeoutIntervalForRequest } == 60)
  #expect(capturedDownloadConfig.withLock { $0?.timeoutIntervalForResource } == 900)

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

@Test func downloadsMultiChunkPayloadAndRejectsOverflowMidChunk() async throws {
  let root = FileManager.default.temporaryDirectory
    .appending(path: "transport-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { Installer.remove(root) }

  let chunks = [
    Data(repeating: 0x41, count: 40 * 1024),
    Data(repeating: 0x42, count: 50 * 1024),
    Data(repeating: 0x43, count: 30 * 1024),
  ]
  let payload = chunks.reduce(into: Data()) { $0.append($1) }
  let url = UpdateConfig.artifactPrefix + "v1.0.0/Baby-multi.zip"
  let artifact = Artifact(
    arch: "arm64", minimumOS: "14.0", url: url, size: Int64(payload.count),
    sha256: sha256(payload))

  let okToken = "multi-ok-\(UUID().uuidString)"
  defer { MockURLProtocol.unregister(okToken) }
  let okTransport = makeMockTransport(okToken) { _ in
    .init(chunks: chunks)
  }
  let okDest = root.appending(path: "multi.zip")
  try await okTransport.download(artifact, to: okDest)
  #expect(try Data(contentsOf: okDest) == payload)

  // Exceeding the limit mid-chunk rejects with .tooLarge and removes the file
  let smallExpected = Data("0123456789".utf8)
  let smallArtifact = Artifact(
    arch: "arm64", minimumOS: "14.0", url: url, size: Int64(smallExpected.count),
    sha256: sha256(smallExpected))

  let overflowToken = "multi-overflow-\(UUID().uuidString)"
  defer { MockURLProtocol.unregister(overflowToken) }
  let overflowTransport = makeMockTransport(overflowToken) { _ in
    .init(chunks: [Data("012345".utf8), Data("6789EXTRA".utf8), Data("MORE".utf8)])
  }
  let overflowDest = root.appending(path: "overflow.zip")
  await #expect(throws: TransportError.tooLarge) {
    try await overflowTransport.download(smallArtifact, to: overflowDest)
  }
  #expect(!FileManager.default.fileExists(atPath: overflowDest.path))

  // Content-Length above limit rejects before streaming body
  let headerToken = "header-overflow-\(UUID().uuidString)"
  defer { MockURLProtocol.unregister(headerToken) }
  let headerTransport = makeMockTransport(headerToken) { _ in
    .init(headers: ["Content-Length": "11"], body: Data("01234".utf8))
  }
  let headerDest = root.appending(path: "header-overflow.zip")
  await #expect(throws: TransportError.tooLarge) {
    try await headerTransport.download(smallArtifact, to: headerDest)
  }
  #expect(!FileManager.default.fileExists(atPath: headerDest.path))
}

@Test func cancelsInFlightAndPreCancelledDownloads() async throws {
  let root = FileManager.default.temporaryDirectory
    .appending(path: "transport-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { Installer.remove(root) }

  let payload = Data("0123456789".utf8)
  let url = UpdateConfig.artifactPrefix + "v1.0.0/Baby-cancel.zip"
  let artifact = Artifact(
    arch: "arm64", minimumOS: "14.0", url: url, size: Int64(payload.count),
    sha256: sha256(payload))

  // In-flight cancellation stops the URLSessionDataTask and removes the partial file
  let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
  let (stopped, stoppedContinuation) = AsyncStream.makeStream(of: Void.self)
  let token = "cancel-inflight-\(UUID().uuidString)"
  defer { MockURLProtocol.unregister(token) }
  let transport = makeMockTransport(token) { _ in
    .init(
      chunks: [Data("0123".utf8)],
      suspendAfterBody: {
        startedContinuation.yield()
        startedContinuation.finish()
      },
      onStop: {
        stoppedContinuation.yield()
        stoppedContinuation.finish()
      }
    )
  }

  let dest = root.appending(path: "inflight.zip")
  let downloadTask = Task {
    try await transport.download(artifact, to: dest)
  }
  for await _ in started {}
  downloadTask.cancel()
  let inFlightError = await #expect(throws: URLError.self) {
    try await downloadTask.value
  }
  #expect(inFlightError?.code == .cancelled)
  let didStop = await withTaskGroup(of: Bool.self) { group in
    group.addTask {
      for await _ in stopped { return true }
      return false
    }
    group.addTask {
      try? await Task.sleep(for: .seconds(5))
      return false
    }
    let first = await group.next() ?? false
    group.cancelAll()
    return first
  }
  #expect(didStop)
  #expect(!FileManager.default.fileExists(atPath: dest.path))

  // Pre-cancelled task fails with URLError.cancelled without starting the request
  let called = OSAllocatedUnfairLock(initialState: false)
  let preToken = "cancel-pre-\(UUID().uuidString)"
  defer { MockURLProtocol.unregister(preToken) }
  let preTransport = makeMockTransport(preToken) { _ in
    called.withLock { $0 = true }
    return .init(body: payload)
  }
  let preDest = root.appending(path: "precancel.zip")
  let preCancelled = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    try await preTransport.download(artifact, to: preDest)
  }
  let preError = await #expect(throws: URLError.self) {
    try await preCancelled.value
  }
  #expect(preError?.code == .cancelled)
  #expect(!called.withLock { $0 })
  #expect(!FileManager.default.fileExists(atPath: preDest.path))
}
