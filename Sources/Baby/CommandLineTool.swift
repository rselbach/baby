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
  static func install(_ helper: URL, at link: URL = CommandLineTool.link) throws {
    let files = FileManager.default
    try files.createDirectory(
      at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let destination = try? files.destinationOfSymbolicLink(atPath: link.path) {
      guard isBabyHelper(destination) else {
        throw CocoaError(
          .fileWriteFileExists,
          userInfo: [
            NSLocalizedDescriptionKey:
              "\(link.path) links to \(destination). Remove it to install Baby's tool."
          ])
      }
      try files.removeItem(at: link)
    } else if files.fileExists(atPath: link.path) {
      throw CocoaError(
        .fileWriteFileExists,
        userInfo: [
          NSLocalizedDescriptionKey:
            "\(link.path) already exists. Move it aside to install Baby's tool."
        ])
    }
    try files.createSymbolicLink(at: link, withDestinationURL: helper)
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
