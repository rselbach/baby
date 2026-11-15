import Foundation
import Testing

@testable import Baby
@testable import BabyControl

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
