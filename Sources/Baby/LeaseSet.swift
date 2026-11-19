import BabyControl
import Darwin
import Foundation

/// The leases keeping the Mac awake. Baby prevents sleep while any is held.
struct LeaseSet {
  /// The ID of the lease the menu bar item holds for the user.
  static let userID = "user"
  /// Reserves one slot for the user and bounds status and relaunch messages.
  static let maximumAgentLeases = 63
  /// Active leases, in the order they were first held.
  private(set) var leases: [Lease] = []

  init() {}

  /// Restores the leases an earlier Baby passed along. Throws only when
  /// `data` isn't a list of leases at all; a lease that can't be held is
  /// skipped, and why goes in `rejected`, so one bad lease doesn't drop the rest.
  init(restoring data: Data, rejected: inout [String]) throws {
    for lease in try ControlCoding.decoder().decode([Lease].self, from: data) {
      do {
        try hold(lease)
      } catch {
        rejected.append("\(lease.id): \(error.message)")
      }
    }
  }

  init(restoring data: Data) throws {
    var rejected: [String] = []
    try self.init(restoring: data, rejected: &rejected)
  }

  var isEmpty: Bool { leases.isEmpty }

  /// The earliest deadline among the leases.
  var nextDeadline: Date? { leases.compactMap(\.deadline).min() }

  /// What the leases need macOS to prevent. Any lease keeps the system
  /// awake; only the user's own keeps the display on, so an agent's
  /// overnight job doesn't light the screen.
  var powerAssertions: Set<PowerAssertion> {
    guard !leases.isEmpty else { return [] }
    guard holdsUserLease else { return [.idleSystemSleep, .systemSleep] }
    return Set(PowerAssertion.allCases)
  }

  /// What the menu bar item shows.
  enum Indicator: Equatable {
    case asleep
    case awakeForUser
    /// Awake only for leases the user didn't start.
    case awakeForOthers
  }

  var indicator: Indicator {
    if holdsUserLease { return .awakeForUser }
    return leases.isEmpty ? .asleep : .awakeForOthers
  }

  /// Whether the user's own lease is held, whatever agents hold.
  var holdsUserLease: Bool { leases.contains { $0.id == Self.userID } }

  /// Adds `lease`, replacing a lease with the same ID in place.
  mutating func hold(_ lease: Lease) throws(LeaseRequestError) {
    try lease.validate()
    guard let index = leases.firstIndex(where: { $0.id == lease.id }) else {
      guard
        lease.id == Self.userID
          || leases.count - (holdsUserLease ? 1 : 0) < Self.maximumAgentLeases
      else {
        throw LeaseRequestError(
          message: "Baby can hold at most \(Self.maximumAgentLeases) agent leases at a time.")
      }
      leases.append(lease)
      return
    }
    leases[index] = lease
  }

  /// Builds and adds the lease `request` asks to hold, ensuring an
  /// auto-generated ID does not collide with an existing lease or `userID`.
  @discardableResult
  mutating func hold(
    _ request: ControlRequest,
    now: Date,
    isRunning: (Int32) -> Bool,
    generateID: () -> String = Lease.randomID
  ) throws(LeaseRequestError) -> Lease {
    let lease = try Lease(
      holding: request,
      now: now,
      isRunning: isRunning,
      existingIDs: Set(leases.map(\.id)),
      generateID: generateID)
    try hold(lease)
    return lease
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
  private static let maximumIDAttempts = 1000
  private static let idCharacters = Set(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

  /// Generates a short random lease ID.
  static func randomID() -> String {
    UUID().uuidString.prefix(8).lowercased()
  }

  /// Builds the lease `request` asks to hold. A request without an ID gets
  /// a random one that avoids `existingIDs` and `LeaseSet.userID`, and one
  /// without a label is labeled with its ID.
  init(
    holding request: ControlRequest,
    now: Date,
    isRunning: (Int32) -> Bool,
    existingIDs: Set<String> = [],
    generateID: () -> String = Self.randomID
  ) throws(LeaseRequestError) {
    let id: String
    if let explicitID = request.id {
      guard explicitID != LeaseSet.userID else {
        throw LeaseRequestError(message: "The lease ID \"user\" is reserved for Baby's menu.")
      }
      id = explicitID
    } else {
      id = try Self.uniqueID(avoiding: existingIDs, generate: generateID)
    }
    var deadline: Date?
    if let seconds = request.seconds {
      guard seconds > 0, seconds <= Self.maximumSeconds else {
        throw LeaseRequestError(
          message:
            "A lease's duration must be positive and at most \(Int(Self.maximumSeconds)) seconds.")
      }
      deadline = now.addingTimeInterval(seconds)
    }
    if let pid = request.pid {
      guard pid > 0, isRunning(pid) else {
        throw LeaseRequestError(message: "Process \(pid) is not running.")
      }
    }
    let label = Self.truncatedLabel(request.label ?? "")
    self.init(id: id, label: label.isEmpty ? id : label, deadline: deadline, pid: request.pid)
    try validate()
  }

  /// Trims `text` and keeps as many whole characters as fit in a label: 64
  /// characters and 256 UTF-8 bytes. A first character too large on its own
  /// leaves the label empty.
  static func truncatedLabel(_ text: String) -> String {
    var label = ""
    var characters = 0
    var bytes = 0
    for character in text.trimmingCharacters(in: .whitespacesAndNewlines) {
      let size = character.utf8.count
      guard characters < 64, bytes + size <= 256 else { break }
      label.append(character)
      characters += 1
      bytes += size
    }
    return label
  }

  private static func uniqueID(
    avoiding existingIDs: Set<String>,
    generate: () -> String
  ) throws(LeaseRequestError) -> String {
    for _ in 0..<maximumIDAttempts {
      let candidate = generate()
      if candidate != LeaseSet.userID, !existingIDs.contains(candidate) {
        return candidate
      }
    }
    throw LeaseRequestError(message: "Could not generate a unique lease ID.")
  }

  fileprivate func validate() throws(LeaseRequestError) {
    guard (1...64).contains(id.count), id.allSatisfy(Self.idCharacters.contains) else {
      throw LeaseRequestError(
        message: "Lease IDs are 1 to 64 letters, digits, dots, dashes, or underscores.")
    }
    guard label.count <= 64, label.utf8.count <= 256 else {
      throw LeaseRequestError(
        message: "Lease labels must fit in 64 characters and 256 UTF-8 bytes.")
    }
    if let pid, pid <= 0 {
      throw LeaseRequestError(message: "Process \(pid) is not running.")
    }
    if let deadline, !deadline.timeIntervalSince1970.isFinite {
      throw LeaseRequestError(message: "The lease deadline must be finite.")
    }
  }
}

/// Reports whether a process with `pid` exists, including one owned by
/// another user.
func processIsRunning(_ pid: Int32) -> Bool {
  kill(pid, 0) == 0 || errno == EPERM
}
