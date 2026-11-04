import Darwin
import Foundation

/// Sends requests to a running Baby.
public enum ControlClient {
  /// Sends `request` to the Baby listening at `url` and returns its reply.
  /// Throws ``ControlError/notRunning`` when nothing is listening.
  public static func send(
    _ request: ControlRequest, to url: URL = ControlSocket.defaultURL
  ) throws -> ControlResponse {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ControlError.system("socket", errno) }
    defer { close(fd) }
    try configure(fd, timeout: 10)
    let failure = try withAddress(url.path) { connect(fd, $0, $1) == 0 ? 0 : errno }
    switch failure {
    case 0:
      break
    case ENOENT, ECONNREFUSED:
      throw ControlError.notRunning
    default:
      throw ControlError.system("connect", failure)
    }
    try writeMessage(fd, ControlCoding.encoder().encode(request))
    let reply = try readMessage(fd)
    do {
      return try ControlCoding.decoder().decode(ControlResponse.self, from: reply)
    } catch {
      throw ControlError.badMessage
    }
  }
}
