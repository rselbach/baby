import Foundation

/// File-system steps of installing an update: staging folders next to the
/// app, the atomic bundle swap, the relaunch waiter, and cleanup.
public enum Installer {
  /// Name prefix of staging folders; nothing else is ever removed.
  public static let stagingPrefix = ".baby-update-"

  /// Creates a new staging folder in `parent` named after `build` and this
  /// process, never reusing an existing one.
  public static func makeStagingFolder(in parent: URL, build: Int) throws -> URL {
    let suffix = UUID().uuidString.prefix(8)
    let folder = parent.appending(
      path: "\(stagingPrefix)\(build)-\(getpid())-\(suffix)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
  }

  /// Exchanges two paths on the same volume in one atomic rename.
  public static func swap(_ first: URL, _ second: URL) throws {
    guard renamex_np(first.path, second.path, UInt32(RENAME_SWAP)) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  /// Unpacks a ZIP made by `ditto -c -k --keepParent` into `folder`.
  @concurrent
  public static func unzip(_ zip: URL, into folder: URL) async throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", zip.path, folder.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
      }
    }
    guard status == 0 else {
      throw CocoaError(
        .fileReadCorruptFile,
        userInfo: [NSLocalizedDescriptionKey: "The update archive could not be unpacked."])
    }
  }

  /// Starts a detached /bin/sh that waits up to a minute for `pid` to exit,
  /// then runs `command`. Arguments arrive as positional parameters, never
  /// as shell text, and the waiter gets its own process group so nothing
  /// aimed at the app's reaches it.
  public static func runAfterExit(of pid: pid_t, _ command: [String]) throws {
    let waiter = """
      pid="$1"; shift; i=0
      while /bin/kill -0 "$pid" 2>/dev/null; do
        i=$((i + 1))
        if [ "$i" -gt 600 ]; then exit 1; fi
        /bin/sleep 0.1
      done
      exec "$@"
      """
    let arguments = ["/bin/sh", "-c", waiter, "baby-relaunch", String(pid)] + command

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(
      &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
    posix_spawnattr_setpgroup(&attributes, 0)

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

    let argv = arguments.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var child: pid_t = 0
    let status = posix_spawn(&child, "/bin/sh", &actions, &attributes, argv, environ)
    guard status == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
    }
  }

  /// Deletes staging folders in `parent` whose owning process is gone; they
  /// hold a finished update's old bundle or an abandoned download.
  public static func removeLeftovers(in parent: URL) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
    for name in names where name.hasPrefix(stagingPrefix) {
      let fields = name.dropFirst(stagingPrefix.count).split(separator: "-")
      guard fields.count == 3, let pid = pid_t(fields[1]), pid != getpid() else { continue }
      if kill(pid, 0) == 0 || errno == EPERM { continue }
      remove(parent.appending(path: name))
    }
  }

  /// Deletes `folder`, first making every directory in it writable:
  /// read-only folders inside bundles otherwise block removal.
  public static func remove(_ folder: URL) {
    let manager = FileManager.default
    func makeWritableDirectory(_ item: URL) {
      let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values?.isDirectory == true, values?.isSymbolicLink == false else { return }
      let mode = (try? manager.attributesOfItem(atPath: item.path)[.posixPermissions])
        as? Int ?? 0
      try? manager.setAttributes([.posixPermissions: mode | 0o700], ofItemAtPath: item.path)
    }
    makeWritableDirectory(folder)
    if let items = manager.enumerator(
      at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    {
      for case let item as URL in items {
        makeWritableDirectory(item)
      }
    }
    try? manager.removeItem(at: folder)
  }
}
