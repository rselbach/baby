import Foundation
import Testing

@testable import Baby
@testable import BabyControl

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Test func holdsLeasesInOrderAndReplacesByID() throws {
  var set = LeaseSet()
  try set.hold(Lease(id: "troy", label: "Troy"))
  try set.hold(Lease(id: "abed", label: "Abed"))
  try set.hold(Lease(id: "troy", label: "Troy Barnes", pid: 7))
  #expect(
    set.leases == [
      Lease(id: "troy", label: "Troy Barnes", pid: 7), Lease(id: "abed", label: "Abed"),
    ])
  set.removeAll { $0.id == "troy" }
  #expect(set.leases.map(\.id) == ["abed"])
  #expect(!set.isEmpty)
}

@Test func findsTheEarliestDeadline() throws {
  var set = LeaseSet()
  #expect(set.nextDeadline == nil)
  try set.hold(Lease(id: "permanent", label: "Permanent"))
  #expect(set.nextDeadline == nil)
  try set.hold(Lease(id: "late", label: "Late", deadline: now.addingTimeInterval(600)))
  try set.hold(Lease(id: "soon", label: "Soon", deadline: now.addingTimeInterval(60)))
  #expect(set.nextDeadline == now.addingTimeInterval(60))
}

@Test func removesExpiredLeasesAndExitedProcesses() throws {
  var set = LeaseSet()
  try set.hold(Lease(id: "expired", label: "Expired", deadline: now))
  try set.hold(Lease(id: "future", label: "Future", deadline: now.addingTimeInterval(1)))
  try set.hold(Lease(id: "exited", label: "Exited", pid: 10))
  try set.hold(Lease(id: "running", label: "Running", pid: 11))
  try set.hold(Lease(id: "permanent", label: "Permanent"))
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

@Test func keepsTheDisplayOnOnlyForTheUser() throws {
  var set = LeaseSet()
  #expect(set.powerAssertions.isEmpty)
  try set.hold(Lease(id: "abed", label: "Abed"))
  #expect(set.powerAssertions == [.idleSystemSleep, .systemSleep])
  try set.hold(Lease(id: LeaseSet.userID, label: "You"))
  #expect(set.powerAssertions == [.idleSystemSleep, .systemSleep, .displaySleep])
  set.removeAll { $0.id == "abed" }
  #expect(set.powerAssertions == [.idleSystemSleep, .systemSleep, .displaySleep])
}

@Test func tracksTheUsersLeaseApartFromAgents() throws {
  var set = LeaseSet()
  #expect(!set.holdsUserLease)
  try set.hold(Lease(id: "abed", label: "Abed"))
  #expect(!set.holdsUserLease)
  try set.hold(Lease(id: LeaseSet.userID, label: "You"))
  #expect(set.holdsUserLease)
  set.removeAll { $0.id == "abed" }
  #expect(set.holdsUserLease)
}

@Test func indicatesWhoKeepsTheMacAwake() throws {
  var set = LeaseSet()
  #expect(set.indicator == .asleep)
  try set.hold(Lease(id: "abed", label: "Abed"))
  #expect(set.indicator == .awakeForOthers)
  try set.hold(Lease(id: LeaseSet.userID, label: "You"))
  #expect(set.indicator == .awakeForUser)
}

@Test func boundsAgentLeasesAndKeepsRoomForTheUser() throws {
  var set = LeaseSet()
  for index in 0..<63 {
    try set.hold(Lease(id: "troy-\(index)", label: "Troy Barnes"))
  }
  #expect(throws: LeaseRequestError.self) {
    try set.hold(Lease(id: "abed", label: "Abed Nadir"))
  }
  try set.hold(Lease(id: "troy-0", label: "Greendale"))
  try set.hold(Lease(id: LeaseSet.userID, label: "You"))
  #expect(set.leases.count == 64)
  #expect(set.leases.first?.label == "Greendale")
  set.removeAll { $0.id == "troy-1" }
  try set.hold(Lease(id: "abed", label: "Abed Nadir"))
  #expect(set.leases.count == 64)
}

@Test func truncatesLabelsToTheirByteLimit() throws {
  let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
  #expect(family.count == 1 && family.utf8.count == 25)
  let wide = try Lease(
    holding: ControlRequest(command: .hold, id: "troy", label: String(repeating: family, count: 64)),
    now: now, isRunning: { _ in true })
  #expect(wide.label == String(repeating: family, count: 10))

  // a single character too large for a label leaves the ID as the label
  let unbounded = "a" + String(repeating: "\u{0301}", count: 300)
  #expect(unbounded.count == 1)
  let lease = try Lease(
    holding: ControlRequest(command: .hold, id: "troy", label: unbounded), now: now,
    isRunning: { _ in true })
  #expect(lease.label == "troy")
}

@Test func fullLeaseSetsFitTheStatusAndRelaunchFormats() throws {
  var set = LeaseSet()
  for index in 0..<LeaseSet.maximumAgentLeases {
    let suffix = String(index)
    let id = String(repeating: "t", count: 64 - suffix.count) + suffix
    try set.hold(
      Lease(
        id: id, label: String(repeating: "\u{0001}", count: 64),
        deadline: .distantFuture, pid: Int32.max))
  }
  try set.hold(Lease(id: LeaseSet.userID, label: "You", deadline: .distantFuture))
  let response = try ControlCoding.encoder().encode(ControlResponse(leases: set.leases))
  #expect(response.count <= maximumMessageSize)
  let data = try ControlCoding.encoder().encode(set.leases)
  #expect(("--leases=" + data.base64EncodedString()).utf8.count < 64 * 1024)
  #expect(try LeaseSet(restoring: data).leases == set.leases)
}

@Test func skipsInvalidLeasesWhenRestoring() throws {
  let cases: [(leases: [Lease], kept: Int)] = [
    ([Lease(id: "troy", label: "Troy", pid: 0)], 0),
    ([Lease(id: "../troy", label: "Troy")], 0),
    ([Lease(id: "troy", label: String(repeating: "a", count: 65))], 0),
    ((0...LeaseSet.maximumAgentLeases).map { Lease(id: "troy-\($0)", label: "Troy") },
      LeaseSet.maximumAgentLeases),
  ]
  for (leases, kept) in cases {
    let data = try ControlCoding.encoder().encode(leases)
    var rejected: [String] = []
    let set = try LeaseSet(restoring: data, rejected: &rejected)
    #expect(set.leases.count == kept)
    #expect(rejected.count == leases.count - kept)
  }
}

@Test func keepsValidLeasesBesideAnInvalidOne() throws {
  let leases = [
    Lease(id: "troy", label: "Troy"),
    Lease(id: "abed", label: "Abed", pid: -1),
    Lease(id: LeaseSet.userID, label: "You"),
  ]
  var rejected: [String] = []
  let set = try LeaseSet(
    restoring: try ControlCoding.encoder().encode(leases), rejected: &rejected)
  #expect(set.leases.map(\.id) == ["troy", LeaseSet.userID])
  #expect(rejected.count == 1)
  #expect(rejected.first?.hasPrefix("abed:") == true)
}

@Test func rejectsRestoreDataThatIsNotALeaseList() {
  for data in [Data(), Data("{}".utf8), Data("[{\"id\": 3}]".utf8)] {
    #expect(throws: DecodingError.self) { try LeaseSet(restoring: data) }
  }
}

@Test func avoidsCollisionsWhenGeneratingLeaseIDs() throws {
  var set = LeaseSet()
  try set.hold(Lease(id: "deadbeef", label: "Troy"))
  try set.hold(Lease(id: "cafebabe", label: "Abed"))

  var candidates = ["deadbeef", LeaseSet.userID, "cafebabe", "feedface"].makeIterator()
  let generated = try set.hold(
    ControlRequest(command: .hold), now: now, isRunning: { _ in true },
    generateID: { candidates.next() ?? "fallback" })

  #expect(generated == Lease(id: "feedface", label: "feedface"))
  #expect(
    set.leases == [
      Lease(id: "deadbeef", label: "Troy"),
      Lease(id: "cafebabe", label: "Abed"),
      Lease(id: "feedface", label: "feedface"),
    ])

  // explicit IDs still replace in place without consulting the generator
  var generatorCalled = false
  let replaced = try set.hold(
    ControlRequest(command: .hold, id: "deadbeef", label: "Troy Barnes"),
    now: now, isRunning: { _ in true },
    generateID: {
      generatorCalled = true
      return "unused00"
    })
  #expect(!generatorCalled)
  #expect(replaced == Lease(id: "deadbeef", label: "Troy Barnes"))
  #expect(set.leases.count == 3)
  #expect(set.leases.first == Lease(id: "deadbeef", label: "Troy Barnes"))
}

@Test func rejectsAutoGeneratedHoldWhenFullInsteadOfOverwriting() throws {
  var set = LeaseSet()
  for index in 0..<LeaseSet.maximumAgentLeases {
    try set.hold(Lease(id: String(format: "%08x", index), label: "Troy \(index)"))
  }
  var candidates = ["00000000", "deadbeef"].makeIterator()
  #expect(throws: LeaseRequestError.self) {
    try set.hold(
      ControlRequest(command: .hold, label: "Abed"), now: now, isRunning: { _ in true },
      generateID: { candidates.next() ?? "fallback" })
  }
  #expect(set.leases.count == LeaseSet.maximumAgentLeases)
  #expect(set.leases.first == Lease(id: "00000000", label: "Troy 0"))
}

@Test func failsWhenAutoGeneratedIDsAlwaysCollide() throws {
  var set = LeaseSet()
  try set.hold(Lease(id: "deadbeef", label: "Troy"))
  #expect(throws: LeaseRequestError.self) {
    try set.hold(
      ControlRequest(command: .hold), now: now, isRunning: { _ in true },
      generateID: { "deadbeef" })
  }
  #expect(throws: LeaseRequestError.self) {
    try set.hold(
      ControlRequest(command: .hold), now: now, isRunning: { _ in true },
      generateID: { LeaseSet.userID })
  }
  #expect(set.leases == [Lease(id: "deadbeef", label: "Troy")])
}
