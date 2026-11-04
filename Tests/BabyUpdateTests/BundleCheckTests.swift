import Foundation
import Testing

@testable import BabyUpdate

private let adHocRequirement = "identifier \"\(UpdateConfig.bundleIdentifier)\""

private func makeSignedBundle(
  in folder: URL,
  bundleIdentifier: String = UpdateConfig.bundleIdentifier,
  version: String = "1.2.0",
  build: String = "7",
  executable: String = "Baby",
  minimumOS: String = "14.0",
  signIdentifier: String = UpdateConfig.bundleIdentifier
) throws -> URL {
  let app = folder.appending(path: "Baby.app", directoryHint: .isDirectory)
  let macOS = app.appending(components: "Contents", "MacOS")
  try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
  let execFile = executable.contains("/") ? "Baby" : executable
  let binary = macOS.appending(path: execFile)
  try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: binary)

  let plist: [String: Any] = [
    "CFBundleIdentifier": bundleIdentifier,
    "CFBundleShortVersionString": version,
    "CFBundleVersion": build,
    "CFBundleExecutable": executable,
    "CFBundlePackageType": "APPL",
    "LSMinimumSystemVersion": minimumOS,
  ]
  let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
  try data.write(to: app.appending(components: "Contents", "Info.plist"))

  let codesign = Process()
  codesign.executableURL = URL(filePath: "/usr/bin/codesign")
  codesign.arguments = [
    "--force", "--sign", "-", "--identifier", signIdentifier, "--timestamp=none", app.path,
  ]
  codesign.standardOutput = FileHandle.nullDevice
  codesign.standardError = FileHandle.nullDevice
  try codesign.run()
  codesign.waitUntilExit()
  #expect(codesign.terminationStatus == 0)
  return app
}

private func expectedRelease(version: String = "1.2.0", build: Int = 7) -> Release {
  Release(version: version, build: build, publishedAt: "", notesURL: nil, artifacts: [])
}

@Test func verifiesSignedBundle() async throws {
  let root = FileManager.default.temporaryDirectory
    .appending(path: "bundle-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { Installer.remove(root) }

  let app = try makeSignedBundle(in: root)
  try await BundleCheck.verify(
    app: app, release: expectedRelease(), os: OSVersion("14.5")!,
    requirement: adHocRequirement)
}

@Test func rejectsSymlinkAndMissingBundle() async throws {
  let root = FileManager.default.temporaryDirectory
    .appending(path: "bundle-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { Installer.remove(root) }

  let real = try makeSignedBundle(in: root)
  let link = root.appending(path: "Link.app")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

  await #expect(throws: BundleCheckError.notABundle) {
    try await BundleCheck.verify(
      app: link, release: expectedRelease(), os: OSVersion("14.5")!,
      requirement: adHocRequirement)
  }
  await #expect(throws: BundleCheckError.notABundle) {
    try await BundleCheck.verify(
      app: root.appending(path: "Missing.app"), release: expectedRelease(),
      os: OSVersion("14.5")!, requirement: adHocRequirement)
  }
}

@Test func rejectsPlistMismatchesAndNewerOS() async throws {
  let root = FileManager.default.temporaryDirectory
    .appending(path: "bundle-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { Installer.remove(root) }

  let wrongID = try makeSignedBundle(
    in: root.appending(path: "id"), bundleIdentifier: "com.example.other")
  await #expect(throws: BundleCheckError.mismatch("bundle identifier")) {
    try await BundleCheck.verify(
      app: wrongID, release: expectedRelease(), os: OSVersion("14.5")!,
      requirement: adHocRequirement)
  }

  let wrongVersion = try makeSignedBundle(
    in: root.appending(path: "ver"), version: "9.9.9")
  await #expect(throws: BundleCheckError.mismatch("version")) {
    try await BundleCheck.verify(
      app: wrongVersion, release: expectedRelease(), os: OSVersion("14.5")!,
      requirement: adHocRequirement)
  }

  let wrongBuild = try makeSignedBundle(in: root.appending(path: "bld"), build: "99")
  await #expect(throws: BundleCheckError.mismatch("build")) {
    try await BundleCheck.verify(
      app: wrongBuild, release: expectedRelease(), os: OSVersion("14.5")!,
      requirement: adHocRequirement)
  }

  let dotExec = try makeSignedBundle(
    in: root.appending(path: "exec"), executable: ".Baby")
  await #expect(throws: BundleCheckError.mismatch("executable")) {
    try await BundleCheck.verify(
      app: dotExec, release: expectedRelease(), os: OSVersion("14.5")!,
      requirement: adHocRequirement)
  }

  let newerOS = try makeSignedBundle(
    in: root.appending(path: "os"), minimumOS: "15.2")
  await #expect(throws: BundleCheckError.requiresNewerOS("15.2")) {
    try await BundleCheck.verify(
      app: newerOS, release: expectedRelease(), os: OSVersion("15.1")!,
      requirement: adHocRequirement)
  }
}

@Test func rejectsTamperedSignedBundle() async throws {
  let root = FileManager.default.temporaryDirectory
    .appending(path: "bundle-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { Installer.remove(root) }

  let app = try makeSignedBundle(in: root)
  try Data("unsealed".utf8).write(
    to: app.appending(components: "Contents", "MacOS", "extra"))

  await #expect {
    try await BundleCheck.verify(
      app: app, release: expectedRelease(), os: OSVersion("14.5")!,
      requirement: adHocRequirement)
  } throws: { error in
    guard case BundleCheckError.signature = error else { return false }
    return true
  }
}
