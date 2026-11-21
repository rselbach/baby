import CryptoKit
import Foundation
import os

/// Why a fetch or download failed.
public enum TransportError: LocalizedError, Equatable {
  case disallowedURL(String)
  case status(Int)
  case tooLarge
  case sizeMismatch
  case hashMismatch

  public var errorDescription: String? {
    switch self {
    case .disallowedURL(let url): "Refused to fetch \(url)."
    case .status(let code): "The server answered with HTTP \(code)."
    case .tooLarge: "The server sent more data than expected."
    case .sizeMismatch: "The download is not the expected size."
    case .hashMismatch: "The download does not match its signed checksum."
    }
  }
}

/// Fetches the feed and artifacts over HTTPS from the allowed hosts only.
/// The signed size and checksum are the trust anchor, not the host.
public struct Transport: Sendable {
  /// The User-Agent sent with every request.
  public let userAgent: String
  /// How long a download may go without receiving data before it fails.
  public static let downloadIdleTimeout: TimeInterval = 60
  /// How long a whole download may take, so a slow connection can still
  /// finish one while a stalled one fails at the idle timeout.
  public static let downloadTotalTimeout: TimeInterval = 15 * 60
  private let makeConfiguration: @Sendable () -> URLSessionConfiguration

  public init(userAgent: String) {
    self.init(userAgent: userAgent, makeConfiguration: { .ephemeral })
  }

  init(
    userAgent: String,
    makeConfiguration: @escaping @Sendable () -> URLSessionConfiguration
  ) {
    self.userAgent = userAgent
    self.makeConfiguration = makeConfiguration
  }

  /// Whether `url` is an HTTPS URL on an allowed host without credentials or a
  /// non-default port.
  public static func isAllowed(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https",
      url.port == nil,
      let host = url.host()?.lowercased(),
      UpdateConfig.allowedHosts.contains(host)
    else { return false }
    return url.user() == nil && url.password() == nil
  }

  /// Fetches the feed's bytes, refusing anything larger than a feed can be.
  @concurrent
  public func fetchFeed(timeout: TimeInterval = 60) async throws -> Data {
    let data = OSAllocatedUnfairLock(initialState: Data())
    try await stream(
      UpdateConfig.feedURL, idleTimeout: timeout, totalTimeout: timeout,
      limit: Int64(Feed.maxBytes)
    ) { chunk in
      data.withLock { $0.append(chunk) }
    }
    return data.withLock { $0 }
  }

  /// Downloads `artifact` to `destination` and checks its signed size and
  /// SHA-256. Removes the file if anything goes wrong.
  @concurrent
  public func download(_ artifact: Artifact, to destination: URL) async throws {
    guard let url = URL(string: artifact.url) else {
      throw TransportError.disallowedURL(artifact.url)
    }
    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
    }
    do {
      let handle = try FileHandle(forWritingTo: destination)
      let sink = OSAllocatedUnfairLock(
        uncheckedState: (handle: handle, hasher: SHA256(), written: Int64(0)))
      defer { try? sink.withLockUnchecked { try $0.handle.close() } }
      try await stream(
        url, idleTimeout: Self.downloadIdleTimeout, totalTimeout: Self.downloadTotalTimeout,
        limit: artifact.size
      ) { chunk in
        try sink.withLockUnchecked { state in
          state.hasher.update(data: chunk)
          try state.handle.write(contentsOf: chunk)
          state.written += Int64(chunk.count)
        }
      }
      let (written, digest) = sink.withLockUnchecked { state in
        (state.written, state.hasher.finalize().map { String(format: "%02x", $0) }.joined())
      }
      guard written == artifact.size else { throw TransportError.sizeMismatch }
      guard digest == artifact.sha256 else { throw TransportError.hashMismatch }
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
  }

  // stream GETs url and hands its body to consume in chunks, failing once
  // more than limit bytes arrive, no data arrives for idleTimeout, or the
  // whole transfer takes longer than totalTimeout.
  private func stream(
    _ url: URL, idleTimeout: TimeInterval, totalTimeout: TimeInterval, limit: Int64,
    consume: @escaping @Sendable (Data) throws -> Void
  ) async throws {
    guard Self.isAllowed(url) else { throw TransportError.disallowedURL(url.absoluteString) }
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: idleTimeout)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    let configuration = makeConfiguration()
    configuration.timeoutIntervalForRequest = idleTimeout
    configuration.timeoutIntervalForResource = totalTimeout
    let delegate = StreamDelegate(limit: limit, consume: consume)
    let session = URLSession(
      configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }

    let task = session.dataTask(with: request)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        delegate.start(task: task, continuation: continuation)
      }
    } onCancel: {
      if delegate.markCancelled() {
        task.cancel()
      }
    }
  }
}

// StreamDelegate enforces the redirect policy, HTTP 200 status, and byte limit
// while forwarding response chunks directly to `consume` on the session's
// serial delegate queue.
private final class StreamDelegate: NSObject, URLSessionDataDelegate, Sendable {
  private struct State: Sendable {
    var continuation: CheckedContinuation<Void, any Error>?
    var receivedResponse = false
    var total: Int64 = 0
    var failure: (any Error)?
    var cancelled = false
  }

  private let limit: Int64
  private let consume: @Sendable (Data) throws -> Void
  private let state = OSAllocatedUnfairLock(initialState: State())

  init(limit: Int64, consume: @escaping @Sendable (Data) throws -> Void) {
    self.limit = limit
    self.consume = consume
  }

  func start(task: URLSessionDataTask, continuation: CheckedContinuation<Void, any Error>) {
    let shouldResume = state.withLock { state -> Bool in
      if state.cancelled { return false }
      state.continuation = continuation
      return true
    }
    guard shouldResume else {
      continuation.resume(throwing: URLError(.cancelled))
      return
    }
    task.resume()
  }

  func markCancelled() -> Bool {
    state.withLock { state in
      state.cancelled = true
      return state.continuation != nil
    }
  }

  private func recordFailure(_ error: any Error) {
    state.withLock { state in
      if state.failure == nil {
        state.failure = error
      }
    }
  }

  private func finish(response: URLResponse?, error: (any Error)?) {
    let result = state.withLock {
      state -> (CheckedContinuation<Void, any Error>, Result<Void, any Error>)? in
      guard let continuation = state.continuation else { return nil }
      state.continuation = nil

      if let failure = state.failure {
        return (continuation, .failure(failure))
      }
      if let error {
        return (continuation, .failure(error))
      }
      if state.cancelled {
        return (continuation, .failure(URLError(.cancelled)))
      }
      if !state.receivedResponse {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (continuation, .failure(TransportError.status(status)))
      }
      return (continuation, .success(()))
    }
    if let (continuation, outcome) = result {
      continuation.resume(with: outcome)
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    let stopped = state.withLock { $0.cancelled || $0.failure != nil }
    guard !stopped else {
      completionHandler(nil)
      return
    }
    guard let url = request.url, Transport.isAllowed(url) else {
      recordFailure(TransportError.status(response.statusCode))
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    let disposition = state.withLock { state -> URLSession.ResponseDisposition in
      guard !state.cancelled, state.failure == nil else { return .cancel }
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard status == 200 else {
        state.failure = TransportError.status(status)
        return .cancel
      }
      if response.expectedContentLength > limit {
        state.failure = TransportError.tooLarge
        return .cancel
      }
      state.receivedResponse = true
      return .allow
    }
    completionHandler(disposition)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard !data.isEmpty else { return }
    enum Action { case consume, ignore, tooLarge }
    let action = state.withLock { state -> Action in
      guard state.receivedResponse, !state.cancelled, state.failure == nil else { return .ignore }
      let chunkSize = Int64(data.count)
      guard chunkSize <= limit - state.total else {
        state.failure = TransportError.tooLarge
        return .tooLarge
      }
      state.total += chunkSize
      return .consume
    }
    switch action {
    case .ignore:
      return
    case .tooLarge:
      dataTask.cancel()
    case .consume:
      do {
        try consume(data)
      } catch {
        recordFailure(error)
        dataTask.cancel()
      }
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    finish(response: task.response, error: error)
  }

  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
    finish(response: nil, error: error ?? URLError(.cancelled))
  }
}
