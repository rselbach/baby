import Darwin
import Foundation

/// Listens on Baby's control socket and answers each request on the main
/// actor. Only processes running as the same user can connect.
public final class ControlServer: Sendable {
  private let source: any DispatchSourceRead
  private let stopped = DispatchGroup()

  /// How many connections are served at once by default. Each waits up to
  /// five seconds for its request on its own thread, so this bounds how many
  /// threads a misbehaving client can tie up.
  public static let defaultMaximumConnections = 8

  /// Starts listening at `url`, replacing any socket an earlier Baby left
  /// there. `handler` runs on the main actor once per request. Connections
  /// beyond `maximumConnections` at once are answered that Baby is busy.
  public init(
    url: URL, maximumConnections: Int = defaultMaximumConnections,
    handler: @escaping @MainActor @Sendable (ControlRequest) -> ControlResponse
  ) throws {
    let path = url.path
    let directory = url.deletingLastPathComponent().path
    try FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true)
    guard chmod(directory, 0o700) == 0 else { throw ControlError.system("chmod", errno) }
    let lock = open(path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
    guard lock >= 0 else { throw ControlError.system("open", errno) }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
      let failure = errno
      close(lock)
      if failure == EWOULDBLOCK { throw ControlError.alreadyRunning }
      throw ControlError.system("flock", failure)
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      let failure = errno
      close(lock)
      throw ControlError.system("socket", failure)
    }
    let inode: ino_t
    do {
      inode = try Self.listen(fd, at: path)
    } catch {
      close(fd)
      close(lock)
      throw error
    }
    source = DispatchSource.makeReadSource(
      fileDescriptor: fd, queue: DispatchQueue(label: "com.rselbach.baby.control"))
    let slots = DispatchSemaphore(value: maximumConnections)
    source.setEventHandler { Self.accept(on: fd, slots: slots, handler: handler) }
    let stopped = self.stopped
    stopped.enter()
    source.setCancelHandler {
      var info = stat()
      if lstat(path, &info) == 0, info.st_ino == inode { unlink(path) }
      close(fd)
      close(lock)
      stopped.leave()
    }
    source.resume()
  }

  deinit {
    stop()
  }

  /// Stops listening and removes the socket, unless a newer Baby has
  /// already replaced it.
  public func stop() {
    source.cancel()
    stopped.wait()
  }

  // listen binds fd to path and returns the socket file's inode.
  private static func listen(_ fd: Int32, at path: String) throws -> ino_t {
    let failure = try withAddress(path) { address, length in
      var existing = stat()
      if lstat(path, &existing) == 0 {
        guard existing.st_mode & S_IFMT == S_IFSOCK else {
          throw ControlError.system("bind", EEXIST)
        }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw ControlError.system("socket", errno) }
        defer { close(probe) }
        guard fcntl(probe, F_SETFL, O_NONBLOCK) == 0 else {
          throw ControlError.system("fcntl", errno)
        }
        if connect(probe, address, length) == 0 { throw ControlError.alreadyRunning }
        switch errno {
        case ECONNREFUSED, ENOENT: break
        case EINPROGRESS, EAGAIN: throw ControlError.alreadyRunning
        default: throw ControlError.system("connect", errno)
        }
        guard unlink(path) == 0 || errno == ENOENT else {
          throw ControlError.system("unlink", errno)
        }
      } else if errno != ENOENT {
        throw ControlError.system("lstat", errno)
      }
      return bind(fd, address, length) == 0 ? 0 : errno
    }
    guard failure == 0 else { throw ControlError.system("bind", failure) }
    var listening = false
    defer { if !listening { unlink(path) } }
    guard chmod(path, 0o600) == 0 else { throw ControlError.system("chmod", errno) }
    // nonblocking so a client that gives up before accept can't stall the queue
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw ControlError.system("fcntl", errno)
    }
    guard Darwin.listen(fd, 16) == 0 else { throw ControlError.system("listen", errno) }
    var info = stat()
    guard stat(path, &info) == 0 else { throw ControlError.system("stat", errno) }
    listening = true
    return info.st_ino
  }

  private static func accept(
    on fd: Int32, slots: DispatchSemaphore,
    handler: @escaping @MainActor @Sendable (ControlRequest) -> ControlResponse
  ) {
    let client = Darwin.accept(fd, nil, nil)
    guard client >= 0 else { return }
    guard slots.wait(timeout: .now()) == .success else {
      refuse(client)
      return
    }
    DispatchQueue.global().async {
      defer { slots.signal() }
      serve(client, handler: handler)
    }
  }

  // refuse tells a client over the connection limit to try again, without
  // reading its request or blocking the accept queue.
  private static func refuse(_ client: Int32) {
    defer { close(client) }
    var uid = uid_t(0)
    var gid = gid_t(0)
    guard getpeereid(client, &uid, &gid) == 0, uid == getuid(),
      (try? configure(client, timeout: 1)) != nil,
      let reply = try? ControlCoding.encoder().encode(
        ControlResponse(error: "Baby is busy. Try again in a moment."))
    else { return }
    // the reply fits in an empty socket buffer, so this write doesn't block
    try? writeMessage(client, reply)
  }

  private static func serve(
    _ client: Int32, handler: @MainActor @Sendable (ControlRequest) -> ControlResponse
  ) {
    defer { close(client) }
    var uid = uid_t(0)
    var gid = gid_t(0)
    guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
    // accepted sockets inherit the listener's O_NONBLOCK on macOS
    let flags = fcntl(client, F_GETFL)
    guard flags >= 0, fcntl(client, F_SETFL, flags & ~O_NONBLOCK) == 0 else { return }
    let response: ControlResponse
    do {
      try configure(client, timeout: 5)
      let request = try ControlCoding.decoder().decode(
        ControlRequest.self, from: readMessage(client))
      response = DispatchQueue.main.sync { MainActor.assumeIsolated { handler(request) } }
    } catch is DecodingError {
      response = ControlResponse(error: "Baby could not read the request.")
    } catch {
      return
    }
    do {
      try writeMessage(client, ControlCoding.encoder().encode(response))
    } catch {
      return
    }
  }
}
