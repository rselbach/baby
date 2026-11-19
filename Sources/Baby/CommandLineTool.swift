import Darwin
import Foundation

/// The baby command line tool inside Baby.app and its link in ~/.local/bin.
enum CommandLineTool {
  /// Where Install links the tool.
  static let link = FileManager.default.homeDirectoryForCurrentUser.appending(
    components: ".local", "bin", "baby")

  /// The tool inside the running app, or nil when Baby runs outside a bundle.
  static var helper: URL? {
    let url = Bundle.main.bundleURL.appending(components: "Contents", "Helpers", "baby")
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
  }

  /// Reports whether `link` points at `helper`.
  static func isInstalled(_ helper: URL, at link: URL = CommandLineTool.link) -> Bool {
    (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == helper.path
  }

  /// Links `helper` at `link`, replacing an earlier link to a Baby helper but
  /// never another file or a link to anything else.
  static func install(
    _ helper: URL,
    at link: URL = CommandLineTool.link,
    rename: (URL, URL) throws -> Void = atomicRename
  ) throws {
    let files = FileManager.default
    let directory = link.deletingLastPathComponent()
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    if let destination = try? files.destinationOfSymbolicLink(atPath: link.path) {
      guard isBabyHelper(destination) else {
        throw CocoaError(
          .fileWriteFileExists,
          userInfo: [
            NSLocalizedDescriptionKey:
              "\(link.path) links to \(destination). Remove it to install Baby's tool."
          ])
      }
    } else if files.fileExists(atPath: link.path) {
      throw CocoaError(
        .fileWriteFileExists,
        userInfo: [
          NSLocalizedDescriptionKey:
            "\(link.path) already exists. Move it aside to install Baby's tool."
        ])
    }

    // stage the new symlink beside `link` and rename it into place so `link`
    // is never missing while replacing an earlier Baby link.
    let temporary = directory.appending(
      path: ".\(link.lastPathComponent)-\(UUID().uuidString)", directoryHint: .notDirectory)
    try files.createSymbolicLink(at: temporary, withDestinationURL: helper)
    do {
      try rename(temporary, link)
    } catch {
      try? files.removeItem(at: temporary)
      throw error
    }
  }

  /// Atomically moves `source` onto `destination` on the same volume.
  private static func atomicRename(_ source: URL, to destination: URL) throws {
    guard Darwin.rename(source.path, destination.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  /// Whether `path` names the tool inside some app bundle, as in
  /// /Applications/Baby.app/Contents/Helpers/baby, wherever that app lives.
  static func isBabyHelper(_ path: String) -> Bool {
    let components = path.split(separator: "/").map(String.init)
    guard components.count >= 4 else { return false }
    return components.suffix(3) == ["Contents", "Helpers", "baby"]
      && components[components.count - 4].hasSuffix(".app")
  }
}
