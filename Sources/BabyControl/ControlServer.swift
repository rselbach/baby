import Darwin
import Foundation

/// Listens on Baby's control socket and answers each request on the main
/// actor. Only processes running as the same user can connect.
public final class ControlServer: Sendable {
  private let path: String
  private let inode: ino_t
  private let source: any DispatchSourceRead

  /// Starts listening at `url`, replacing any socket an earlier Baby left
  /// there. `handler` runs on the main actor once per request.
  public init(
    url: URL, handler: @escaping @MainActor @Sendable (ControlRequest) -> ControlResponse
  ) throws {
    path = url.path
    let directory = url.deletingLastPathComponent().path
    try FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true)
    guard chmod(directory, 0o700) == 0 else { throw ControlError.system("chmod", errno) }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ControlError.system("socket", errno) }
    do {
      inode = try Self.listen(fd, at: path)
    } catch {
      close(fd)
      throw error
    }
    source = DispatchSource.makeReadSource(
      fileDescriptor: fd, queue: DispatchQueue(label: "com.rselbach.baby.control"))
    source.setEventHandler { Self.accept(on: fd, handler: handler) }
    source.setCancelHandler { close(fd) }
    source.resume()
  }

  /// Stops listening and removes the socket, unless a newer Baby has
  /// already replaced it.
  public func stop() {
    source.cancel()
    var info = stat()
    if stat(path, &info) == 0, info.st_ino == inode {
      unlink(path)
    }
  }

  // listen binds fd to path and returns the socket file's inode.
  private static func listen(_ fd: Int32, at path: String) throws -> ino_t {
    guard unlink(path) == 0 || errno == ENOENT else {
      throw ControlError.system("unlink", errno)
    }
    let failure = try withAddress(path) { bind(fd, $0, $1) == 0 ? 0 : errno }
    guard failure == 0 else { throw ControlError.system("bind", failure) }
    guard chmod(path, 0o600) == 0 else { throw ControlError.system("chmod", errno) }
    // nonblocking so a client that gives up before accept can't stall the queue
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw ControlError.system("fcntl", errno)
    }
    guard Darwin.listen(fd, 16) == 0 else { throw ControlError.system("listen", errno) }
    var info = stat()
    guard stat(path, &info) == 0 else { throw ControlError.system("stat", errno) }
    return info.st_ino
  }

  private static func accept(
    on fd: Int32, handler: @escaping @MainActor @Sendable (ControlRequest) -> ControlResponse
  ) {
    let client = Darwin.accept(fd, nil, nil)
    guard client >= 0 else { return }
    DispatchQueue.global().async { serve(client, handler: handler) }
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
