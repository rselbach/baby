import BabyControl
import Darwin
import Foundation

/// Persists leases across an update restart next to the control socket so
/// whichever Baby instance acquires the socket lock first restores them, even
/// if the CLI auto-launched Baby with `--asleep` before the updater's relaunch.
struct RelaunchHandoff: Codable, Equatable, Sendable {
  /// Result of attempting to consume a relaunch handoff file.
  enum Outcome: Equatable, Sendable {
    case leases([Lease])
    case absent
    case stale
    case corrupt(String)
  }

  /// Handoffs older than this are discarded instead of resurrecting leases
  /// from an interrupted restart.
  static let maximumAge: TimeInterval = 120
  /// Small tolerance for backward NTP clock steps during a restart.
  static let maximumClockSkew: TimeInterval = 60
  static let maximumFileSize = 64 * 1024
  static let filename = "relaunch-leases.json"

  var createdAt: Date
  var leases: [Lease]

  static func url(nextTo socketURL: URL = ControlSocket.defaultURL) -> URL {
    socketURL.deletingLastPathComponent().appending(path: filename)
  }

  /// Atomically writes `leases` to `url` inside Baby's private socket directory.
  static func write(
    _ leases: [Lease],
    to url: URL = Self.url(),
    now: Date = Date()
  ) throws {
    let data = try ControlCoding.encoder().encode(RelaunchHandoff(createdAt: now, leases: leases))
    try data.write(to: url, options: .atomic)
    _ = chmod(url.path, 0o600)
  }

  /// Removes a regular handoff file at `url`, leaving non-regular paths alone.
  static func remove(at url: URL = Self.url()) {
    var info = stat()
    if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG {
      unlink(url.path)
    }
  }

  /// Reads and removes any regular handoff file at `url`. Only the Baby that
  /// holds the control socket lock calls this, so a handoff is consumed once.
  static func consume(from url: URL = Self.url(), now: Date = Date()) -> Outcome {
    let path = url.path
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    if fd < 0 {
      if errno == ENOENT { return .absent }
      return .corrupt("open failed: \(String(cString: strerror(errno)))")
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)

    var info = stat()
    guard fstat(fd, &info) == 0 else {
      return .corrupt("fstat failed: \(String(cString: strerror(errno)))")
    }
    guard info.st_mode & S_IFMT == S_IFREG else {
      return .corrupt("handoff path is not a regular file")
    }
    // unlink now so stale, oversized, or corrupt handoffs are never left behind
    guard unlink(path) == 0 else {
      return .corrupt("unlink failed: \(String(cString: strerror(errno)))")
    }

    guard info.st_size >= 0, info.st_size <= maximumFileSize else {
      return .corrupt("handoff file exceeds \(maximumFileSize) bytes")
    }
    let data: Data
    do {
      data = try handle.read(upToCount: maximumFileSize + 1) ?? Data()
    } catch {
      return .corrupt(error.localizedDescription)
    }
    guard data.count <= maximumFileSize else {
      return .corrupt("handoff file exceeds \(maximumFileSize) bytes")
    }

    let handoff: RelaunchHandoff
    do {
      handoff = try ControlCoding.decoder().decode(RelaunchHandoff.self, from: data)
    } catch {
      return .corrupt(error.localizedDescription)
    }

    let age = now.timeIntervalSince(handoff.createdAt)
    guard age.isFinite, age >= -maximumClockSkew, age <= maximumAge else {
      return .stale
    }
    return .leases(handoff.leases)
  }
}

/// What Baby holds when it launches, read from its handoff file, arguments,
/// and settings. A fresh relaunch handoff takes precedence so leases survive
/// even when the CLI auto-launches Baby with `--asleep` during an update.
/// Relaunch arguments preserve the live state across an update from earlier
/// Babys and override the launch preference.
enum LaunchState: Equatable {
  /// The leases an updating Baby persisted to the relaunch handoff file.
  case handoff([Lease])
  /// The leases an updating Baby passed along, as JSON. Data that doesn't
  /// decode restores nothing.
  case leases(Data)
  /// The user's own lease, until `until` or until released.
  case awake(until: Date?)
  /// Nothing.
  case asleep

  static let leasesPrefix = "--leases="
  static let deadlinePrefix = "--awake-until="

  init(arguments: [String], activateOnLaunch: Bool, handoff: [Lease]? = nil) {
    if let handoff {
      self = .handoff(handoff)
      return
    }
    if let argument = arguments.first(where: { $0.hasPrefix(Self.leasesPrefix) }) {
      let encoded = String(argument.dropFirst(Self.leasesPrefix.count))
      // invalid base64 decodes to nothing, which the JSON decoder rejects
      self = .leases(Data(base64Encoded: encoded) ?? Data())
      return
    }
    if let argument = arguments.first(where: { $0.hasPrefix(Self.deadlinePrefix) }) {
      guard let timestamp = TimeInterval(argument.dropFirst(Self.deadlinePrefix.count)),
        timestamp.isFinite
      else {
        self = .asleep
        return
      }
      self = .awake(until: Date(timeIntervalSince1970: timestamp))
      return
    }
    let awake =
      arguments.contains("--awake")
      || (!arguments.contains("--asleep") && activateOnLaunch)
    self = awake ? .awake(until: nil) : .asleep
  }

  /// The arguments that carry `leases` into the Baby an update relaunches.
  static func relaunchArguments(for leases: [Lease]) -> [String] {
    guard !leases.isEmpty else { return ["--asleep"] }
    guard let data = try? ControlCoding.encoder().encode(leases) else { return ["--awake"] }
    return [leasesPrefix + data.base64EncodedString()]
  }
}
