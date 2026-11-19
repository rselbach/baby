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

  updater.start()
  try await Task.sleep(for: .seconds(11))
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

@MainActor
@Test func installsStagedUpdateBeforeQuitWithoutRelaunching() async throws {
  let root = FileManager.default.temporaryDirectory
    .appending(path: "updater-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { Installer.remove(root) }

  let suite = "baby.tests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }

  let dir = root.appending(path: "quit", directoryHint: .isDirectory)
  let app = dir.appending(path: "Baby.app", directoryHint: .isDirectory)
  try buildAppBundle(at: app, version: "1.0.0", build: 1)
  let v11 = try packageRelease(in: root, version: "1.1.0", build: 2)

  let token = "updater-quit-\(UUID().uuidString)"
  defer { MockURLProtocol.unregister(token) }
  let transport = makeMockTransport(token) { req in
    req.url == UpdateConfig.feedURL ? .init(body: v11.feed) : .init(body: v11.zip)
  }
  let relaunched = OSAllocatedUnfairLock(initialState: false)
  let updater = Updater(
    version: "1.0.0", build: 1, bundleURL: app, defaults: defaults, transport: transport,
    os: OSVersion("14.5")!, arch: "arm64", publicKey: signingKey.publicKey,
    codeRequirement: adHocRequirement, relaunch: { _ in relaunched.withLock { $0 = true } })

  await updater.installBeforeQuit()
  #expect(installedBuild(at: app) == "1")

  await updater.check()
  #expect(updater.state == .ready(version: "1.1.0"))
  await updater.installBeforeQuit()
  #expect(installedBuild(at: app) == "2")
  #expect(!relaunched.withLock { $0 })
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

  // generate-key writes a seed only its owner can read, and never over a file
  let root = FileManager.default.temporaryDirectory.appending(path: "tool-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { Installer.remove(root) }
  let seedFile = root.appending(path: "seed.txt")
  #expect(try runTool(["generate-key", "--seed-out", seedFile.path]).0 == 0)
  let seed = try String(contentsOf: seedFile, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  #expect(Data(base64Encoded: seed)?.count == 32)
  let mode = try FileManager.default.attributesOfItem(atPath: seedFile.path)[.posixPermissions]
  #expect(mode as? Int == 0o600)
  #expect(try runTool(["generate-key", "--seed-out", seedFile.path]).0 != 0)
  #expect(try String(contentsOf: seedFile, encoding: .utf8).hasPrefix(seed))

  // signing refuses a key Baby doesn't trust before touching the feed
  let refresh = Process()
  refresh.executableURL = tool
  refresh.arguments = [
    "refresh-feed", root.appending(path: "live.json").path,
    "--out", root.appending(path: "out.json").path,
  ]
  let input = Pipe()
  let errors = Pipe()
  refresh.standardInput = input
  refresh.standardError = errors
  refresh.standardOutput = FileHandle.nullDevice
  try refresh.run()
  try input.fileHandleForWriting.write(contentsOf: Data((seed + "\n").utf8))
  try input.fileHandleForWriting.close()
  refresh.waitUntilExit()
  #expect(refresh.terminationStatus != 0)
  let refusal = String(
    decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  #expect(refusal.contains("is not one Baby trusts"))
  #expect(!FileManager.default.fileExists(atPath: root.appending(path: "out.json").path))
}

@MainActor
@Test(arguments: [false, true])
func waitsForAnInstallationBeforeQuitting(restart: Bool) async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: "updater-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { Installer.remove(root) }
  let suite = "baby.tests.\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let app = root.appending(path: "Baby.app")
  try buildAppBundle(at: app, version: "1.0.0", build: 1)
  let next = try packageRelease(in: root, version: "1.1.0", build: 2)
  let token = "updater-quit-wait-\(UUID())"
  defer { MockURLProtocol.unregister(token) }
  let transport = makeMockTransport(token) { request in
    request.url == UpdateConfig.feedURL ? .init(body: next.feed) : .init(body: next.zip)
  }
  let updater = Updater(
    version: "1.0.0", build: 1, bundleURL: app, defaults: defaults, transport: transport,
    os: OSVersion("14.5")!, arch: "arm64", publicKey: signingKey.publicKey,
    codeRequirement: adHocRequirement, relaunch: { _ in })
  await updater.check()
  try #require(updater.state == .ready(version: "1.1.0"))
  let installation = Task {
    if restart { return await updater.restartToUpdate(launchArguments: { ["--asleep"] }) }
    await updater.installBeforeQuit()
    return true
  }
  while updater.state == .ready(version: "1.1.0") { await Task.yield() }
  #expect(updater.state.needsInstallationBeforeQuit)
  await updater.installBeforeQuit()
  #expect(updater.state == .installed)
  #expect(!updater.state.needsInstallationBeforeQuit)
  #expect(installedBuild(at: app) == "2")
  #expect(await installation.value)
}

@MainActor
@Test func marksThePreviousBundleForRecoveryWhenRollbackFails() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: "updater-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { Installer.remove(root) }
  let suite = "baby.tests.\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let app = root.appending(path: "Baby.app")
  try buildAppBundle(at: app, version: "1.0.0", build: 1)
  let next = try packageRelease(in: root, version: "1.1.0", build: 2)
  let token = "updater-stranded-\(UUID())"
  defer { MockURLProtocol.unregister(token) }
  let transport = makeMockTransport(token) { request in
    request.url == UpdateConfig.feedURL ? .init(body: next.feed) : .init(body: next.zip)
  }
  let updater = Updater(
    version: "1.0.0", build: 1, bundleURL: app, defaults: defaults, transport: transport,
    os: OSVersion("14.5")!, arch: "arm64", publicKey: signingKey.publicKey,
    codeRequirement: adHocRequirement,
    relaunch: { _ in
      try FileManager.default.moveItem(at: app, to: root.appending(path: "displaced.app"))
      throw POSIXError(.EAGAIN)
    })
  await updater.check()
  #expect(!(await updater.restartToUpdate(launchArguments: { ["--asleep"] })))
  guard case .stranded = updater.state else {
    Issue.record("expected a stranded update, got \(updater.state)")
    return
  }
  let folders = try FileManager.default.contentsOfDirectory(
    at: root, includingPropertiesForKeys: nil)
  let recovery = try #require(
    folders.first { $0.lastPathComponent.hasPrefix(Installer.stagingPrefix) })
  #expect(installedBuild(at: recovery.appending(path: "Baby.app")) == "1")
  #expect(
    FileManager.default.fileExists(atPath: recovery.appending(path: "recovery-required").path))
}

@MainActor
@Test(arguments: [false, true])
func keepsRecoveryMarkerUntilUpdatedBuildLaunches(restart: Bool) async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: "updater-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { Installer.remove(root) }
  let suite = "baby.tests.\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let app = root.appending(path: "Baby.app", directoryHint: .isDirectory)
  try buildAppBundle(at: app, version: "1.0.0", build: 1)
  let next = try packageRelease(in: root, version: "1.1.0", build: 2)
  let token = "updater-recovery-keep-\(UUID())"
  defer { MockURLProtocol.unregister(token) }
  let transport = makeMockTransport(token) { request in
    request.url == UpdateConfig.feedURL ? .init(body: next.feed) : .init(body: next.zip)
  }
  let updater = Updater(
    version: "1.0.0", build: 1, bundleURL: app, defaults: defaults, transport: transport,
    os: OSVersion("14.5")!, arch: "arm64", publicKey: signingKey.publicKey,
    codeRequirement: adHocRequirement, relaunch: { _ in })

  await updater.check()
  try #require(updater.state == .ready(version: "1.1.0"))
  if restart {
    #expect(await updater.restartToUpdate(launchArguments: { ["--asleep"] }))
  } else {
    await updater.installBeforeQuit()
  }
  #expect(updater.state == .installed)
  #expect(installedBuild(at: app) == "2")

  let folders = try FileManager.default.contentsOfDirectory(
    at: root, includingPropertiesForKeys: nil)
  let staging = try #require(
    folders.first { $0.lastPathComponent.hasPrefix(Installer.stagingPrefix) })
  #expect(installedBuild(at: staging.appending(path: "Baby.app")) == "1")
  #expect(
    FileManager.default.fileExists(
      atPath: staging.appending(path: Installer.recoveryMarker).path))

  // simulate the old process having exited so removeLeftovers evaluates the staging folder
  let exited = Process()
  exited.executableURL = URL(filePath: "/usr/bin/true")
  try exited.run()
  exited.waitUntilExit()
  let fields = staging.lastPathComponent.dropFirst(Installer.stagingPrefix.count).split(
    separator: "-")
  try #require(fields.count == 3)
  let retired = root.appending(
    path: "\(Installer.stagingPrefix)\(fields[0])-\(exited.processIdentifier)-\(fields[2])")
  try FileManager.default.moveItem(at: staging, to: retired)

  // without the new build running, the recovery marker keeps the previous bundle safe
  Installer.removeLeftovers(in: root)
  #expect(FileManager.default.fileExists(atPath: retired.path))
  Installer.removeLeftovers(in: root, installed: app, runningBuild: 1)
  #expect(FileManager.default.fileExists(atPath: retired.path))

  // once the updated build launches, removeLeftovers cleans up the staging folder
  Installer.removeLeftovers(in: root, installed: app, runningBuild: 2)
  #expect(!FileManager.default.fileExists(atPath: retired.path))
  #expect(installedBuild(at: app) == "2")
}

@MainActor
@Test func refusesExpiredFeeds() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: "updater-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { Installer.remove(root) }
  let suite = "baby.tests.\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let app = root.appending(path: "Baby.app")
  try buildAppBundle(at: app, version: "1.0.0", build: 1)
  var release = try packageRelease(in: root, version: "1.1.0", build: 2).release
  release.expiresAt = "2026-12-01T00:00:00Z"
  let feed = try Feed.seal(release, privateKey: signingKey)
  let token = "updater-expired-\(UUID())"
  defer { MockURLProtocol.unregister(token) }
  let transport = makeMockTransport(token) { _ in .init(body: feed) }
  let updater = Updater(
    version: "1.0.0", build: 1, bundleURL: app, defaults: defaults, transport: transport,
    os: OSVersion("14.5")!, arch: "arm64", publicKey: signingKey.publicKey,
    codeRequirement: adHocRequirement, relaunch: { _ in },
    now: { Date(timeIntervalSince1970: 1_800_000_000) })

  // 15 January 2027 is after the feed expired
  await updater.check()
  #expect(updater.state == .failed(FeedError.expired.localizedDescription))
  // an expired feed doesn't count as seen, so it can't block a fresh one
  #expect(defaults.integer(forKey: "highestUpdateBuildSeen") == 0)
}

@MainActor
@Test func throttlesDailyChecksAndHandlesClockSkewUsingInjectedClock() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: "updater-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { Installer.remove(root) }
  let suite = "baby.tests.\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }

  let app = root.appending(path: "Baby.app", directoryHint: .isDirectory)
  try buildAppBundle(at: app, version: "1.0.0", build: 5)
  let current = try packageRelease(in: root, version: "1.0.0", build: 5)

  let calls = OSAllocatedUnfairLock(initialState: 0)
  let token = "updater-clock-\(UUID())"
  defer { MockURLProtocol.unregister(token) }
  let transport = makeMockTransport(token) { _ in
    calls.withLock { $0 += 1 }
    return .init(body: current.feed)
  }

  let start = Date(timeIntervalSince1970: 1_700_000_000)
  let clock = OSAllocatedUnfairLock(initialState: start)
  let clockReads = OSAllocatedUnfairLock(initialState: 0)
  let updater = Updater(
    version: "1.0.0", build: 5, bundleURL: app, defaults: defaults, transport: transport,
    os: OSVersion("14.5")!, arch: "arm64", publicKey: signingKey.publicKey,
    codeRequirement: adHocRequirement,
    now: {
      clockReads.withLock { $0 += 1 }
      return clock.withLock { $0 }
    })

  // initial check runs and stamps lastUpdateCheck from the injected clock
  await updater.checkIfDue()
  #expect(updater.state == .upToDate)
  #expect(calls.withLock { $0 } == 1)
  #expect(defaults.object(forKey: "lastUpdateCheck") as? Date == start)

  // still throttled one second before 24 hours have elapsed, reading now() once
  clock.withLock { $0 = start.addingTimeInterval(24 * 60 * 60 - 1) }
  let readsBeforeThrottle = clockReads.withLock { $0 }
  await updater.checkIfDue()
  #expect(calls.withLock { $0 } == 1)
  #expect(clockReads.withLock { $0 } == readsBeforeThrottle + 1)

  // due again once 24 hours have elapsed
  let nextDay = start.addingTimeInterval(24 * 60 * 60)
  clock.withLock { $0 = nextDay }
  await updater.checkIfDue()
  #expect(calls.withLock { $0 } == 2)
  #expect(defaults.object(forKey: "lastUpdateCheck") as? Date == nextDay)

  // clock skewed backward before lastUpdateCheck bypasses throttle and restamps
  let skewed = nextDay.addingTimeInterval(-1)
  clock.withLock { $0 = skewed }
  await updater.checkIfDue()
  #expect(calls.withLock { $0 } == 3)
  #expect(defaults.object(forKey: "lastUpdateCheck") as? Date == skewed)

  // throttled again relative to the restamped time
  clock.withLock { $0 = skewed.addingTimeInterval(60) }
  await updater.checkIfDue()
  #expect(calls.withLock { $0 } == 3)
}

@MainActor
@Test func stampsInjectedClockWhenUpdateCannotBeReplacedInPlace() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: "updater-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { Installer.remove(root) }
  let suite = "baby.tests.\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }

  let app = root.appending(components: "AppTranslocation", "Baby.app")
  try buildAppBundle(at: app, version: "1.0.0", build: 1)
  let next = try packageRelease(in: root, version: "1.1.0", build: 2)

  let calls = OSAllocatedUnfairLock(initialState: 0)
  let token = "updater-available-clock-\(UUID())"
  defer { MockURLProtocol.unregister(token) }
  let transport = makeMockTransport(token) { _ in
    calls.withLock { $0 += 1 }
    return .init(body: next.feed)
  }

  let start = Date(timeIntervalSince1970: 1_700_000_000)
  let clock = OSAllocatedUnfairLock(initialState: start)
  let updater = Updater(
    version: "1.0.0", build: 1, bundleURL: app, defaults: defaults, transport: transport,
    os: OSVersion("14.5")!, arch: "arm64", publicKey: signingKey.publicKey,
    codeRequirement: adHocRequirement, now: { clock.withLock { $0 } })

  await updater.checkIfDue()
  #expect(updater.state == .available(version: "1.1.0", page: next.release.pageURL))
  #expect(calls.withLock { $0 } == 1)
  #expect(defaults.object(forKey: "lastUpdateCheck") as? Date == start)

  clock.withLock { $0 = start.addingTimeInterval(24 * 60 * 60 - 1) }
  await updater.checkIfDue()
  #expect(calls.withLock { $0 } == 1)

  let nextDay = start.addingTimeInterval(24 * 60 * 60)
  clock.withLock { $0 = nextDay }
  await updater.checkIfDue()
  #expect(calls.withLock { $0 } == 2)
  #expect(defaults.object(forKey: "lastUpdateCheck") as? Date == nextDay)
}
