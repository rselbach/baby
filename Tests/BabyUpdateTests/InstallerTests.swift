import Foundation
import Testing

@testable import BabyUpdate

private func temporaryFolder() throws -> URL {
  let folder = FileManager.default.temporaryDirectory
    .appending(path: "baby-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  return folder
}

private func exitedPID() throws -> pid_t {
  let process = Process()
  process.executableURL = URL(filePath: "/usr/bin/true")
  try process.run()
  process.waitUntilExit()
  return process.processIdentifier
}

@Test func swapsBundles() throws {
  let root = try temporaryFolder()
  defer { Installer.remove(root) }
  let installed = root.appending(path: "Baby.app")
  let staged = root.appending(path: "staged/Baby.app")
  try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
  try Data("old".utf8).write(to: installed.appending(path: "marker"))
  try Data("new".utf8).write(to: staged.appending(path: "marker"))

  try Installer.swap(staged, installed)
  #expect(try String(contentsOf: installed.appending(path: "marker"), encoding: .utf8) == "new")
  #expect(try String(contentsOf: staged.appending(path: "marker"), encoding: .utf8) == "old")
}

@Test func removesOnlyAbandonedStagingFolders() throws {
  let root = try temporaryFolder()
  defer { Installer.remove(root) }
  let dead = root.appending(path: "\(Installer.stagingPrefix)7-\(try exitedPID())-deadbeef")
  let mine = try Installer.makeStagingFolder(in: root, build: 7)
  let alive = root.appending(path: "\(Installer.stagingPrefix)7-1-cafebabe")
  let unrelated = root.appending(path: "Greendale.app")
  // a read-only folder inside a bundle must not block removal
  let locked = dead.appending(path: "Baby.app/Contents")
  for folder in [locked, alive, unrelated] {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }
  try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)

  Installer.removeLeftovers(in: root)
  #expect(!FileManager.default.fileExists(atPath: dead.path))
  #expect(FileManager.default.fileExists(atPath: mine.path))
  #expect(FileManager.default.fileExists(atPath: alive.path))
  #expect(FileManager.default.fileExists(atPath: unrelated.path))
}

@Test func runsCommandAfterProcessExits() async throws {
  let root = try temporaryFolder()
  defer { Installer.remove(root) }
  let marker = root.appending(path: "relaunched with spaces")
  let sleeper = Process()
  sleeper.executableURL = URL(filePath: "/bin/sleep")
  sleeper.arguments = ["0.5"]
  try sleeper.run()

  try Installer.runAfterExit(of: sleeper.processIdentifier, ["/usr/bin/touch", marker.path])
  try await Task.sleep(for: .milliseconds(200))
  #expect(!FileManager.default.fileExists(atPath: marker.path))

  sleeper.waitUntilExit()
  for _ in 0..<50 where !FileManager.default.fileExists(atPath: marker.path) {
    try await Task.sleep(for: .milliseconds(100))
  }
  #expect(FileManager.default.fileExists(atPath: marker.path))
}

@Test func unzipsDittoArchives() async throws {
  let root = try temporaryFolder()
  defer { Installer.remove(root) }
  let app = root.appending(path: "source/Baby.app/Contents")
  try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
  try Data("Troy Barnes".utf8).write(to: app.appending(path: "Info.plist"))
  let zip = root.appending(path: "Baby.zip")
  let ditto = Process()
  ditto.executableURL = URL(filePath: "/usr/bin/ditto")
  ditto.arguments = [
    "-c", "-k", "--sequesterRsrc", "--keepParent", root.appending(path: "source/Baby.app").path,
    zip.path,
  ]
  try ditto.run()
  ditto.waitUntilExit()
  #expect(ditto.terminationStatus == 0)

  let out = try Installer.makeStagingFolder(in: root, build: 1)
  try await Installer.unzip(zip, into: out)
  let unpacked = out.appending(path: "Baby.app/Contents/Info.plist")
  #expect(try String(contentsOf: unpacked, encoding: .utf8) == "Troy Barnes")
}

@Test func removesReadOnlyRootFolder() throws {
  let root = try temporaryFolder()
  defer { Installer.remove(root) }
  let lockedRoot = root.appending(path: "locked-stage")
  try FileManager.default.createDirectory(
    at: lockedRoot.appending(path: "Baby.app"), withIntermediateDirectories: true)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o500], ofItemAtPath: lockedRoot.path)

  Installer.remove(lockedRoot)
  #expect(!FileManager.default.fileExists(atPath: lockedRoot.path))
}

@Test func closesExtraFileDescriptorsInWaiter() async throws {
  let root = try temporaryFolder()
  defer { Installer.remove(root) }
  let leakedFile = root.appending(path: "secret")
  try Data("secret".utf8).write(to: leakedFile)
  let fd = open(leakedFile.path, O_RDONLY)
  #expect(fd >= 3)
  defer { close(fd) }
  _ = fcntl(fd, F_SETFD, 0)

  let out = root.appending(path: "result")
  try Installer.runAfterExit(
    of: try exitedPID(),
    ["/bin/sh", "-c", "if (exec <&\"$1\") 2>/dev/null; then echo leaked; else echo closed; fi >\"$2\"", "probe", String(fd), out.path])
  for _ in 0..<50 where !FileManager.default.fileExists(atPath: out.path) {
    try await Task.sleep(for: .milliseconds(50))
  }
  #expect(try String(contentsOf: out, encoding: .utf8) == "closed\n")
}

@Test func rejectsCorruptArchives() async throws {
  let root = try temporaryFolder()
  defer { Installer.remove(root) }
  let zip = root.appending(path: "bad.zip")
  try Data("not a zip".utf8).write(to: zip)
  await #expect(throws: CocoaError.self) {
    try await Installer.unzip(zip, into: root)
  }
}
