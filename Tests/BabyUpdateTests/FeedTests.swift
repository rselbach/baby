import CryptoKit
import Foundation
import Testing

@testable import BabyUpdate

private let key = Curve25519.Signing.PrivateKey()
private let sha = String(repeating: "ab", count: 32)

private func release(
  build: Int = 7, url: String = UpdateConfig.artifactPrefix + "v1.2.0/Baby-1.2.0-macos-arm64.zip",
  minimumOS: String = "14.0"
) -> Release {
  Release(
    version: "1.2.0", build: build, publishedAt: "2026-11-03T12:00:00Z",
    notesURL: "https://github.com/rselbach/baby/releases/tag/v1.2.0",
    artifacts: [
      Artifact(arch: "arm64", minimumOS: minimumOS, url: url, size: 1024, sha256: sha)
    ])
}

private func envelope(_ data: Data) throws -> [String: String] {
  try JSONDecoder().decode([String: String].self, from: data)
}

private func encode(_ envelope: [String: String]) throws -> Data {
  try JSONEncoder().encode(envelope)
}

@Test func roundTrip() throws {
  let feed = try Feed.seal(release(), privateKey: key)
  #expect(try Feed.open(feed, publicKey: key.publicKey) == release())
}

@Test func signsTheDMGWithoutChangingTheUpdaterArtifact() throws {
  var candidate = release()
  var dmg = candidate.artifacts[0]
  dmg.kind = "dmg"
  dmg.url = UpdateConfig.artifactPrefix + "v1.2.0/Installer.dmg"
  candidate.artifacts.insert(dmg, at: 0)
  let feed = try Feed.seal(candidate, privateKey: key)
  let restored = try Feed.open(feed, publicKey: key.publicKey)
  #expect(restored == candidate)
  #expect(
    restored.decide(currentBuild: 6, os: OSVersion("14")!, arch: "arm64")
      == .install(candidate, candidate.artifacts[1]))
}

@Test func rejectsOtherKeys() throws {
  let feed = try Feed.seal(release(), privateKey: key)
  #expect(throws: FeedError.badSignature) {
    try Feed.open(feed, publicKey: Curve25519.Signing.PrivateKey().publicKey)
  }
}

@Test func rejectsTamperedPayload() throws {
  var fields = try envelope(try Feed.seal(release(), privateKey: key))
  let tampered = try JSONEncoder().encode(release(build: 99))
  fields["payload"] = tampered.base64EncodedString()
  #expect(throws: FeedError.badSignature) {
    try Feed.open(try encode(fields), publicKey: key.publicKey)
  }
}

@Test func rejectsSignaturesWithoutContext() throws {
  let payload = try JSONEncoder().encode(release())
  let fields = [
    "payload": payload.base64EncodedString(),
    "signature": try key.signature(for: payload).base64EncodedString(),
  ]
  #expect(throws: FeedError.badSignature) {
    try Feed.open(try encode(fields), publicKey: key.publicKey)
  }
}

@Test func rejectsOversizedFeeds() {
  #expect(throws: FeedError.tooLarge) {
    try Feed.open(Data(count: Feed.maxBytes + 1), publicKey: key.publicKey)
  }
}

@Test func acceptsFractionalSecondTimestamps() throws {
  var r = release()
  r.publishedAt = "2026-11-03T12:00:00.123Z"
  let feed = try Feed.seal(r, privateKey: key)
  #expect(try Feed.open(feed, publicKey: key.publicKey) == r)
}

@Test(arguments: [
  "app", "channel", "version", "build", "published_at", "notes_url", "artifacts", "sha256",
  "size", "minimum_os", "expires_at",
])
func rejectsInvalidFields(field: String) throws {
  var bad = release()
  switch field {
  case "app": bad.app = "com.example.other"
  case "channel": bad.channel = "beta"
  case "version": bad.version = "../1"
  case "build": bad.build = 0
  case "published_at": bad.publishedAt = "yesterday"
  case "notes_url": bad.notesURL = "https://example.com/notes"
  case "artifacts": bad.artifacts = []
  case "sha256": bad.artifacts[0].sha256 = "AB"
  case "size": bad.artifacts[0].size = 0
  case "minimum_os": bad.artifacts[0].minimumOS = "14.0.0.1"
  case "expires_at": bad.expiresAt = "2026-11-03T11:59:59Z"
  default: Issue.record("unknown field \(field)")
  }
  let feed = try Feed.seal(bad, privateKey: key)
  #expect(throws: FeedError.invalid(field)) {
    try Feed.open(feed, publicKey: key.publicKey)
  }
}

@Test(arguments: [
  "https://example.com/rselbach/baby/releases/download/v1/Baby.zip",
  "http://github.com/rselbach/baby/releases/download/v1/Baby.zip",
  UpdateConfig.artifactPrefix + "v1/Baby.zip?x=1",
  UpdateConfig.artifactPrefix + "v1/Baby.zip#frag",
  UpdateConfig.artifactPrefix + "../../other/releases/download/v1/Baby.zip",
])
func rejectsUnsafeArtifactURLs(url: String) throws {
  let feed = try Feed.seal(release(url: url), privateKey: key)
  #expect(throws: FeedError.invalid("url")) {
    try Feed.open(feed, publicKey: key.publicKey)
  }
}

@Test func decidesInstallForNewerBuilds() {
  let r = release(build: 7)
  #expect(
    r.decide(currentBuild: 6, os: OSVersion("14.5")!, arch: "arm64")
      == .install(r, r.artifacts[0]))
}

@Test func decidesUpToDate() {
  let r = release(build: 7)
  #expect(r.decide(currentBuild: 7, os: OSVersion("14.5")!, arch: "arm64") == .upToDate)
  #expect(r.decide(currentBuild: 8, os: OSVersion("14.5")!, arch: "arm64") == .upToDate)
  #expect(r.decide(currentBuild: 6, os: OSVersion("14.5")!, arch: "x86_64") == .upToDate)
}

@Test func decidesNewerOSRequired() {
  let r = release(build: 7, minimumOS: "15.1")
  #expect(
    r.decide(currentBuild: 6, os: OSVersion("15.0.9")!, arch: "arm64")
      == .requiresNewerOS(r, minimum: "15.1"))
}

@Test func comparesOSVersions() {
  #expect(OSVersion("14")! == OSVersion("14.0.0")!)
  #expect(OSVersion("14.2")! < OSVersion("14.10")!)
  #expect(OSVersion("27.0")! > OSVersion("14.9.9")!)
  #expect(OSVersion("14.a") == nil)
  #expect(OSVersion("") == nil)
  for invalid in ["+14", "14.+2", "14.-0", "-0", "14..1", "14.2.", "١٤"] {
    #expect(OSVersion(invalid) == nil, "\(invalid)")
  }
}

@Test func allowsOnlyKnownHTTPSHosts() {
  #expect(Transport.isAllowed(UpdateConfig.feedURL))
  #expect(Transport.isAllowed(URL(string: "HTTPS://GitHub.COM/x")!))
  #expect(
    Transport.isAllowed(URL(string: "https://release-assets.githubusercontent.com/x")!))
  #expect(!Transport.isAllowed(URL(string: "https://github.com:8443/x")!))
  #expect(!Transport.isAllowed(URL(string: "http://github.com/x")!))
  #expect(!Transport.isAllowed(URL(string: "https://evil.example.com/x")!))
  #expect(!Transport.isAllowed(URL(string: "https://user:pw@github.com/x")!))
}

@Test func publicKeysParse() throws {
  #expect(try Feed.legacyPublicKey().rawRepresentation.count == 32)
  let keys = try Feed.publicKeys()
  #expect(!keys.isEmpty)
  #expect(keys.allSatisfy { $0.rawRepresentation.count == 32 })
}

@Test(arguments: ["1.2.0-beta", "1.2.0+build", "1.2.3.4", "9223372036854775808", "1..2"])
func rejectsReleaseVersionsThatCannotBeOrdered(version: String) throws {
  var candidate = release()
  candidate.version = version
  #expect(throws: FeedError.invalid("version")) { try candidate.validate() }
}

@Test func publishReusesLiveFeedOnRerunAndRejectsRollbacks() throws {
  let base = release(build: 7)
  let (liveFeed, liveRelease) = try Feed.publish(
    version: base.version, build: base.build, publishedAt: "2020-01-01T00:00:00Z",
    notesURL: base.notesURL, artifacts: base.artifacts, privateKey: key,
    publicKey: key.publicKey)

  // Rerun without explicit publishedAt reuses the verified live feed verbatim
  let (rerunFeed, rerunRelease) = try Feed.publish(
    version: base.version, build: base.build, notesURL: base.notesURL,
    artifacts: base.artifacts, privateKey: key, after: liveFeed, publicKey: key.publicKey)
  #expect(rerunFeed == liveFeed)
  #expect(rerunRelease == liveRelease)
  try Feed.open(rerunFeed, publicKey: key.publicKey).verifySupersedes(liveRelease)

  // Same build with altered artifact hash is rejected
  var altered = base.artifacts
  altered[0].sha256 = String(repeating: "cd", count: 32)
  #expect(throws: FeedError.rollback(seen: 7, got: 7)) {
    _ = try Feed.publish(
      version: base.version, build: base.build, notesURL: base.notesURL,
      artifacts: altered, privateKey: key, after: liveFeed, publicKey: key.publicKey)
  }

  // Higher build on an older version is rejected
  #expect(throws: FeedError.invalid("version")) {
    _ = try Feed.publish(
      version: "1.1.9", build: 8, notesURL: base.notesURL, artifacts: base.artifacts,
      privateKey: key, after: liveFeed, publicKey: key.publicKey)
  }

  // Advancing build and version produces a superseding feed
  let (_, nextRelease) = try Feed.publish(
    version: "1.2.1", build: 8, notesURL: base.notesURL, artifacts: base.artifacts,
    privateKey: key, after: liveFeed, publicKey: key.publicKey)
  try nextRelease.verifySupersedes(liveRelease)
}

private let launch = Date(timeIntervalSince1970: 1_800_000_000)

@Test func publishedFeedsExpire() throws {
  let base = release()
  let (feed, published) = try Feed.publish(
    version: base.version, build: base.build, notesURL: base.notesURL,
    artifacts: base.artifacts, privateKey: key, publicKey: key.publicKey, now: launch)
  let opened = try Feed.open(feed, publicKey: key.publicKey)
  #expect(opened == published)
  #expect(opened.expiryDate == launch.addingTimeInterval(Feed.validity))
  try opened.checkFresh(at: launch.addingTimeInterval(Feed.validity - 1))
  #expect(throws: FeedError.expired) {
    try opened.checkFresh(at: launch.addingTimeInterval(Feed.validity))
  }
  // feeds signed before expiry existed stay readable
  try release().checkFresh(at: .distantFuture)
}

@Test func refreshReSignsOnlyFeedsCloseToExpiring() throws {
  let legacy = try Feed.seal(release(), privateKey: key)
  let (refreshed, renewed) = try Feed.refresh(
    legacy, privateKeys: [key], publicKeys: [key.publicKey], now: launch)
  #expect(refreshed != legacy)
  #expect(renewed.expiryDate == launch.addingTimeInterval(Feed.validity))
  try renewed.verifySupersedes(release())

  // a feed with plenty of time left is reused byte for byte
  let soon = launch.addingTimeInterval(Feed.validity - Feed.refreshMargin - 60)
  let (again, _) = try Feed.refresh(
    refreshed, privateKeys: [key], publicKeys: [key.publicKey], now: soon)
  #expect(again == refreshed)

  let late = launch.addingTimeInterval(Feed.validity - Feed.refreshMargin + 60)
  let (later, laterRelease) = try Feed.refresh(
    refreshed, privateKeys: [key], publicKeys: [key.publicKey], now: late)
  #expect(later != refreshed)
  #expect(laterRelease.expiryDate == late.addingTimeInterval(Feed.validity))
  try laterRelease.verifySupersedes(renewed)
}

@Test func refreshesCannotShortenOrDropExpiry() throws {
  var current = release()
  current.expiresAt = "2027-01-01T00:00:00Z"
  var earlier = current
  earlier.expiresAt = "2026-12-01T00:00:00Z"
  #expect(throws: FeedError.rollback(seen: 7, got: 7)) { try earlier.verifySupersedes(current) }
  var dropped = current
  dropped.expiresAt = nil
  #expect(throws: FeedError.rollback(seen: 7, got: 7)) { try dropped.verifySupersedes(current) }
  var changed = current
  changed.expiresAt = "2027-02-01T00:00:00Z"
  changed.notesURL = nil
  #expect(throws: FeedError.rollback(seen: 7, got: 7)) { try changed.verifySupersedes(current) }
}

@Test func feedsSignedWithSeveralKeysVerifyWithAnyOfThem() throws {
  let dedicated = Curve25519.Signing.PrivateKey()
  let feed = try Feed.seal(release(), privateKeys: [key, dedicated])
  #expect(try Feed.open(feed, publicKey: key.publicKey) == release())
  #expect(try Feed.open(feed, publicKey: dedicated.publicKey) == release())
  #expect(throws: FeedError.badSignature) {
    try Feed.open(feed, publicKey: Curve25519.Signing.PrivateKey().publicKey)
  }

  // older builds read only `signature`, which the first key signs
  let fields = try JSONSerialization.jsonObject(with: feed) as? [String: Any]
  let payload = try #require(Data(base64Encoded: try #require(fields?["payload"] as? String)))
  let signature = try #require(
    Data(base64Encoded: try #require(fields?["signature"] as? String)))
  #expect(key.publicKey.isValidSignature(signature, for: Feed.signingContext + payload))
  #expect((fields?["signatures"] as? [String])?.count == 1)
}

@Test func publishRequiresEveryTrustedSigner() throws {
  let base = release()
  let dedicated = Curve25519.Signing.PrivateKey()
  #expect(throws: FeedError.badSignature) {
    _ = try Feed.publish(
      version: base.version, build: base.build, notesURL: base.notesURL,
      artifacts: base.artifacts, privateKeys: [key],
      publicKeys: [key.publicKey, dedicated.publicKey])
  }
  let (feed, _) = try Feed.publish(
    version: base.version, build: base.build, notesURL: base.notesURL,
    artifacts: base.artifacts, privateKeys: [key, dedicated],
    publicKeys: [dedicated.publicKey])
  _ = try Feed.open(feed, publicKey: key.publicKey)
  _ = try Feed.open(feed, publicKey: dedicated.publicKey)
}
