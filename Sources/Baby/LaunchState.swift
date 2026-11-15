import BabyControl
import Foundation

/// What Baby holds when it launches, read from its arguments and settings.
/// Relaunch arguments preserve the live state across an update and override
/// the launch preference. Earlier Babys relaunch with --awake or
/// --awake-until=; newer ones pass every lease in --leases=.
enum LaunchState: Equatable {
  /// The leases an updating Baby passed along, as JSON. Data that doesn't
  /// decode restores nothing.
  case leases(Data)
  /// The user's own lease, until `until` or until released.
  case awake(until: Date?)
  /// Nothing.
  case asleep

  static let leasesPrefix = "--leases="
  static let deadlinePrefix = "--awake-until="

  init(arguments: [String], activateOnLaunch: Bool) {
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
