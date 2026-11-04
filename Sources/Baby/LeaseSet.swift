import BabyControl
import Darwin
import Foundation

/// The leases keeping the Mac awake. Baby prevents sleep while any is held.
struct LeaseSet {
  /// The ID of the lease the menu bar item holds for the user.
  static let userID = "user"
  /// Active leases, in the order they were first held.
  private(set) var leases: [Lease] = []

  var isEmpty: Bool { leases.isEmpty }

  /// The earliest deadline among the leases.
  var nextDeadline: Date? { leases.compactMap(\.deadline).min() }

  /// Adds `lease`, replacing a lease with the same ID in place.
  mutating func hold(_ lease: Lease) {
    guard let index = leases.firstIndex(where: { $0.id == lease.id }) else {
      leases.append(lease)
      return
    }
    leases[index] = lease
  }

  /// Removes the leases matching `shouldRemove`.
  mutating func removeAll(where shouldRemove: (Lease) -> Bool) {
    leases.removeAll(where: shouldRemove)
  }

  /// Removes leases whose deadline has passed or whose process has exited.
  mutating func removeFinished(now: Date, isRunning: (Int32) -> Bool) {
    leases.removeAll { lease in
      if let deadline = lease.deadline, deadline <= now { return true }
      if let pid = lease.pid, !isRunning(pid) { return true }
      return false
    }
  }
}

/// Why Baby refused a hold request.
struct LeaseRequestError: LocalizedError, Equatable {
  let message: String
  var errorDescription: String? { message }
}

extension Lease {
  /// The longest duration a hold request can ask for, matching the menu's
  /// longest preset.
  static let maximumSeconds = Double(UInt32.max)
  private static let idCharacters = Set(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

  /// Builds the lease `request` asks to hold. A request without an ID gets
  /// a random one, and one without a label is labeled with its ID.
  init(holding request: ControlRequest, now: Date, isRunning: (Int32) -> Bool)
    throws(LeaseRequestError)
  {
    let id = request.id ?? UUID().uuidString.prefix(8).lowercased()
    guard (1...64).contains(id.count), id.allSatisfy(Self.idCharacters.contains) else {
      throw LeaseRequestError(
        message: "Lease IDs are 1 to 64 letters, digits, dots, dashes, or underscores.")
    }
    guard id != LeaseSet.userID else {
      throw LeaseRequestError(message: "The lease ID \"user\" is reserved for Baby's menu.")
    }
    var deadline: Date?
    if let seconds = request.seconds {
      guard seconds > 0, seconds <= Self.maximumSeconds else {
        throw LeaseRequestError(
          message: "A lease's duration must be positive and at most \(Int(Self.maximumSeconds)) seconds.")
      }
      deadline = now.addingTimeInterval(seconds)
    }
    if let pid = request.pid {
      guard pid > 0, isRunning(pid) else {
        throw LeaseRequestError(message: "Process \(pid) is not running.")
      }
    }
    let label = String(
      (request.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
    self.init(id: id, label: label.isEmpty ? id : label, deadline: deadline, pid: request.pid)
  }
}

/// Reports whether a process with `pid` exists, including one owned by
/// another user.
func processIsRunning(_ pid: Int32) -> Bool {
  kill(pid, 0) == 0 || errno == EPERM
}
