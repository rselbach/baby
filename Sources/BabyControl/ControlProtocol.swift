import Foundation

/// A command sent to Baby over its control socket, encoded as one line of
/// JSON.
public struct ControlRequest: Codable, Equatable, Sendable {
  /// What the request asks Baby to do.
  public enum Command: String, Codable, Sendable {
    /// Adds a lease, replacing any lease with the same ID.
    case hold
    /// Ends the lease with the request's ID, if there is one.
    case release
    /// Lists the active leases.
    case status
  }

  /// What to do.
  public var command: Command
  /// The lease to hold or release. Baby picks one for a hold without it.
  public var id: String?
  /// The name Baby shows for a held lease.
  public var label: String?
  /// How long a held lease lasts, or nil to hold it until released.
  public var seconds: Double?
  /// The process whose exit ends a held lease.
  public var pid: Int32?

  /// Creates a request.
  public init(
    command: Command, id: String? = nil, label: String? = nil, seconds: Double? = nil,
    pid: Int32? = nil
  ) {
    self.command = command
    self.id = id
    self.label = label
    self.seconds = seconds
    self.pid = pid
  }
}

/// Baby's reply to a ``ControlRequest``, encoded as one line of JSON.
public struct ControlResponse: Codable, Equatable, Sendable {
  /// Why the request failed, or nil if it succeeded.
  public var error: String?
  /// The lease a hold created or replaced.
  public var lease: Lease?
  /// Every active lease, in the order they were first held.
  public var leases: [Lease]?

  /// Creates a response.
  public init(error: String? = nil, lease: Lease? = nil, leases: [Lease]? = nil) {
    self.error = error
    self.lease = lease
    self.leases = leases
  }
}

/// The JSON settings both ends of the control socket use.
public enum ControlCoding {
  /// Returns an encoder that writes dates as ISO 8601 and sorts keys.
  public static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  /// Returns a decoder that reads ISO 8601 dates.
  public static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

/// Where Baby listens for control requests.
public enum ControlSocket {
  /// The socket a running Baby listens on.
  public static var defaultURL: URL {
    URL.applicationSupportDirectory.appending(components: "Baby", "control.sock")
  }
}
