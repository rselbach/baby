import Foundation

/// A request to keep the Mac awake. It lasts until it is released, its
/// deadline passes, or its process exits, whichever comes first.
public struct Lease: Codable, Equatable, Sendable {
  /// The ID that releases or replaces the lease.
  public var id: String
  /// A human-readable name for the menu, such as "Claude Code".
  public var label: String
  /// When the lease ends on its own, or nil to hold it until released.
  public var deadline: Date?
  /// The process whose exit ends the lease, or nil.
  public var pid: Int32?

  /// Creates a lease.
  public init(id: String, label: String, deadline: Date? = nil, pid: Int32? = nil) {
    self.id = id
    self.label = label
    self.deadline = deadline
    self.pid = pid
  }
}
