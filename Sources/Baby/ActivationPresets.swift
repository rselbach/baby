import CoreFoundation
import Foundation
import Observation

/// Saved durations offered for temporary activation.
@MainActor
@Observable
final class ActivationPresets {
  static let maximumMinutes = Int(UInt32.max) / 60
  private static let storageKey = "activationPresetMinutes"
  private let defaults: UserDefaults
  private(set) var minutes: [Int] {
    didSet { defaults.set(minutes, forKey: Self.storageKey) }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    guard let stored = defaults.object(forKey: Self.storageKey) else {
      minutes = [5, 10, 15, 30, 60, 120, 300]
      return
    }
    let values = (stored as? [Any] ?? []).compactMap { value -> Int? in
      guard let number = value as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID(),
        let minutes = Int(exactly: number.doubleValue),
        (1...Self.maximumMinutes).contains(minutes)
      else {
        return nil
      }
      return minutes
    }
    minutes = Array(Set(values)).sorted()
  }

  func add(minutes: Int) {
    guard (1...Self.maximumMinutes).contains(minutes),
      !self.minutes.contains(minutes)
    else {
      return
    }
    self.minutes = (self.minutes + [minutes]).sorted()
  }

  func remove(minutes: Int) {
    guard self.minutes.contains(minutes) else { return }
    self.minutes.removeAll { $0 == minutes }
  }

  static func title(for minutes: Int) -> String {
    let hours = minutes / 60
    let remainder = minutes % 60
    var parts: [String] = []
    if hours > 0 {
      parts.append("\(hours) \(hours == 1 ? "hour" : "hours")")
    }
    if remainder > 0 {
      parts.append("\(remainder) \(remainder == 1 ? "minute" : "minutes")")
    }
    return parts.joined(separator: " ")
  }
}
