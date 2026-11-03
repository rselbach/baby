import CryptoKit
import Foundation

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

  public init(userAgent: String) {
    self.userAgent = userAgent
  }

  /// Whether `url` is an HTTPS URL on an allowed host without credentials.
  public static func isAllowed(_ url: URL) -> Bool {
    guard url.scheme == "https", let host = url.host(),
      UpdateConfig.allowedHosts.contains(host)
    else { return false }
    return url.user() == nil && url.password() == nil
  }

  /// Fetches the feed's bytes, refusing anything larger than a feed can be.
  @concurrent
  public func fetchFeed(timeout: TimeInterval = 60) async throws -> Data {
    var data = Data()
    try await stream(UpdateConfig.feedURL, timeout: timeout, limit: Int64(Feed.maxBytes)) {
      data.append($0)
    }
    return data
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
      defer { try? handle.close() }
      var hasher = SHA256()
      var written: Int64 = 0
      try await stream(url, timeout: 60, limit: artifact.size) { chunk in
        hasher.update(data: chunk)
        try handle.write(contentsOf: chunk)
        written += Int64(chunk.count)
      }
      guard written == artifact.size else { throw TransportError.sizeMismatch }
      let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
      guard digest == artifact.sha256 else { throw TransportError.hashMismatch }
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
  }

  // stream GETs url and hands its body to consume in chunks, failing once
  // more than limit bytes arrive.
  private func stream(
    _ url: URL, timeout: TimeInterval, limit: Int64,
    consume: (Data) throws -> Void
  ) async throws {
    guard Self.isAllowed(url) else { throw TransportError.disallowedURL(url.absoluteString) }
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    let session = URLSession(
      configuration: .ephemeral, delegate: RedirectPolicy(), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }

    let (bytes, response) = try await session.bytes(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw TransportError.status(status) }
    if response.expectedContentLength > limit { throw TransportError.tooLarge }

    var buffer = Data()
    buffer.reserveCapacity(64 * 1024)
    var total: Int64 = 0
    for try await byte in bytes {
      total += 1
      guard total <= limit else { throw TransportError.tooLarge }
      buffer.append(byte)
      if buffer.count == 64 * 1024 {
        try consume(buffer)
        buffer.removeAll(keepingCapacity: true)
      }
    }
    if !buffer.isEmpty { try consume(buffer) }
  }
}

// RedirectPolicy follows redirects only to allowed HTTPS hosts; a refused
// redirect surfaces as a non-200 status.
private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    guard let url = request.url, Transport.isAllowed(url) else { return nil }
    return request
  }
}
