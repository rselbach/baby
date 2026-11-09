import Darwin
import Foundation
import Testing

@testable import BabyControl

@Test(arguments: [maximumMessageSize - 1, maximumMessageSize, maximumMessageSize + 1])
func enforcesMessageSizeIncludingTheFinalChunk(size: Int) throws {
  var sockets: [Int32] = [-1, -1]
  try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
  defer {
    close(sockets[0])
    close(sockets[1])
  }
  try configure(sockets[0], timeout: 5)
  try configure(sockets[1], timeout: 5)
  var capacity = Int32(maximumMessageSize * 2)
  try #require(
    setsockopt(
      sockets[0], SOL_SOCKET, SO_SNDBUF, &capacity,
      socklen_t(MemoryLayout<Int32>.size)) == 0)
  let message = Data(repeating: 0x61, count: size)
  try writeMessage(sockets[0], message)
  if size > maximumMessageSize {
    #expect(throws: ControlError.badMessage) { try readMessage(sockets[1]) }
  } else {
    #expect(try readMessage(sockets[1]) == message)
  }
}
