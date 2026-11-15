import BabyControl
import Foundation
import Testing

@testable import BabyCLI

// Script answers requests in turn, records what the tool did, and stands in
// for a Baby that may not be running yet.
private final class Script {
  var replies: [Result<ControlResponse, ControlError>]
  var sent: [ControlRequest] = []
  var opened = 0
  var paused = 0

  init(_ replies: [Result<ControlResponse, ControlError>]) {
    self.replies = replies
  }

  var connection: BabyConnection {
    BabyConnection(
      send: { request in
        self.sent.append(request)
        guard !self.replies.isEmpty else { throw ControlError.notRunning }
        return try self.replies.removeFirst().get()
      },
      open: { self.opened += 1 },
      pause: { self.paused += 1 },
      attempts: 5)
  }
}

private let status = ControlRequest(command: .status)

@Test func talksToARunningBabyWithoutOpeningIt() throws {
  let script = Script([.success(ControlResponse(leases: []))])
  #expect(try send(status, launch: true, via: script.connection) == ControlResponse(leases: []))
  #expect(script.opened == 0)
  #expect(script.sent == [status])
}

@Test func opensBabyAndWaitsForItToStart() throws {
  let script = Script([
    .failure(.notRunning), .failure(.notRunning), .failure(.notRunning),
    .success(ControlResponse()),
  ])
  #expect(try send(status, launch: true, via: script.connection) == ControlResponse())
  #expect(script.opened == 1)
  #expect(script.paused == 2)
  #expect(script.sent.count == 4)
}

@Test func leavesBabyClosedWhenNotLaunching() {
  let script = Script([.failure(.notRunning)])
  #expect(throws: ControlError.notRunning) {
    try send(status, launch: false, via: script.connection)
  }
  #expect(script.opened == 0)
}

@Test func givesUpOnABabyThatNeverStarts() {
  let script = Script([])
  #expect(throws: CLIError(message: "Baby did not start")) {
    try send(status, launch: true, via: script.connection)
  }
  #expect(script.opened == 1)
  // one try before opening, then every attempt
  #expect(script.sent.count == 6)
}

@Test func reportsErrorsBabySends() {
  let script = Script([.success(ControlResponse(error: "Process 99 is not running."))])
  #expect(throws: CLIError(message: "Process 99 is not running.")) {
    try send(status, launch: true, via: script.connection)
  }
}

@Test func passesOtherFailuresThrough() {
  let script = Script([.failure(.badMessage)])
  #expect(throws: ControlError.badMessage) {
    try send(status, launch: true, via: script.connection)
  }
  #expect(script.opened == 0)
}

@Test func opensTheAppTheToolShipsIn() {
  let app = containingApp(of: "/Applications/Baby.app/Contents/Helpers/baby")
  #expect(app?.path == "/Applications/Baby.app")
  #expect(
    openArguments(app: app) == ["-g", "/Applications/Baby.app", "--args", "--asleep"])
  #expect(containingApp(of: "/nonexistent/bin/baby") == nil)
  #expect(containingApp(of: "/nonexistent/Baby.app/Contents/MacOS/baby") == nil)
  #expect(containingApp(of: nil) == nil)
  #expect(
    openArguments(app: nil) == ["-g", "-b", "com.rselbach.baby", "--args", "--asleep"])
}
