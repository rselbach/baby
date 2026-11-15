import Foundation
import Testing

@testable import Baby

private func temporaryFolder() throws -> URL {
  let folder = FileManager.default.temporaryDirectory
    .appending(path: "baby-cli-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  return folder
}

@Test func recognizesBabyHelpers() {
  #expect(CommandLineTool.isBabyHelper("/Applications/Baby.app/Contents/Helpers/baby"))
  #expect(CommandLineTool.isBabyHelper("/Users/troy/Downloads/Baby 2.app/Contents/Helpers/baby"))
  #expect(CommandLineTool.isBabyHelper("../../Applications/Baby.app/Contents/Helpers/baby"))
  #expect(!CommandLineTool.isBabyHelper("/opt/homebrew/bin/baby"))
  #expect(!CommandLineTool.isBabyHelper("/Applications/Baby.app/Contents/MacOS/Baby"))
  #expect(!CommandLineTool.isBabyHelper("/Contents/Helpers/baby"))
  #expect(!CommandLineTool.isBabyHelper("/tmp/Other/Contents/Helpers/baby"))
}

@Test func installsAndReplacesOnlyBabyLinks() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let link = root.appending(path: "bin/baby")
  let old = root.appending(path: "Old/Baby.app/Contents/Helpers/baby")
  let new = root.appending(path: "New/Baby.app/Contents/Helpers/baby")

  try CommandLineTool.install(old, at: link)
  #expect(CommandLineTool.isInstalled(old, at: link))
  // an earlier Baby's link, even a dangling one, is replaced
  try CommandLineTool.install(new, at: link)
  #expect(CommandLineTool.isInstalled(new, at: link))
  #expect(!CommandLineTool.isInstalled(old, at: link))
}

@Test func refusesToReplaceOtherFilesAndLinks() throws {
  let root = try temporaryFolder()
  defer { try? FileManager.default.removeItem(at: root) }
  let helper = root.appending(path: "Baby.app/Contents/Helpers/baby")
  let link = root.appending(path: "bin/baby")
  try FileManager.default.createDirectory(
    at: link.deletingLastPathComponent(), withIntermediateDirectories: true)

  let other = root.appending(path: "other-baby")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
  #expect(throws: CocoaError.self) { try CommandLineTool.install(helper, at: link) }
  #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == other.path)

  try FileManager.default.removeItem(at: link)
  try Data("#!/bin/sh\n".utf8).write(to: link)
  #expect(throws: CocoaError.self) { try CommandLineTool.install(helper, at: link) }
  #expect(try Data(contentsOf: link) == Data("#!/bin/sh\n".utf8))
}
