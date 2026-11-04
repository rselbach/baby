import BabyControl
import Foundation
import Testing

@testable import Baby

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Test func holdsLeasesInOrderAndReplacesByID() {
  var set = LeaseSet()
  set.hold(Lease(id: "troy", label: "Troy"))
  set.hold(Lease(id: "abed", label: "Abed"))
  set.hold(Lease(id: "troy", label: "Troy Barnes", pid: 7))
  #expect(
    set.leases == [Lease(id: "troy", label: "Troy Barnes", pid: 7), Lease(id: "abed", label: "Abed")])
  set.removeAll { $0.id == "troy" }
  #expect(set.leases.map(\.id) == ["abed"])
  #expect(!set.isEmpty)
}

@Test func findsTheEarliestDeadline() {
  var set = LeaseSet()
  #expect(set.nextDeadline == nil)
  set.hold(Lease(id: "permanent", label: "Permanent"))
  #expect(set.nextDeadline == nil)
  set.hold(Lease(id: "late", label: "Late", deadline: now.addingTimeInterval(600)))
  set.hold(Lease(id: "soon", label: "Soon", deadline: now.addingTimeInterval(60)))
  #expect(set.nextDeadline == now.addingTimeInterval(60))
}

@Test func removesExpiredLeasesAndExitedProcesses() {
  var set = LeaseSet()
  set.hold(Lease(id: "expired", label: "Expired", deadline: now))
  set.hold(Lease(id: "future", label: "Future", deadline: now.addingTimeInterval(1)))
  set.hold(Lease(id: "exited", label: "Exited", pid: 10))
  set.hold(Lease(id: "running", label: "Running", pid: 11))
  set.hold(Lease(id: "permanent", label: "Permanent"))
  set.removeFinished(now: now, isRunning: { $0 == 11 })
  #expect(set.leases.map(\.id) == ["future", "running", "permanent"])
}

@Test func buildsLeasesFromHoldRequests() throws {
  let request = ControlRequest(
    command: .hold, id: "greendale.build-1", label: "  Greendale build  ", seconds: 90, pid: 42)
  let lease = try Lease(holding: request, now: now, isRunning: { $0 == 42 })
  #expect(
    lease
      == Lease(
        id: "greendale.build-1", label: "Greendale build", deadline: now.addingTimeInterval(90),
        pid: 42))
}

@Test func fillsInMissingIDsAndLabels() throws {
  let lease = try Lease(holding: ControlRequest(command: .hold), now: now, isRunning: { _ in true })
  #expect(lease.id.count == 8)
  #expect(lease.label == lease.id)
  #expect(lease.deadline == nil)
  #expect(lease.pid == nil)
  let blank = try Lease(
    holding: ControlRequest(command: .hold, id: "chang", label: "   "), now: now,
    isRunning: { _ in true })
  #expect(blank.label == "chang")
}

@Test func truncatesLongLabels() throws {
  let request = ControlRequest(command: .hold, label: String(repeating: "x", count: 100))
  let lease = try Lease(holding: request, now: now, isRunning: { _ in true })
  #expect(lease.label.count == 64)
}

@Test func rejectsInvalidHoldRequests() {
  let cases: [String: (ControlRequest, String)] = [
    "empty id": (ControlRequest(command: .hold, id: ""), "Lease IDs"),
    "long id": (ControlRequest(command: .hold, id: String(repeating: "a", count: 65)), "Lease IDs"),
    "spaces in id": (ControlRequest(command: .hold, id: "Troy Barnes"), "Lease IDs"),
    "reserved id": (ControlRequest(command: .hold, id: "user"), "reserved"),
    "zero seconds": (ControlRequest(command: .hold, seconds: 0), "duration"),
    "negative seconds": (ControlRequest(command: .hold, seconds: -5), "duration"),
    "nan seconds": (ControlRequest(command: .hold, seconds: .nan), "duration"),
    "too many seconds": (
      ControlRequest(command: .hold, seconds: Lease.maximumSeconds + 1), "duration"
    ),
    "zero pid": (ControlRequest(command: .hold, pid: 0), "not running"),
    "exited pid": (ControlRequest(command: .hold, pid: 99), "not running"),
  ]
  for (name, tc) in cases {
    let (request, want) = tc
    do {
      let lease = try Lease(holding: request, now: now, isRunning: { $0 != 99 })
      Issue.record("\(name): got \(lease), want an error")
    } catch {
      #expect(error.message.contains(want), "\(name): \(error.message)")
    }
  }
}

@Test func detectsRunningProcesses() {
  #expect(processIsRunning(getpid()))
  #expect(processIsRunning(1))
  #expect(!processIsRunning(Int32.max))
}
