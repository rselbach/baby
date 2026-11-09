import Foundation
import IOKit.pwr_mgt
import Testing

@testable import Baby

// the assertion types macOS reports this process holding under name
private func heldTypes(named name: String) -> Set<String> {
  var copied: Unmanaged<CFDictionary>?
  guard IOPMCopyAssertionsByProcess(&copied) == kIOReturnSuccess,
    let all = copied?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
  else { return [] }
  let mine = all[NSNumber(value: getpid())] ?? []
  return Set(
    mine.filter { $0["AssertName"] as? String == name }.compactMap { $0["AssertType"] as? String })
}

@MainActor
@Test func holdsExactlyTheWantedAssertions() throws {
  let name = "baby-tests-\(UUID().uuidString)"
  let holder = PowerAssertionHolder(name: name)
  try holder.hold([.idleSystemSleep, .systemSleep])
  #expect(heldTypes(named: name) == ["PreventUserIdleSystemSleep", "PreventSystemSleep"])
  try holder.hold(Set(PowerAssertion.allCases))
  try holder.hold(Set(PowerAssertion.allCases))
  #expect(
    heldTypes(named: name) == [
      "PreventUserIdleSystemSleep", "PreventSystemSleep", "PreventUserIdleDisplaySleep",
    ])
  try holder.hold([.idleSystemSleep, .systemSleep])
  #expect(heldTypes(named: name) == ["PreventUserIdleSystemSleep", "PreventSystemSleep"])
  try holder.hold([])
  #expect(heldTypes(named: name).isEmpty)
}
