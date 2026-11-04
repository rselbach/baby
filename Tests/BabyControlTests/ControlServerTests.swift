import Darwin
import Foundation
import Testing

@testable import BabyControl

// socket paths must fit in sockaddr_un, so tests use short /tmp paths
@MainActor
private func withSocketURL(_ body: (URL) async throws -> Void) async throws {
  let directory = URL(filePath: "/tmp/baby-\(UUID().uuidString.prefix(8))")
  defer { try? FileManager.default.removeItem(at: directory) }
  try await body(directory.appending(path: "control.sock"))
}

@MainActor
private final class Recorder {
  var requests: [ControlRequest] = []
}

private func send(_ request: ControlRequest, to url: URL) async throws -> ControlResponse {
  try await Task.detached { try ControlClient.send(request, to: url) }.value
}

// sendRaw writes bytes to the socket and returns the reply line.
private func sendRaw(_ bytes: String, to url: URL) async throws -> String {
  try await Task.detached {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(fd >= 0)
    defer { close(fd) }
    try configure(fd, timeout: 5)
    let status = try withAddress(url.path) { connect(fd, $0, $1) }
    #expect(status == 0)
    try writeMessage(fd, Data(bytes.utf8))
    return String(decoding: try readMessage(fd), as: UTF8.self)
  }.value
}

@MainActor
@Test func answersRequestsOnTheMainActor() async throws {
  try await withSocketURL { url in
    let recorder = Recorder()
    let lease = Lease(
      id: "troy", label: "Troy Barnes", deadline: Date(timeIntervalSince1970: 1_800_000_000),
      pid: 42)
    let server = try ControlServer(url: url) { request in
      MainActor.assertIsolated()
      recorder.requests.append(request)
      return ControlResponse(lease: lease, leases: [lease])
    }
    defer { server.stop() }
    let request = ControlRequest(command: .hold, id: "troy", label: "Troy Barnes", seconds: 90)
    let response = try await send(request, to: url)
    #expect(response == ControlResponse(lease: lease, leases: [lease]))
    #expect(recorder.requests == [request])
  }
}

@MainActor
@Test func reportsRequestsItCannotDecode() async throws {
  try await withSocketURL { url in
    let server = try ControlServer(url: url) { _ in ControlResponse() }
    defer { server.stop() }
    let reply = try await sendRaw(#"{"command":"dance"}"#, to: url)
    let response = try ControlCoding.decoder().decode(ControlResponse.self, from: Data(reply.utf8))
    #expect(response.error == "Baby could not read the request.")
  }
}

@MainActor
@Test func restrictsTheSocketToItsOwner() async throws {
  try await withSocketURL { url in
    let server = try ControlServer(url: url) { _ in ControlResponse() }
    defer { server.stop() }
    let socket = try FileManager.default.attributesOfItem(atPath: url.path)
    let directory = try FileManager.default.attributesOfItem(
      atPath: url.deletingLastPathComponent().path)
    #expect(socket[.posixPermissions] as? Int == 0o600)
    #expect(directory[.posixPermissions] as? Int == 0o700)
  }
}

@MainActor
@Test func replacesAStaleSocket() async throws {
  try await withSocketURL { url in
    let first = try ControlServer(url: url) { _ in ControlResponse(error: "first") }
    first.stop()
    // a crashed Baby leaves its socket file behind
    let stale = try ControlServer(url: url) { _ in ControlResponse(error: "stale") }
    let second = try ControlServer(url: url) { _ in ControlResponse(error: "second") }
    defer { second.stop() }
    let response = try await send(ControlRequest(command: .status), to: url)
    #expect(response.error == "second")
    // the replaced server must not remove its successor's socket
    stale.stop()
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(try await send(ControlRequest(command: .status), to: url).error == "second")
  }
}

@MainActor
@Test func stopRemovesTheSocket() async throws {
  try await withSocketURL { url in
    let server = try ControlServer(url: url) { _ in ControlResponse() }
    server.stop()
    #expect(!FileManager.default.fileExists(atPath: url.path))
    await #expect(throws: ControlError.notRunning) {
      try await send(ControlRequest(command: .status), to: url)
    }
  }
}

@MainActor
@Test func reportsMissingBabyAsNotRunning() async throws {
  try await withSocketURL { url in
    #expect(throws: ControlError.notRunning) {
      try ControlClient.send(ControlRequest(command: .status), to: url)
    }
  }
}

@Test func rejectsSocketPathsThatDoNotFit() {
  let url = URL(filePath: "/tmp/" + String(repeating: "a", count: 200))
  #expect(throws: ControlError.pathTooLong(url.path)) {
    try ControlClient.send(ControlRequest(command: .status), to: url)
  }
}

@Test func encodesDeadlinesAsISO8601() throws {
  let lease = Lease(id: "abed", label: "Abed Nadir", deadline: Date(timeIntervalSince1970: 0))
  let json = String(decoding: try ControlCoding.encoder().encode(lease), as: UTF8.self)
  #expect(json == #"{"deadline":"1970-01-01T00:00:00Z","id":"abed","label":"Abed Nadir"}"#)
  #expect(try ControlCoding.decoder().decode(Lease.self, from: Data(json.utf8)) == lease)
}
