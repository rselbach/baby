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

  /// Reports whether the link points at `helper`.
  static func isInstalled(_ helper: URL) -> Bool {
    (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == helper.path
  }

  /// Links `helper` into ~/.local/bin, replacing an earlier link but never
  /// another file.
  static func install(_ helper: URL) throws {
    let files = FileManager.default
    try files.createDirectory(
      at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    if (try? files.destinationOfSymbolicLink(atPath: link.path)) != nil {
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
}
