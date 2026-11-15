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
  /// The raw Ed25519 public key, base64, behind every feed's `signature`
  /// field. Its private half is the shared SPARKLE_EDDSA_PRIVATE_KEY
  /// deployment secret. Builds released before Baby had a key of its own
  /// trust only this one, so every feed keeps this signature for them.
  public static let legacyPublicKey = "2obyIySbPw8xSuXQwzSw2sCbOixUww08jk95se82unc="
  /// The raw Ed25519 public keys, base64, this build trusts to sign the
  /// feed. scripts/rotate-feed-key.sh replaces the shared legacy key here
  /// with one used for nothing else, kept in the BABY_FEED_SIGNING_KEY secret.
  public static let publicKeys = [legacyPublicKey]
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
  case expired

  public var errorDescription: String? {
    switch self {
    case .expired:
      "The update feed has expired. Check that your Mac's date and time are correct."
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
  /// When clients stop trusting this feed, so a feed withheld or replayed
  /// for too long fails instead of hiding newer releases. Absent in feeds
  /// signed before expiry existed; a refresh re-signs a release with a later one.
  public var expiresAt: String?

  public init(
    version: String, build: Int, publishedAt: String, notesURL: String?,
    artifacts: [Artifact], expiresAt: String? = nil
  ) {
    self.schema = 1
    self.app = UpdateConfig.bundleIdentifier
    self.channel = UpdateConfig.channel
    self.version = version
    self.build = build
    self.publishedAt = publishedAt
    self.notesURL = notesURL
    self.artifacts = artifacts
    self.expiresAt = expiresAt
  }

  enum CodingKeys: String, CodingKey {
    case schema, app, channel, version, build, artifacts
    case publishedAt = "published_at"
    case notesURL = "notes_url"
    case expiresAt = "expires_at"
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

/// The signed feed envelope: a base64 release payload and detached Ed25519
/// signatures over the signing context followed by the payload bytes.
/// `signature` is by the legacy key, the only field older builds read;
/// `signatures` holds the rest. A feed is valid when any of them verifies
/// with a key the build trusts.
public enum Feed {
  /// Feeds larger than this are rejected unread.
  public static let maxBytes = 64 * 1024
  /// How long a newly signed feed stays valid.
  public static let validity: TimeInterval = 90 * 24 * 60 * 60
  /// A refresh re-signs the live feed once less than this much time is left.
  public static let refreshMargin: TimeInterval = 60 * 24 * 60 * 60
  // keeps a feed signature from being valid as any other message signed
  // with the shared key, such as a Sparkle archive signature or another
  // app's feed
  static let signingContext = Data("baby-update-feed-v1\n".utf8)

  private struct Envelope: Codable {
    var payload: String
    var signature: String
    var signatures: [String]?
  }

  /// The compiled-in feed verification keys.
  public static func publicKeys() throws -> [Curve25519.Signing.PublicKey] {
    try UpdateConfig.publicKeys.map(publicKey(base64:))
  }

  /// The key older builds trust, which signs every feed's `signature`.
  public static func legacyPublicKey() throws -> Curve25519.Signing.PublicKey {
    try publicKey(base64: UpdateConfig.legacyPublicKey)
  }

  static func publicKey(base64: String) throws -> Curve25519.Signing.PublicKey {
    guard let raw = Data(base64Encoded: base64) else { throw FeedError.badSignature }
    return try Curve25519.Signing.PublicKey(rawRepresentation: raw)
  }

  /// Verifies a feed's signature with `publicKey`, or the compiled-in keys,
  /// then parses and validates its release. It doesn't check expiry, so
  /// tooling can still read an expired live feed; see ``Release/checkFresh(at:)``.
  public static func open(
    _ data: Data, publicKey: Curve25519.Signing.PublicKey? = nil
  ) throws -> Release {
    try open(data, publicKeys: publicKey.map { [$0] } ?? Self.publicKeys())
  }

  /// Verifies that one of the feed's signatures is by one of `publicKeys`,
  /// then parses and validates its release.
  public static func open(
    _ data: Data, publicKeys: [Curve25519.Signing.PublicKey]
  ) throws -> Release {
    guard data.count <= maxBytes else { throw FeedError.tooLarge }
    guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
      let payload = Data(base64Encoded: envelope.payload)
    else { throw FeedError.malformed }
    var signatures: [Data] = []
    for text in [envelope.signature] + (envelope.signatures ?? []) {
      guard let signature = Data(base64Encoded: text) else { throw FeedError.malformed }
      signatures.append(signature)
    }
    let message = signingContext + payload
    let verified = signatures.contains { signature in
      signature.count == 64
        && publicKeys.contains { $0.isValidSignature(signature, for: message) }
    }
    guard verified else { throw FeedError.badSignature }
    guard let release = try? JSONDecoder().decode(Release.self, from: payload)
    else { throw FeedError.malformed }
    try release.validate()
    return release
  }

  /// Signs a release into a feed envelope with one key.
  public static func seal(
    _ release: Release, privateKey: Curve25519.Signing.PrivateKey
  ) throws -> Data {
    try seal(release, privateKeys: [privateKey])
  }

  /// Signs a release into a feed envelope. The first key signs `signature`,
  /// which older builds read, so it must be the legacy key for a real feed;
  /// the others sign `signatures`.
  public static func seal(
    _ release: Release, privateKeys: [Curve25519.Signing.PrivateKey]
  ) throws -> Data {
    guard let first = privateKeys.first else { throw FeedError.badSignature }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let payload = try encoder.encode(release)
    let message = signingContext + payload
    let rest = try privateKeys.dropFirst().map {
      try $0.signature(for: message).base64EncodedString()
    }
    let envelope = Envelope(
      payload: payload.base64EncodedString(),
      signature: try first.signature(for: message).base64EncodedString(),
      signatures: rest.isEmpty ? nil : rest)
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(envelope) + Data("\n".utf8)
  }

  /// Signs a release to succeed `live` (if any), reusing the verified `live`
  /// feed on an idempotent rerun when `publishedAt` was not pinned. A rerun
  /// re-signs `live` with a later expiry only if it is close to expiring.
  public static func publish(
    version: String, build: Int, publishedAt: String? = nil, notesURL: String?,
    artifacts: [Artifact], privateKey: Curve25519.Signing.PrivateKey,
    after live: Data? = nil, publicKey: Curve25519.Signing.PublicKey? = nil,
    now: Date = Date()
  ) throws -> (feed: Data, release: Release) {
    try publish(
      version: version, build: build, publishedAt: publishedAt, notesURL: notesURL,
      artifacts: artifacts, privateKeys: [privateKey], after: live,
      publicKeys: publicKey.map { [$0] } ?? Self.publicKeys(), now: now)
  }

  /// Signs a release with every key in `privateKeys`, which must cover all
  /// of `publicKeys`, to succeed `live` (if any).
  public static func publish(
    version: String, build: Int, publishedAt: String? = nil, notesURL: String?,
    artifacts: [Artifact], privateKeys: [Curve25519.Signing.PrivateKey],
    after live: Data? = nil, publicKeys: [Curve25519.Signing.PublicKey],
    now: Date = Date()
  ) throws -> (feed: Data, release: Release) {
    try requireSigners(privateKeys, for: publicKeys)
    let current = try live.map { try open($0, publicKeys: publicKeys) }
    if let live, let current, publishedAt == nil {
      let candidate = Release(
        version: version, build: build, publishedAt: current.publishedAt,
        notesURL: notesURL, artifacts: artifacts, expiresAt: current.expiresAt)
      if candidate == current {
        return try refresh(
          live, privateKeys: privateKeys, publicKeys: publicKeys, now: now)
      }
    }
    let release = Release(
      version: version, build: build,
      publishedAt: publishedAt ?? ISO8601DateFormatter().string(from: now),
      notesURL: notesURL, artifacts: artifacts,
      expiresAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(validity)))
    try release.validate()
    if let current {
      try release.verifySupersedes(current)
    }
    let feed = try seal(release, privateKeys: privateKeys)
    guard try open(feed, publicKeys: publicKeys) == release else {
      throw FeedError.malformed
    }
    return (feed, release)
  }

  /// Returns `live` verbatim while it has more than ``refreshMargin`` left,
  /// and otherwise re-signs the same release to expire ``validity`` from now.
  public static func refresh(
    _ live: Data, privateKeys: [Curve25519.Signing.PrivateKey],
    publicKeys: [Curve25519.Signing.PublicKey], now: Date = Date()
  ) throws -> (feed: Data, release: Release) {
    try requireSigners(privateKeys, for: publicKeys)
    let current = try open(live, publicKeys: publicKeys)
    if let expiry = current.expiryDate, expiry.timeIntervalSince(now) > refreshMargin {
      return (live, current)
    }
    var release = current
    release.expiresAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(validity))
    try release.validate()
    try release.verifySupersedes(current)
    let feed = try seal(release, privateKeys: privateKeys)
    guard try open(feed, publicKeys: publicKeys) == release else {
      throw FeedError.malformed
    }
    return (feed, release)
  }

  // requireSigners fails early when the feed wouldn't verify for this build.
  private static func requireSigners(
    _ privateKeys: [Curve25519.Signing.PrivateKey],
    for publicKeys: [Curve25519.Signing.PublicKey]
  ) throws {
    let signers = Set(privateKeys.map(\.publicKey.rawRepresentation))
    guard !publicKeys.isEmpty,
      publicKeys.allSatisfy({ signers.contains($0.rawRepresentation) })
    else { throw FeedError.badSignature }
  }
}

extension Release {
  /// Rejects `self` unless it equals `current`, re-signs it with a later
  /// expiry, or advances `build` without regressing `version`.
  public func verifySupersedes(_ current: Release) throws {
    if self == current { return }
    if build == current.build {
      var unexpiring = self
      unexpiring.expiresAt = current.expiresAt
      guard unexpiring == current, let expiry = expiryDate,
        expiry >= current.expiryDate ?? .distantPast
      else { throw FeedError.rollback(seen: current.build, got: build) }
      return
    }
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
    guard let published = Self.date(publishedAt) else {
      throw FeedError.invalid("published_at")
    }
    if let expiresAt {
      guard let expiry = Self.date(expiresAt), expiry > published else {
        throw FeedError.invalid("expires_at")
      }
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

  /// When the feed expires, if it does.
  public var expiryDate: Date? { expiresAt.flatMap(Self.date) }

  /// Rejects a feed that expired before `now`. Feeds signed before expiry
  /// existed never expire; rollback protection retires them once a client
  /// sees a newer build.
  public func checkFresh(at now: Date = Date()) throws {
    if let expiry = expiryDate, expiry <= now { throw FeedError.expired }
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

  // date parses RFC 3339 / ISO 8601 timestamps with or without fractional
  // seconds.
  static func date(_ string: String) -> Date? {
    if let date = ISO8601DateFormatter().date(from: string) { return date }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: string)
  }

  // release versions use the same numeric ordering as minimum OS versions.
  static func isValidVersion(_ version: String) -> Bool {
    version.utf8.count <= 64 && OSVersion(version) != nil
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
      guard !piece.isEmpty, piece.allSatisfy({ $0.isASCII && $0.isNumber }),
        let value = Int(piece)
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
