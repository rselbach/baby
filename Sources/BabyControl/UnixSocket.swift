import Darwin
import Foundation

/// Why talking over the control socket failed.
public enum ControlError: LocalizedError, Equatable, Sendable {
  /// Nothing is listening on the socket.
  case notRunning
  /// Another Baby already owns this control socket.
  case alreadyRunning
  /// The socket path does not fit in a socket address.
  case pathTooLong(String)
  /// The other end sent something that is not a control message.
  case badMessage
  /// A system call failed with an errno value.
  case system(String, Int32)

  public var errorDescription: String? {
    switch self {
    case .notRunning: "Baby is not running."
    case .alreadyRunning: "Baby is already running."
    case .pathTooLong(let path): "The control socket path is too long: \(path)"
    case .badMessage: "Baby sent a reply that could not be read."
    case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
    }
  }
}

// messages are single JSON lines; nothing legitimate comes close to this
let maximumMessageSize = 64 * 1024

// withAddress passes a sockaddr_un for path to body.
func withAddress<T>(
  _ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
) throws -> T {
  var address = sockaddr_un()
  let bytes = Array(path.utf8)
  // leave room for the terminating NUL
  guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
    throw ControlError.pathTooLong(path)
  }
  address.sun_family = sa_family_t(AF_UNIX)
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
  return try withUnsafePointer(to: address) {
    try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
}

// setCloseOnExec keeps a file descriptor from leaking into child processes.
func setCloseOnExec(_ fd: Int32) throws {
  let flags = fcntl(fd, F_GETFD)
  guard flags >= 0, fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0 else {
    throw ControlError.system("fcntl", errno)
  }
}

// makeSocket opens a UNIX stream socket with FD_CLOEXEC set.
func makeSocket() throws -> Int32 {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { throw ControlError.system("socket", errno) }
  do {
    try setCloseOnExec(fd)
  } catch {
    close(fd)
    throw error
  }
  return fd
}

// configure keeps a write to a closed peer from raising SIGPIPE and bounds
// how long reads and writes can block.
func configure(_ fd: Int32, timeout seconds: Int) throws {
  var on: Int32 = 1
  guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
  else {
    throw ControlError.system("setsockopt", errno)
  }
  var timeout = timeval(tv_sec: seconds, tv_usec: 0)
  let size = socklen_t(MemoryLayout<timeval>.size)
  for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
    guard setsockopt(fd, SOL_SOCKET, option, &timeout, size) == 0 else {
      throw ControlError.system("setsockopt", errno)
    }
  }
}

// readMessage reads up to the first newline, or to end of file.
func readMessage(_ fd: Int32) throws -> Data {
  var message = Data()
  var buffer = [UInt8](repeating: 0, count: 4096)
  while true {
    let count = read(fd, &buffer, buffer.count)
    if count < 0 {
      if errno == EINTR { continue }
      throw ControlError.system("read", errno)
    }
    if count == 0 { return message }
    let chunk = buffer[..<count]
    let newline = chunk.firstIndex(of: 0x0A)
    message.append(contentsOf: chunk[..<(newline ?? chunk.endIndex)])
    guard message.count <= maximumMessageSize else { throw ControlError.badMessage }
    if newline != nil { return message }
  }
}

// writeMessage writes data followed by a newline.
func writeMessage(_ fd: Int32, _ data: Data) throws {
  var line = data
  line.append(0x0A)
  try line.withUnsafeBytes { raw in
    guard let base = raw.baseAddress else { return }
    var offset = 0
    while offset < raw.count {
      let count = write(fd, base + offset, raw.count - offset)
      if count < 0 {
        if errno == EINTR { continue }
        throw ControlError.system("write", errno)
      }
      offset += count
    }
  }
}
