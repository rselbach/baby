import CryptoKit
import Foundation

/// Fixed facts about where Baby's updates come from and what they must be.
public enum UpdateConfig {
  /// The signed feed on GitHub Pages.
  public static let feedURL = URL(string: "https://rselbach.github.io/baby/update.json")!
  /// The page to send people to when Baby cannot replace itself.
  public static let releasesURL = URL(string: "https://github.com/rselbach/baby/releases/latest")!
  /// The bundle identifier every release must carry.
  public static let bundleIdentifier = "com.rselbach.baby"
  /// The only channel Baby follows.
  public static let channel = "stable"
  /// The raw Ed25519 public key, base64, that signs the feed. Its private
  /// half is the shared SPARKLE_EDDSA_PRIVATE_KEY deployment secret.
  public static let publicKey = "2obyIySbPw8xSuXQwzSw2sCbOixUww08jk95se82unc="
  /// The prefix every artifact URL must start with.
  public static let artifactPrefix = "https://github.com/rselbach/baby/releases/download/"
  /// The prefix a release notes URL must start with.
  public static let notesPrefix = "https://github.com/rselbach/baby/"
  /// Hosts the feed and its artifacts may be served from, redirects included.
  public static let allowedHosts: Set<String> = [
    "github.com",
    "objects.githubusercontent.com",
    "release-assets.githubusercontent.com",
    "rselbach.github.io",
  ]
  /// The code requirement a downloaded Baby.app must satisfy: Developer ID
  /// signed by our team, and notarized.
  public static let codeRequirement =
    "anchor apple generic and identifier \"com.rselbach.baby\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"LS8YD2TR79\" and notarized"
  /// The artifact architecture this build runs on.
  public static var arch: String {
    #if arch(arm64)
      "arm64"
    #else
      "x86_64"
    #endif
  }
}

/// Why a feed was rejected.
public enum FeedError: LocalizedError, Equatable {
  case tooLarge
  case malformed
  case badSignature
  case invalid(String)
  case rollback(seen: Int, got: Int)

  public var errorDescription: String? {
    switch self {
    case .tooLarge: "The update feed is too large."
    case .malformed: "The update feed is malformed."
    case .badSignature: "The update feed's signature is not valid."
    case .invalid(let field): "The update feed has an invalid \(field)."
    case .rollback(let seen, let got):
      seen == got
        ? "The update feed reuses build \(got) with different contents."
        : "The update feed offers build \(got), older than build \(seen) already seen."
    }
  }
}

/// A release as described by the signed feed payload.
public struct Release: Codable, Equatable, Sendable {
  public var schema: Int
  public var app: String
  public var channel: String
  public var version: String
  public var build: Int
  public var publishedAt: String
  public var notesURL: String?
  public var artifacts: [Artifact]

  public init(
    version: String, build: Int, publishedAt: String, notesURL: String?,
    artifacts: [Artifact]
  ) {
    self.schema = 1
    self.app = UpdateConfig.bundleIdentifier
    self.channel = UpdateConfig.channel
    self.version = version
    self.build = build
    self.publishedAt = publishedAt
    self.notesURL = notesURL
    self.artifacts = artifacts
  }

  enum CodingKeys: String, CodingKey {
    case schema, app, channel, version, build, artifacts
    case publishedAt = "published_at"
    case notesURL = "notes_url"
  }
}

/// A downloadable build of a release.
public struct Artifact: Codable, Equatable, Sendable {
  public var os: String
  public var arch: String
  public var kind: String
  public var minimumOS: String
  public var url: String
  public var size: Int64
  public var sha256: String

  public init(
    arch: String, minimumOS: String, url: String, size: Int64, sha256: String
  ) {
    self.os = "macos"
    self.arch = arch
    self.kind = "app-zip"
    self.minimumOS = minimumOS
    self.url = url
    self.size = size
    self.sha256 = sha256
  }

  enum CodingKeys: String, CodingKey {
    case os, arch, kind, url, size, sha256
    case minimumOS = "minimum_os"
  }
}

/// What the running build should do about a verified release.
public enum Decision: Equatable, Sendable {
  case upToDate
  case requiresNewerOS(Release, minimum: String)
  case install(Release, Artifact)
}

/// The signed feed envelope: a base64 release payload and a detached
/// Ed25519 signature over the signing context followed by the payload bytes.
public enum Feed {
  /// Feeds larger than this are rejected unread.
  public static let maxBytes = 64 * 1024
  // keeps a feed signature from being valid as any other message signed
  // with the shared key, such as a Sparkle archive signature or another
  // app's feed
  static let signingContext = Data("baby-update-feed-v1\n".utf8)

  private struct Envelope: Codable {
    var payload: String
    var signature: String
  }

  /// The compiled-in feed verification key.
  public static func publicKey() throws -> Curve25519.Signing.PublicKey {
    guard let raw = Data(base64Encoded: UpdateConfig.publicKey) else {
      throw FeedError.badSignature
    }
    return try Curve25519.Signing.PublicKey(rawRepresentation: raw)
  }

  /// Verifies a feed's signature, then parses and validates its release.
  public static func open(
    _ data: Data, publicKey: Curve25519.Signing.PublicKey? = nil
  ) throws -> Release {
    guard data.count <= maxBytes else { throw FeedError.tooLarge }
    guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
      let payload = Data(base64Encoded: envelope.payload),
      let signature = Data(base64Encoded: envelope.signature)
    else { throw FeedError.malformed }
    let key = try publicKey ?? Self.publicKey()
    guard signature.count == 64,
      key.isValidSignature(signature, for: signingContext + payload)
    else { throw FeedError.badSignature }
    guard let release = try? JSONDecoder().decode(Release.self, from: payload)
    else { throw FeedError.malformed }
    try release.validate()
    return release
  }

  /// Signs a release into a feed envelope.
  public static func seal(
    _ release: Release, privateKey: Curve25519.Signing.PrivateKey
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let payload = try encoder.encode(release)
    let signature = try privateKey.signature(for: signingContext + payload)
    let envelope = Envelope(
      payload: payload.base64EncodedString(),
      signature: signature.base64EncodedString())
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(envelope) + Data("\n".utf8)
  }

  /// Signs a release to succeed `live` (if any), reusing the verified `live`
  /// feed verbatim on an idempotent rerun when `publishedAt` was not pinned.
  public static func publish(
    version: String, build: Int, publishedAt: String? = nil, notesURL: String?,
    artifacts: [Artifact], privateKey: Curve25519.Signing.PrivateKey,
    after live: Data? = nil, publicKey: Curve25519.Signing.PublicKey? = nil
  ) throws -> (feed: Data, release: Release) {
    let key = try publicKey ?? Self.publicKey()
    guard privateKey.publicKey.rawRepresentation == key.rawRepresentation else {
      throw FeedError.badSignature
    }
    let current = try live.map { try open($0, publicKey: key) }
    if let live, let current, publishedAt == nil {
      let candidate = Release(
        version: version, build: build, publishedAt: current.publishedAt,
        notesURL: notesURL, artifacts: artifacts)
      if candidate == current {
        return (live, current)
      }
    }
    let release = Release(
      version: version, build: build,
      publishedAt: publishedAt ?? ISO8601DateFormatter().string(from: Date()),
      notesURL: notesURL, artifacts: artifacts)
    try release.validate()
    if let current {
      try release.verifySupersedes(current)
    }
    let feed = try seal(release, privateKey: privateKey)
    guard try open(feed, publicKey: key) == release else {
      throw FeedError.malformed
    }
    return (feed, release)
  }
}

extension Release {
  /// Rejects `self` unless it equals `current` or advances `build` without
  /// regressing `version`.
  public func verifySupersedes(_ current: Release) throws {
    if self == current { return }
    guard build > current.build else {
      throw FeedError.rollback(seen: current.build, got: build)
    }
    guard let next = OSVersion(version),
      let previous = OSVersion(current.version),
      next >= previous
    else {
      throw FeedError.invalid("version")
    }
  }

  /// Rejects a release whose known fields carry values Baby cannot trust.
  public func validate() throws {
    guard schema == 1 else { throw FeedError.invalid("schema") }
    guard app == UpdateConfig.bundleIdentifier else { throw FeedError.invalid("app") }
    guard channel == UpdateConfig.channel else { throw FeedError.invalid("channel") }
    guard Self.isValidVersion(version) else { throw FeedError.invalid("version") }
    guard build > 0 else { throw FeedError.invalid("build") }
    guard Self.isValidTimestamp(publishedAt) else {
      throw FeedError.invalid("published_at")
    }
    if let notesURL {
      guard Self.isSafeURL(notesURL, prefix: UpdateConfig.notesPrefix) else {
        throw FeedError.invalid("notes_url")
      }
    }
    guard !artifacts.isEmpty else { throw FeedError.invalid("artifacts") }
    for artifact in artifacts {
      try artifact.validate()
    }
  }

  /// Picks this Mac's artifact if the release is newer than `currentBuild`.
  public func decide(currentBuild: Int, os: OSVersion, arch: String) -> Decision {
    guard build > currentBuild,
      let artifact = artifacts.first(where: {
        $0.os == "macos" && $0.arch == arch && $0.kind == "app-zip"
      }),
      let minimum = OSVersion(artifact.minimumOS)
    else { return .upToDate }
    guard minimum <= os else {
      return .requiresNewerOS(self, minimum: artifact.minimumOS)
    }
    return .install(self, artifact)
  }

  /// The page to open for this release.
  public var pageURL: URL {
    notesURL.flatMap(URL.init(string:)) ?? UpdateConfig.releasesURL
  }

  // isValidTimestamp accepts RFC 3339 / ISO 8601 timestamps with or without
  // fractional seconds.
  static func isValidTimestamp(_ string: String) -> Bool {
    if ISO8601DateFormatter().date(from: string) != nil { return true }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: string) != nil
  }

  // isValidVersion allows 1-64 characters from [A-Za-z0-9.+-] starting with
  // a digit; versions name folders, so nothing else gets through.
  static func isValidVersion(_ version: String) -> Bool {
    guard (1...64).contains(version.count), version.first?.isASCII == true,
      version.first?.isNumber == true
    else { return false }
    return version.allSatisfy {
      $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0))
    }
  }

  // isSafeURL accepts only an exact https URL under prefix, with no
  // credentials, query, fragment, or dot segments.
  static func isSafeURL(_ string: String, prefix: String) -> Bool {
    guard string.hasPrefix(prefix),
      let components = URLComponents(string: string),
      components.url?.absoluteString == string,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil
    else { return false }
    return !components.path.split(separator: "/").contains { $0 == ".." || $0 == "." }
  }
}

extension Artifact {
  func validate() throws {
    guard os == "macos" else { throw FeedError.invalid("os") }
    guard ["arm64", "x86_64"].contains(arch) else { throw FeedError.invalid("arch") }
    guard ["app-zip", "dmg"].contains(kind) else { throw FeedError.invalid("kind") }
    guard OSVersion(minimumOS) != nil else { throw FeedError.invalid("minimum_os") }
    guard Release.isSafeURL(url, prefix: UpdateConfig.artifactPrefix) else {
      throw FeedError.invalid("url")
    }
    guard (1...(2 << 30)).contains(size) else { throw FeedError.invalid("size") }
    guard sha256.count == 64, sha256.allSatisfy({ "0123456789abcdef".contains($0) })
    else { throw FeedError.invalid("sha256") }
  }
}

/// A dotted macOS version with up to three numeric parts.
public struct OSVersion: Comparable, Sendable, CustomStringConvertible {
  public let parts: [Int]

  /// Parses "14", "14.2", or "14.2.1"; anything else is nil.
  public init?(_ string: String) {
    let pieces = string.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...3).contains(pieces.count) else { return nil }
    var parts: [Int] = []
    for piece in pieces {
      guard !piece.isEmpty, piece.allSatisfy(\.isASCII), let value = Int(piece),
        value >= 0
      else { return nil }
      parts.append(value)
    }
    while parts.count < 3 { parts.append(0) }
    self.parts = parts
  }

  /// The version of the running macOS.
  public static var current: OSVersion {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return OSVersion("\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")!
  }

  public static func < (lhs: OSVersion, rhs: OSVersion) -> Bool {
    lhs.parts.lexicographicallyPrecedes(rhs.parts)
  }

  public var description: String { parts.map(String.init).joined(separator: ".") }
}
