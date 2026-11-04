import Foundation
import Testing

@testable import Baby

private let presetKey = "activationPresetMinutes"

@MainActor
private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
  let suite = "BabyTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  try body(defaults)
}

@MainActor
@Test func startsWithExistingPresets() throws {
  try withDefaults { defaults in
    #expect(ActivationPresets(defaults: defaults).minutes == [5, 10, 15, 30, 60, 120, 300])
  }
}

@MainActor
@Test func savesSortedUniquePresetsAndRemovals() throws {
  try withDefaults { defaults in
    let presets = ActivationPresets(defaults: defaults)
    presets.add(minutes: 90)
    presets.add(minutes: 1)
    presets.add(minutes: 90)
    presets.remove(minutes: 10)
    presets.remove(minutes: 999)
    let want = [1, 5, 15, 30, 60, 90, 120, 300]
    #expect(presets.minutes == want)
    #expect(ActivationPresets(defaults: defaults).minutes == want)
  }
}

@MainActor
@Test func preservesAnEmptyPresetList() throws {
  try withDefaults { defaults in
    let presets = ActivationPresets(defaults: defaults)
    for minutes in presets.minutes {
      presets.remove(minutes: minutes)
    }
    #expect(presets.minutes.isEmpty)
    #expect(ActivationPresets(defaults: defaults).minutes.isEmpty)
  }
}

@MainActor
@Test func filtersUnusableSavedPresets() throws {
  try withDefaults { defaults in
    defaults.set(
      [90, 5, 90, true, false, 0, -5, 1.5, "30", ActivationPresets.maximumMinutes,
        ActivationPresets.maximumMinutes + 1] as [Any],
      forKey: presetKey)
    #expect(
      ActivationPresets(defaults: defaults).minutes == [5, 90, ActivationPresets.maximumMinutes])
  }
}

@MainActor
@Test func keepsUnusableSavedPreferencesEmpty() throws {
  try withDefaults { defaults in
    defaults.set("invalid", forKey: presetKey)
    #expect(ActivationPresets(defaults: defaults).minutes.isEmpty)
    defaults.set([0, -1, true, "5"] as [Any], forKey: presetKey)
    #expect(ActivationPresets(defaults: defaults).minutes.isEmpty)
  }
}

@MainActor
@Test func rejectsInvalidDurationsWithoutLosingPresets() throws {
  try withDefaults { defaults in
    let presets = ActivationPresets(defaults: defaults)
    let want = presets.minutes
    for minutes in [0, -1, ActivationPresets.maximumMinutes + 1, Int.max] {
      presets.add(minutes: minutes)
      #expect(presets.minutes == want)
    }
    #expect(ActivationPresets(defaults: defaults).minutes == want)
  }
}

@MainActor
@Test func acceptsTheLongestSupportedDuration() throws {
  try withDefaults { defaults in
    let presets = ActivationPresets(defaults: defaults)
    presets.add(minutes: ActivationPresets.maximumMinutes)
    #expect(presets.minutes.last == ActivationPresets.maximumMinutes)
    #expect(
      ActivationPresets(defaults: defaults).minutes.last == ActivationPresets.maximumMinutes)
  }
}

@MainActor
@Test func formatsPresetDurations() {
  let cases = [
    1: "1 minute", 5: "5 minutes", 60: "1 hour", 120: "2 hours",
    61: "1 hour 1 minute", 90: "1 hour 30 minutes", 121: "2 hours 1 minute",
  ]
  for (minutes, want) in cases {
    #expect(ActivationPresets.title(for: minutes) == want)
  }
}
