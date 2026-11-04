import CryptoKit
import Foundation
import Testing
import os

@testable import BabyUpdate

private let signingKey = Curve25519.Signing.PrivateKey()
private let adHocRequirement = "identifier \"\(UpdateConfig.bundleIdentifier)\""

private struct PackagedRelease: Sendable {
  let release: Release
  let feed: Data
  let zip: Data
}

private func buildAppBundle(at app: URL, version: String, build: Int, minimumOS: String = "14.0")
  throws
{
  let macOS = app.appending(components: "Contents", "MacOS")
  try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
  try FileManager.default.copyItem(
    at: URL(filePath: "/usr/bin/true"), to: macOS.appending(path: "Baby"))
  let plist: [String: Any] = [
    "CFBundleIdentifier": UpdateConfig.bundleIdentifier,
    "CFBundleShortVersionString": version,
    "CFBundleVersion": String(build),
    "CFBundleExecutable": "Baby",
    "CFBundlePackageType": "APPL",
    "LSMinimumSystemVersion": minimumOS,
  ]
  let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
  try data.write(to: app.appending(components: "Contents", "Info.plist"))

  let sign = Process()
  sign.executableURL = URL(filePath: "/usr/bin/codesign")
  sign.arguments = [
    "--force", "--sign", "-", "--identifier", UpdateConfig.bundleIdentifier,
    "--timestamp=none", app.path,
  ]
  sign.standardOutput = FileHandle.nullDevice
  sign.standardError = FileHandle.nullDevice
  try sign.run()
  sign.waitUntilExit()
  #expect(sign.terminationStatus == 0)
}

private func packageRelease(
  in scratch: URL, version: String, build: Int, minimumOS: String = "14.0"
) throws -> PackagedRelease {
  let work = scratch.appending(path: "pkg-\(build)-\(UUID().uuidString)")
  let app = work.appending(path: "Baby.app", directoryHint: .isDirectory)
  try buildAppBundle(at: app, version: version, build: build, minimumOS: minimumOS)
  let zipURL = work.appending(path: "Baby-\(version)-macos-arm64.zip")

  let ditto = Process()
  ditto.executableURL = URL(filePath: "/usr/bin/ditto")
  ditto.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, zipURL.path]
  try ditto.run()
  ditto.waitUntilExit()
  #expect(ditto.terminationStatus == 0)

  let zipData = try Data(contentsOf: zipURL)
  let digest = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
  let url = UpdateConfig.artifactPrefix + "v\(version)/Baby-\(version)-macos-arm64.zip"
  let release = Release(
    version: version, build: build, publishedAt: "2026-11-03T12:00:00Z",
    notesURL: "https://github.com/rselbach/baby/releases/tag/v\(version)",
    artifacts: [
      Artifact(
        arch: "arm64", minimumOS: minimumOS, url: url, size: Int64(zipData.count),
        sha256: digest)
    ])
  let feed = try Feed.seal(release, privateKey: signingKey)
  return PackagedRelease(release: release, feed: feed, zip: zipData)
}

private func installedBuild(at app: URL) -> String? {
  let plist = app.appending(components: "Contents", "Info.plist")
  return NSDictionary(contentsOf: plist)?["CFBundleVersion"] as? String
}

@MainActor
@Test func retriesAfterTransientFailureAndThrottlesAfterSuccess() async throws {
  let root = FileManager.default.temporaryDirectory
    .appending(path: "updater-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { Installer.remove(root) }

  let suite = "baby.tests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }

  let app = root.appending(path: "Baby.app", directoryHint: .isDirectory)
  try buildAppBundle(at: app, version: "1.0.0", build: 5)
  let current = try packageRelease(in: root, version: "1.0.0", build: 5)

  let calls = OSAllocatedUnfairLock(initialState: 0)
  let shouldFail = OSAllocatedUnfairLock(initialState: true)
  let token = "updater-retry-\(UUID().uuidString)"
  defer { MockURLProtocol.unregister(token) }

  let transport = makeMockTransport(token) { _ in
    calls.withLock { $0 += 1 }
    if shouldFail.withLock({ $0 }) {
      return .init(status: 503)
    }
    return .init(body: current.feed)
  }

  let updater = Updater(
    version: "1.0.0", build: 5, bundleURL: app, defaults: defaults, transport: transport,
    os: OSVersion("14.5")!, arch: "arm64", publicKey: signingKey.publicKey,
    codeRequirement: adHocRequirement)

  await updater.checkIfDue()
  guard case .failed = updater.state else {
    Issue.record("expected .failed, got \(updater.state)")
    return
  }
  #expect(calls.withLock { $0 } == 1)

  // transient failure did not stamp lastUpdateCheck, so next poll retries
  shouldFail.withLock { $0 = false }
  await updater.checkIfDue()
  #expect(updater.state == .upToDate)
  #expect(calls.withLock { $0 } == 2)

  // successful check stamps lastUpdateCheck, throttling subsequent polls
  await updater.checkIfDue()
  #expect(calls.withLock { $0 } == 2)
}

@MainActor
@Test func rejectsRollbackFeeds() async throws {
  let root = FileManager.default.temporaryDirectory
    .appending(path: "updater-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { Installer.remove(root) }

  let suite = "baby.tests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }

  let app = root.appending(path: "Baby.app", directoryHint: .isDirectory)
  try buildAppBundle(at: app, version: "1.2.0", build: 10)
  let build10 = try packageRelease(in: root, version: "1.2.0", build: 10)
  let build9 = try packageRelease(in: root, version: "1.1.0", build: 9)

  let servedFeed = OSAllocatedUnfairLock(initialState: build10.feed)
  let token = "updater-rollback-\(UUID().uuidString)"
  defer { MockURLProtocol.unregister(token) }
  let transport = makeMockTransport(token) { _ in
    .init(body: servedFeed.withLock { $0 })
  }

  let updater = Updater(
    version: "1.2.0", build: 10, bundleURL: app, defaults: defaults, transport: transport,
    os: OSVersion("14.5")!, arch: "arm64", publicKey: signingKey.publicKey,
    codeRequirement: adHocRequirement)

  await updater.check()
  #expect(updater.state == .upToDate)

  servedFeed.withLock { $0 = build9.feed }
  await updater.check()
  #expect(updater.state == .failed(FeedError.rollback(seen: 10, got: 9).localizedDescription))
}

@MainActor
@Test(arguments: [["--asleep"], ["--awake"], ["--awake-until=1793808000.0"]])
func preservesStagedUpdateWhenNewerReleaseCannotBeInstalled(launchArguments: [String]) async throws
{
  let root = FileManager.default.temporaryDirectory
    .appending(path: "updater-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { Installer.remove(root) }

  let v11 = try packageRelease(in: root, version: "1.1.0", build: 2, minimumOS: "14.0")
  let v20NewerOS = try packageRelease(in: root, version: "2.0.0", build: 3, minimumOS: "15.0")
  let v12BrokenZip = try packageRelease(in: root, version: "1.2.0", build: 4, minimumOS: "14.0")

  // Case 1: newer feed requires macOS 15 -> keeps and installs staged v1.1 (build 2)
  do {
    let dir = root.appending(path: "case-os", directoryHint: .isDirectory)
    let app = dir.appending(path: "Baby.app", directoryHint: .isDirectory)
    try buildAppBundle(at: app, version: "1.0.0", build: 1)
    let suite = "baby.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let currentFeed = OSAllocatedUnfairLock(initialState: v11.feed)
    let token = "updater-os-\(UUID().uuidString)"
    defer { MockURLProtocol.unregister(token) }
    let transport = makeMockTransport(token) { req in
      if req.url == UpdateConfig.feedURL { return .init(body: currentFeed.withLock { $0 }) }
      return .init(body: v11.zip)
    }
    let relaunched = OSAllocatedUnfairLock<[String]?>(initialState: nil)
    let updater = Updater(
      version: "1.0.0", build: 1, bundleURL: app, defaults: defaults, transport: transport,
      os: OSVersion("14.5")!, arch: "arm64", publicKey: signingKey.publicKey,
      codeRequirement: adHocRequirement, relaunch: { args in relaunched.withLock { $0 = args } })

    await updater.check()
    #expect(updater.state == .ready(version: "1.1.0"))
    currentFeed.withLock { $0 = v20NewerOS.feed }

    let shouldQuit = await updater.restartToUpdate(launchArguments: { launchArguments })
    #expect(shouldQuit)
    #expect(installedBuild(at: app) == "2")
    #expect(
      relaunched.withLock { $0 } == ["/usr/bin/open", "-n", app.path, "--args"] + launchArguments)
  }

  // Case 2: newer feed's ZIP download fails -> keeps and installs staged v1.1 (build 2)
  do {
    let dir = root.appending(path: "case-dl", directoryHint: .isDirectory)
    let app = dir.appending(path: "Baby.app", directoryHint: .isDirectory)
    try buildAppBundle(at: app, version: "1.0.0", build: 1)
    let suite = "baby.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let currentFeed = OSAllocatedUnfairLock(initialState: v11.feed)
    let token = "updater-dl-\(UUID().uuidString)"
    defer { MockURLProtocol.unregister(token) }
    let transport = makeMockTransport(token) { req in
      if req.url == UpdateConfig.feedURL { return .init(body: currentFeed.withLock { $0 }) }
      if req.url?.absoluteString == v11.release.artifacts[0].url { return .init(body: v11.zip) }
      return .init(status: 503)
    }
    let relaunched = OSAllocatedUnfairLock<[String]?>(initialState: nil)
    let updater = Updater(
      version: "1.0.0", build: 1, bundleURL: app, defaults: defaults, transport: transport,
      os: OSVersion("14.5")!, arch: "arm64", publicKey: signingKey.publicKey,
      codeRequirement: adHocRequirement, relaunch: { args in relaunched.withLock { $0 = args } })

    await updater.check()
    #expect(updater.state == .ready(version: "1.1.0"))
    currentFeed.withLock { $0 = v12BrokenZip.feed }

    let shouldQuit = await updater.restartToUpdate(launchArguments: { launchArguments })
    #expect(shouldQuit)
    #expect(installedBuild(at: app) == "2")
    #expect(
      relaunched.withLock { $0 } == ["/usr/bin/open", "-n", app.path, "--args"] + launchArguments)
  }
}

@MainActor
@Test func upgradesToNewerReleaseInOneRestartAndRollsBackOnRelaunchFailure() async throws {
  let root = FileManager.default.temporaryDirectory
    .appending(path: "updater-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { Installer.remove(root) }

  let v11 = try packageRelease(in: root, version: "1.1.0", build: 2)
  let v12 = try packageRelease(in: root, version: "1.2.0", build: 3)

  // Upgrades staged v1.1 -> v1.2 and immediately installs without returning .ready
  do {
    let dir = root.appending(path: "upgrade", directoryHint: .isDirectory)
    let app = dir.appending(path: "Baby.app", directoryHint: .isDirectory)
    try buildAppBundle(at: app, version: "1.0.0", build: 1)
    let suite = "baby.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let currentFeed = OSAllocatedUnfairLock(initialState: v11.feed)
    let token = "updater-up-\(UUID().uuidString)"
    defer { MockURLProtocol.unregister(token) }
    let transport = makeMockTransport(token) { req in
      if req.url == UpdateConfig.feedURL { return .init(body: currentFeed.withLock { $0 }) }
      if req.url?.absoluteString == v11.release.artifacts[0].url { return .init(body: v11.zip) }
      return .init(body: v12.zip)
    }

    let updater = Updater(
      version: "1.0.0", build: 1, bundleURL: app, defaults: defaults, transport: transport,
      os: OSVersion("14.5")!, arch: "arm64", publicKey: signingKey.publicKey,
      codeRequirement: adHocRequirement, relaunch: { _ in })

    await updater.check()
    #expect(updater.state == .ready(version: "1.1.0"))
    currentFeed.withLock { $0 = v12.feed }

    #expect(await updater.restartToUpdate(launchArguments: { ["--awake"] }))
    #expect(installedBuild(at: app) == "3")
  }

  // Rolls back the swapped bundle when relaunch throws
  do {
    let dir = root.appending(path: "rollback", directoryHint: .isDirectory)
    let app = dir.appending(path: "Baby.app", directoryHint: .isDirectory)
    try buildAppBundle(at: app, version: "1.0.0", build: 1)
    let suite = "baby.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let token = "updater-fail-\(UUID().uuidString)"
    defer { MockURLProtocol.unregister(token) }
    let transport = makeMockTransport(token) { req in
      req.url == UpdateConfig.feedURL ? .init(body: v11.feed) : .init(body: v11.zip)
    }

    let updater = Updater(
      version: "1.0.0", build: 1, bundleURL: app, defaults: defaults, transport: transport,
      os: OSVersion("14.5")!, arch: "arm64", publicKey: signingKey.publicKey,
      codeRequirement: adHocRequirement,
      relaunch: { _ in throw POSIXError(.EAGAIN) })

    await updater.check()
    #expect(!(await updater.restartToUpdate(launchArguments: { ["--asleep"] })))
    #expect(installedBuild(at: app) == "1")
    guard case .failed = updater.state else {
      Issue.record("expected .failed after rollback, got \(updater.state)")
      return
    }
  }
}

@Test func updateToolValidatesFlagsAndFeedMonotonicity() throws {
  let binDir = URL(filePath: CommandLine.arguments[0]).deletingLastPathComponent()
  var tool = binDir.appending(path: "baby-update-tool")
  if !FileManager.default.isExecutableFile(atPath: tool.path) {
    let bundleDir = Bundle(for: MockURLProtocol.self).bundleURL.deletingLastPathComponent()
    tool = bundleDir.appending(path: "baby-update-tool")
  }
  #expect(FileManager.default.isExecutableFile(atPath: tool.path))

  func runTool(_ arguments: [String]) throws -> (Int32, String) {
    let proc = Process()
    proc.executableURL = tool
    proc.arguments = arguments
    let errPipe = Pipe()
    proc.standardError = errPipe
    proc.standardOutput = FileHandle.nullDevice
    try proc.run()
    proc.waitUntilExit()
    let errText = String(
      decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return (proc.terminationStatus, errText)
  }

  let (status, errText) = try runTool([
    "verify-feed", "/tmp/nonexistent.json", "--verison", "1.2.0",
  ])
  #expect(status != 0)
  #expect(errText.contains("unknown option --verison"))
}
