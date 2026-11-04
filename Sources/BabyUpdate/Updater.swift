import CryptoKit
import Foundation
import Observation

/// Checks Baby's signed feed, downloads and stages verified updates next to
/// the app, and swaps them in when the user restarts.
@MainActor
@Observable
public final class Updater {
  /// Where the updater is, as shown in the menu and Settings.
  public enum State: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case failed(String)
    case requiresNewerOS(version: String, minimum: String)
    case downloading(version: String)
    case ready(version: String)
    case available(version: String, page: URL)
    case installing
    case stranded(String)
  }

  private enum Key {
    static let automaticChecks = "automaticUpdateChecks"
    static let lastCheck = "lastUpdateCheck"
    static let highestBuildSeen = "highestUpdateBuildSeen"
  }

  // a staged update: the verified Baby.app inside its staging folder
  private struct Staged {
    let release: Release
    let folder: URL
    let app: URL
  }

  private static let launchDelay: Duration = .seconds(10)
  private static let pollInterval: TimeInterval = 60 * 60
  private static let checkInterval: TimeInterval = 24 * 60 * 60

  public private(set) var state: State = .idle
  /// Whether Baby checks for updates on launch and daily.
  public var automaticChecks: Bool {
    didSet { defaults.set(automaticChecks, forKey: Key.automaticChecks) }
  }
  /// The running version, such as "1.2.0".
  public let version: String
  /// The running build number.
  public let build: Int

  private let bundleURL: URL
  private let defaults: UserDefaults
  private let transport: Transport
  private let os: OSVersion
  private let arch: String
  private let publicKey: Curve25519.Signing.PublicKey?
  private let codeRequirement: String
  private let relaunch: @Sendable ([String]) throws -> Void
  private var staged: Staged?
  private var timer: Timer?

  /// Nil when not running from an app bundle with a numeric build, such as
  /// under `swift run`; such builds never update.
  public convenience init?() {
    let bundle = Bundle.main
    guard bundle.bundleURL.pathExtension == "app",
      let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String,
      let buildString = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
      let build = Int(buildString)
    else { return nil }
    self.init(
      version: version,
      build: build,
      bundleURL: bundle.bundleURL.resolvingSymlinksInPath(),
      transport: Transport(userAgent: "Baby/\(version)"))
  }

  init(
    version: String,
    build: Int,
    bundleURL: URL,
    defaults: UserDefaults = .standard,
    transport: Transport,
    os: OSVersion = .current,
    arch: String = UpdateConfig.arch,
    publicKey: Curve25519.Signing.PublicKey? = nil,
    codeRequirement: String = UpdateConfig.codeRequirement,
    relaunch: @escaping @Sendable ([String]) throws -> Void = {
      try Installer.runAfterExit(of: getpid(), $0)
    }
  ) {
    self.version = version
    self.build = build
    self.bundleURL = bundleURL
    self.defaults = defaults
    self.transport = transport
    self.os = os
    self.arch = arch
    self.publicKey = publicKey
    self.codeRequirement = codeRequirement
    self.relaunch = relaunch
    self.automaticChecks = defaults.object(forKey: Key.automaticChecks) as? Bool ?? true
  }

  /// Removes leftovers from earlier updates and starts scheduled checks.
  public func start() {
    let parent = bundleURL.deletingLastPathComponent()
    Task.detached { Installer.removeLeftovers(in: parent) }
    Task {
      try? await Task.sleep(for: Self.launchDelay)
      if automaticChecks { await check() }
    }
    timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) {
      [weak self] _ in
      Task { @MainActor in await self?.checkIfDue() }
    }
  }

  /// Fetches the feed and, if a newer build is installable, downloads and
  /// stages it. Does nothing while busy or once an update is staged.
  public func check() async {
    switch state {
    case .checking, .downloading, .ready, .installing, .stranded: return
    default: break
    }
    state = .checking
    do {
      let release = try await fetchRelease()
      switch release.decide(currentBuild: build, os: os, arch: arch) {
      case .upToDate:
        state = .upToDate
      case .requiresNewerOS(let release, let minimum):
        state = .requiresNewerOS(version: release.version, minimum: minimum)
      case .install(let release, let artifact):
        guard let parent = replaceableParent() else {
          state = .available(version: release.version, page: release.pageURL)
          defaults.set(Date(), forKey: Key.lastCheck)
          return
        }
        state = .downloading(version: release.version)
        staged = try await Self.stage(
          release, artifact, in: parent, transport: transport, os: os,
          requirement: codeRequirement)
        state = .ready(version: release.version)
      }
      defaults.set(Date(), forKey: Key.lastCheck)
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  /// Installs the staged update and schedules Baby to relaunch once this
  /// process exits. Returns `true` when the caller should terminate the app.
  public func restartToUpdate(isAwake: () -> Bool) async -> Bool {
    guard case .ready = state, staged != nil else { return false }
    state = .installing

    // a staged update can wait for days: if the feed now offers a newer
    // installable build, try staging that first; otherwise install what we have
    if let release = try? await fetchRelease(timeout: 5),
      let currentStaged = staged,
      release.build > currentStaged.release.build,
      case .install(let newerRelease, let artifact) = release.decide(
        currentBuild: build, os: os, arch: arch),
      let parent = replaceableParent()
    {
      state = .downloading(version: newerRelease.version)
      if let replacement = try? await Self.stage(
        newerRelease, artifact, in: parent, transport: transport, os: os,
        requirement: codeRequirement)
      {
        discardStaged()
        staged = replacement
      }
      state = .installing
    }

    guard let staged else { return false }
    do {
      try await Self.install(
        staged, over: bundleURL, runningBuild: build, os: os, requirement: codeRequirement)
    } catch {
      discardStaged()
      state = .failed(error.localizedDescription)
      return false
    }
    let command = [
      "/usr/bin/open", "-n", bundleURL.path, "--args", isAwake() ? "--awake" : "--asleep",
    ]
    do {
      try relaunch(command)
    } catch {
      // put the running version back; if that fails too, keep both copies
      if (try? Installer.swap(staged.app, bundleURL)) != nil {
        discardStaged()
        state = .failed(error.localizedDescription)
      } else {
        state = .stranded(
          "Baby could not finish updating. The previous version is in \(staged.folder.path).")
      }
      return false
    }
    return true
  }

  func checkIfDue() async {
    guard automaticChecks else { return }
    if let last = defaults.object(forKey: Key.lastCheck) as? Date,
      last <= Date(), Date().timeIntervalSince(last) < Self.checkInterval
    {
      return
    }
    await check()
  }

  // fetchRelease verifies the feed and refuses one older than any already
  // verified, so a replayed old feed cannot roll Baby back.
  private func fetchRelease(timeout: TimeInterval = 60) async throws -> Release {
    let release = try Feed.open(
      try await transport.fetchFeed(timeout: timeout), publicKey: publicKey)
    let seen = defaults.integer(forKey: Key.highestBuildSeen)
    guard release.build >= seen else {
      throw FeedError.rollback(seen: seen, got: release.build)
    }
    defaults.set(release.build, forKey: Key.highestBuildSeen)
    return release
  }

  // replaceableParent is the folder Baby lives in, when Baby can replace
  // itself there.
  private func replaceableParent() -> URL? {
    guard !bundleURL.pathComponents.contains("AppTranslocation") else { return nil }
    let parent = bundleURL.deletingLastPathComponent()
    let manager = FileManager.default
    guard manager.isWritableFile(atPath: bundleURL.path),
      manager.isWritableFile(atPath: parent.path)
    else { return nil }
    return parent
  }

  private func discardStaged() {
    if let staged {
      Installer.remove(staged.folder)
    }
    staged = nil
  }

  // stage downloads and unpacks the release next to the app, so the swap
  // stays on one volume, and verifies the unpacked bundle.
  @concurrent
  private static func stage(
    _ release: Release, _ artifact: Artifact, in parent: URL, transport: Transport,
    os: OSVersion, requirement: String
  ) async throws -> Staged {
    let folder = try Installer.makeStagingFolder(in: parent, build: release.build)
    do {
      let zip = folder.appending(path: "update.zip")
      try await transport.download(artifact, to: zip)
      try await Installer.unzip(zip, into: folder)
      try FileManager.default.removeItem(at: zip)
      let app = folder.appending(path: "Baby.app", directoryHint: .isDirectory)
      try await BundleCheck.verify(app: app, release: release, os: os, requirement: requirement)
      return Staged(release: release, folder: folder, app: app)
    } catch {
      Installer.remove(folder)
      throw error
    }
  }

  // install re-verifies the staged bundle and swaps it with the installed
  // one in a single rename, leaving the old bundle in the staging folder.
  @concurrent
  private static func install(
    _ staged: Staged, over installed: URL, runningBuild: Int, os: OSVersion,
    requirement: String
  ) async throws {
    let plist = installed.appending(components: "Contents", "Info.plist")
    let installedBuild = NSDictionary(contentsOf: plist)?["CFBundleVersion"] as? String
    guard installedBuild == String(runningBuild) else {
      throw CocoaError(
        .fileWriteUnknown,
        userInfo: [NSLocalizedDescriptionKey: "Baby was replaced by another version."])
    }
    try await BundleCheck.verify(
      app: staged.app, release: staged.release, os: os, requirement: requirement)
    try Installer.swap(staged.app, installed)
  }
}

extension Updater.State {
  /// The title of the menu item and Settings button for this state.
  public var actionTitle: String {
    switch self {
    case .checking: "Checking for Updates…"
    case .downloading: "Downloading Update…"
    case .ready: "Restart to Update"
    case .available(let version, _): "Download Baby \(version)…"
    case .installing: "Restarting…"
    case .idle, .upToDate, .failed, .requiresNewerOS, .stranded: "Check for Updates…"
    }
  }

  /// Whether the action can run in this state.
  public var actionEnabled: Bool {
    switch self {
    case .checking, .downloading, .installing, .stranded: false
    default: true
    }
  }

  /// A sentence describing this state, if there is anything to say.
  public var caption: String? {
    switch self {
    case .idle, .checking, .installing: nil
    case .upToDate: "Baby is up to date."
    case .failed(let reason): "Couldn't update Baby: \(reason)"
    case .requiresNewerOS(let version, let minimum):
      "Baby \(version) requires macOS \(minimum) or later."
    case .downloading(let version): "Downloading Baby \(version)…"
    case .ready(let version): "Baby \(version) is ready. Restart Baby to finish updating."
    case .available(let version, _):
      "Baby \(version) is available, but Baby can't update itself where it is."
    case .stranded(let reason): reason
    }
  }

  /// Whether the caption reports a problem.
  public var isProblem: Bool {
    switch self {
    case .failed, .stranded: true
    default: false
    }
  }
}
