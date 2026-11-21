import Darwin
import Foundation
import Testing

@testable import Baby
@testable import BabyControl

private func withTempDirectory(_ body: (URL) throws -> Void) throws {
  let directory = URL(filePath: "/tmp/baby-\(UUID().uuidString.prefix(8))")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}

@Test func launchesAsTheSettingSays() {
  #expect(LaunchState(arguments: ["Baby"], activateOnLaunch: false) == .asleep)
  #expect(LaunchState(arguments: ["Baby"], activateOnLaunch: true) == .awake(until: nil))
}

@Test func launchArgumentsOverrideTheSetting() {
  // the CLI opens Baby with --asleep so activate-on-launch doesn't kick in
  #expect(LaunchState(arguments: ["Baby", "--asleep"], activateOnLaunch: true) == .asleep)
  #expect(
    LaunchState(arguments: ["Baby", "--awake"], activateOnLaunch: false) == .awake(until: nil))
  #expect(
    LaunchState(arguments: ["Baby", "--awake-until=1800000000.5"], activateOnLaunch: false)
      == .awake(until: Date(timeIntervalSince1970: 1_800_000_000.5)))
  for invalid in ["--awake-until=soon", "--awake-until=inf", "--awake-until=nan"] {
    #expect(LaunchState(arguments: ["Baby", invalid], activateOnLaunch: true) == .asleep)
  }
}

@Test func relaunchArgumentsCarryEveryLease() throws {
  let leases = [
    Lease(id: LeaseSet.userID, label: "You", deadline: Date(timeIntervalSince1970: 1_800_000_000)),
    Lease(id: "troy", label: "Troy Barnes", pid: 42),
  ]
  let arguments = LaunchState.relaunchArguments(for: leases)
  let state = LaunchState(arguments: ["Baby"] + arguments, activateOnLaunch: false)
  guard case .leases(let data) = state else {
    Issue.record("expected leases, got \(state)")
    return
  }
  #expect(try LeaseSet(restoring: data).leases == leases)

  // with nothing held, the relaunched Baby stays asleep whatever the setting
  let empty = LaunchState.relaunchArguments(for: [])
  #expect(LaunchState(arguments: ["Baby"] + empty, activateOnLaunch: true) == .asleep)
}

@Test func garbledLeaseArgumentsRestoreNothing() {
  let state = LaunchState(arguments: ["Baby", "--leases=%%%"], activateOnLaunch: true)
  #expect(state == .leases(Data()))
  #expect(throws: DecodingError.self) { try LeaseSet(restoring: Data()) }
}

@Test func relaunchHandoffRoundTripsAndCleansUpOnConsumption() throws {
  try withTempDirectory { directory in
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let url = directory.appending(path: RelaunchHandoff.filename)
    let leases = [
      Lease(id: LeaseSet.userID, label: "You", deadline: now.addingTimeInterval(600)),
      Lease(id: "troy", label: "Troy Barnes", pid: 42),
      Lease(id: "abed", label: "Abed Nadir"),
    ]

    try RelaunchHandoff.write(leases, to: url, now: now)
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)

    #expect(RelaunchHandoff.consume(from: url, now: now.addingTimeInterval(5)) == .leases(leases))
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(RelaunchHandoff.consume(from: url, now: now.addingTimeInterval(6)) == .absent)

    // a maximum-size lease set fits within the handoff file size cap
    var full = LeaseSet()
    for index in 0..<LeaseSet.maximumAgentLeases {
      let suffix = String(index)
      let id = String(repeating: "g", count: 64 - suffix.count) + suffix
      try full.hold(
        Lease(
          id: id, label: String(repeating: "\u{0001}", count: 64),
          deadline: .distantFuture, pid: Int32.max))
    }
    try full.hold(Lease(id: LeaseSet.userID, label: "You", deadline: .distantFuture))
    try RelaunchHandoff.write(full.leases, to: url, now: now)
    let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
    #expect((size ?? Int.max) <= RelaunchHandoff.maximumFileSize)
    #expect(RelaunchHandoff.consume(from: url, now: now) == .leases(full.leases))
  }
}

@MainActor
@Test func handoffPreservesLeasesWhenAsleepWinsTheControlLock() throws {
  try withTempDirectory { directory in
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let socketURL = directory.appending(path: "control.sock")
    let handoffURL = RelaunchHandoff.url(nextTo: socketURL)
    let leases = [
      Lease(id: LeaseSet.userID, label: "You", deadline: now.addingTimeInterval(1800)),
      Lease(id: "greendale", label: "Greendale Community College", pid: 42),
    ]

    // exiting Baby writes the handoff while holding the socket lock, then stops
    let exiting = try ControlServer(url: socketURL) { _ in ControlResponse() }
    try RelaunchHandoff.write(leases, to: handoffURL, now: now)
    exiting.stop()

    // CLI-launched `Baby.app --asleep` acquires the control lock first
    let cliBaby = try ControlServer(url: socketURL) { _ in ControlResponse() }
    defer { cliBaby.stop() }

    // updater-launched `Baby.app --leases=...` loses the lock and exits before touching handoff
    #expect(throws: ControlError.alreadyRunning) {
      let updaterBaby = try ControlServer(url: socketURL) { _ in ControlResponse() }
      updaterBaby.stop()
    }
    #expect(FileManager.default.fileExists(atPath: handoffURL.path))

    // CLI-launched Baby consumes the handoff and restores every lease despite --asleep
    guard case .leases(let handedOff) = RelaunchHandoff.consume(from: handoffURL, now: now) else {
      Issue.record("expected handoff leases")
      return
    }
    let state = LaunchState(
      arguments: ["Baby", "--asleep"], activateOnLaunch: false, handoff: handedOff)
    guard case .handoff(let restored) = state else {
      Issue.record("expected handoff state, got \(state)")
      return
    }
    var rejected: [String] = []
    let set = LeaseSet(restoring: restored, rejected: &rejected)
    #expect(set.leases == leases)
    #expect(rejected.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: handoffURL.path))

    // if that Baby later quits before a delayed updater launch arrives, the
    // handoff is already gone so the updater's --asleep launch does not resurrect leases
    cliBaby.stop()
    let delayedUpdater = try ControlServer(url: socketURL) { _ in ControlResponse() }
    defer { delayedUpdater.stop() }
    #expect(RelaunchHandoff.consume(from: handoffURL, now: now) == .absent)
    #expect(
      LaunchState(arguments: ["Baby", "--asleep"], activateOnLaunch: true, handoff: nil) == .asleep)

    // remove cleans up an unused handoff after a failed relaunch without touching symlinks
    try RelaunchHandoff.write(leases, to: handoffURL, now: now)
    RelaunchHandoff.remove(at: handoffURL)
    #expect(!FileManager.default.fileExists(atPath: handoffURL.path))

    // an empty handoff overrides activateOnLaunch so an asleep Baby stays asleep across update
    try RelaunchHandoff.write([], to: handoffURL, now: now)
    guard case .leases(let emptyHandoff) = RelaunchHandoff.consume(from: handoffURL, now: now)
    else {
      Issue.record("expected empty handoff")
      return
    }
    #expect(
      LaunchState(arguments: ["Baby"], activateOnLaunch: true, handoff: emptyHandoff)
        == .handoff([]))
  }
}

@Test func discardsStaleAndCorruptHandoffsAndFallsBackToArguments() throws {
  try withTempDirectory { directory in
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let url = directory.appending(path: RelaunchHandoff.filename)
    let leases = [Lease(id: "troy", label: "Troy Barnes")]

    // stale past maximumAge is discarded and deleted
    try RelaunchHandoff.write(leases, to: url, now: now)
    #expect(
      RelaunchHandoff.consume(
        from: url, now: now.addingTimeInterval(RelaunchHandoff.maximumAge + 1)) == .stale)
    #expect(!FileManager.default.fileExists(atPath: url.path))

    // future timestamp beyond clock skew tolerance is discarded and deleted
    try RelaunchHandoff.write(leases, to: url, now: now)
    #expect(
      RelaunchHandoff.consume(
        from: url, now: now.addingTimeInterval(-(RelaunchHandoff.maximumClockSkew + 1))) == .stale)
    #expect(!FileManager.default.fileExists(atPath: url.path))

    // small backward clock skew within tolerance still restores
    try RelaunchHandoff.write(leases, to: url, now: now)
    #expect(
      RelaunchHandoff.consume(from: url, now: now.addingTimeInterval(-10)) == .leases(leases))

    // corrupt JSON is discarded and deleted
    try Data("{corrupt".utf8).write(to: url)
    guard case .corrupt = RelaunchHandoff.consume(from: url, now: now) else {
      Issue.record("expected .corrupt for invalid JSON")
      return
    }
    #expect(!FileManager.default.fileExists(atPath: url.path))

    // oversized handoff file is rejected and deleted
    try Data(repeating: 0x20, count: RelaunchHandoff.maximumFileSize + 1).write(to: url)
    guard case .corrupt = RelaunchHandoff.consume(from: url, now: now) else {
      Issue.record("expected .corrupt for oversized file")
      return
    }
    #expect(!FileManager.default.fileExists(atPath: url.path))

    // symlink is rejected without following or removing it
    let target = directory.appending(path: "secret.json")
    try RelaunchHandoff.write(leases, to: target, now: now)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    guard case .corrupt = RelaunchHandoff.consume(from: url, now: now) else {
      Issue.record("expected .corrupt for symlink")
      return
    }
    #expect(FileManager.default.fileExists(atPath: target.path))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == target.path)
    try FileManager.default.removeItem(at: url)

    // directory is rejected without removing it
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    guard case .corrupt = RelaunchHandoff.consume(from: url, now: now) else {
      Issue.record("expected .corrupt for directory")
      return
    }
    #expect(FileManager.default.fileExists(atPath: url.path))
    try FileManager.default.removeItem(at: url)

    // a handoff file that cannot be unlinked is not restored (prevents re-consuming on next launch)
    let lockedDir = directory.appending(path: "locked", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: lockedDir, withIntermediateDirectories: true)
    defer { _ = chmod(lockedDir.path, 0o700) }
    let lockedURL = lockedDir.appending(path: RelaunchHandoff.filename)
    try RelaunchHandoff.write(leases, to: lockedURL, now: now)
    try #require(chmod(lockedDir.path, 0o500) == 0)
    guard case .corrupt(let reason) = RelaunchHandoff.consume(from: lockedURL, now: now) else {
      Issue.record("expected .corrupt when unlink fails")
      return
    }
    #expect(reason.contains("unlink failed"))

    // when handoff is nil (absent/stale/corrupt), legacy launch arguments still work
    let args = LaunchState.relaunchArguments(for: leases)
    guard case .leases(let data) = LaunchState(arguments: ["Baby"] + args, activateOnLaunch: false, handoff: nil) else {
      Issue.record("expected fallback to --leases=")
      return
    }
    #expect(try LeaseSet(restoring: data).leases == leases)
    #expect(
      LaunchState(arguments: ["Baby", "--awake"], activateOnLaunch: false, handoff: nil)
        == .awake(until: nil))
    #expect(
      LaunchState(
        arguments: ["Baby", "--awake-until=1800000000.5"], activateOnLaunch: false, handoff: nil)
        == .awake(until: Date(timeIntervalSince1970: 1_800_000_000.5)))
    #expect(
      LaunchState(arguments: ["Baby", "--asleep"], activateOnLaunch: true, handoff: nil) == .asleep)
  }
}
