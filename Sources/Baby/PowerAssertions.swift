import Foundation
import IOKit.pwr_mgt

/// A kind of sleep Baby can ask macOS to prevent.
enum PowerAssertion: CaseIterable {
  /// The system sleeping because the user is idle.
  case idleSystemSleep
  /// The system sleeping at all; macOS honors it only on AC power.
  case systemSleep
  /// The display sleeping because the user is idle.
  case displaySleep

  /// The IOKit assertion type.
  var type: String {
    switch self {
    case .idleSystemSleep: "PreventUserIdleSystemSleep"
    case .systemSleep: "PreventSystemSleep"
    case .displaySleep: "PreventUserIdleDisplaySleep"
    }
  }
}

/// Why macOS refused a power assertion.
struct PowerAssertionError: LocalizedError, Equatable {
  let assertion: PowerAssertion
  let code: IOReturn
  var errorDescription: String? {
    "macOS refused to prevent sleep (\(assertion.type), error \(code))."
  }
}

/// Holds the power assertions that keep the Mac awake. macOS releases them
/// when Baby exits, so a crash never leaves the Mac stuck awake.
@MainActor
final class PowerAssertionHolder {
  private let name: String
  private var held: [PowerAssertion: IOPMAssertionID] = [:]

  /// `name` is what `pmset -g assertions` shows for each assertion.
  init(name: String) {
    self.name = name
  }

  /// Holds exactly `wanted`, creating and releasing assertions as needed.
  func hold(_ wanted: Set<PowerAssertion>) throws(PowerAssertionError) {
    for (assertion, id) in held where !wanted.contains(assertion) {
      IOPMAssertionRelease(id)
      held[assertion] = nil
    }
    for assertion in wanted where held[assertion] == nil {
      var id = IOPMAssertionID(0)
      let code = IOPMAssertionCreateWithName(
        assertion.type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
        name as CFString, &id)
      guard code == kIOReturnSuccess else {
        throw PowerAssertionError(assertion: assertion, code: code)
      }
      held[assertion] = id
    }
  }
}
