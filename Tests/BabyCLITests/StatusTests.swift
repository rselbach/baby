import BabyControl
import Foundation
import Testing

@testable import BabyCLI

@Test func formatsEmptyStatus() {
  #expect(formatStatus([]) == "Baby is not keeping your Mac awake.")
}

@Test func alignsASCIILeases() {
  let leases = [
    Lease(id: "a", label: "build", pid: 42),
    Lease(id: "claude", label: "Claude Code"),
  ]
  let want = [
    "Baby is keeping your Mac awake for:",
    "  a       build        while process 42 runs",
    "  claude  Claude Code  until released",
  ].joined(separator: "\n")
  #expect(formatStatus(leases) == want)
}

@Test func preservesSingleAndMultipleEmojiLabels() {
  let single = [Lease(id: "bot", label: "🤖")]
  let singleWant = [
    "Baby is keeping your Mac awake for:",
    "  bot  🤖  until released",
  ].joined(separator: "\n")
  let singleOutput = formatStatus(single)
  #expect(singleOutput == singleWant)
  #expect(!singleOutput.contains("\u{FFFD}"))

  let multiple = [Lease(id: "bots", label: "🤖🤖")]
  let multipleWant = [
    "Baby is keeping your Mac awake for:",
    "  bots  🤖🤖  until released",
  ].joined(separator: "\n")
  #expect(formatStatus(multiple) == multipleWant)
}

@Test func preservesZWJSequencesAndAlignsColumns() {
  let leases = [
    Lease(id: "a", label: "👨‍👩‍👧‍👦"),
    Lease(id: "dev", label: "👩‍💻", pid: 7),
    Lease(id: "job", label: "build"),
  ]
  let want = [
    "Baby is keeping your Mac awake for:",
    "  a    👨‍👩‍👧‍👦      until released",
    "  dev  👩‍💻      while process 7 runs",
    "  job  build  until released",
  ].joined(separator: "\n")
  let output = formatStatus(leases)
  #expect(output == want)
  #expect(output.unicodeScalars.elementsEqual(want.unicodeScalars))
}

@Test func preservesCombiningCharacterSequences() {
  let single = [Lease(id: "e\u{0301}", label: "e\u{0301}")]
  let singleWant = [
    "Baby is keeping your Mac awake for:",
    "  e\u{0301}  e\u{0301}  until released",
  ].joined(separator: "\n")
  let singleOutput = formatStatus(single)
  #expect(singleOutput == singleWant)
  #expect(singleOutput.unicodeScalars.elementsEqual(singleWant.unicodeScalars))

  let mixed = [
    Lease(id: "a", label: "cafe\u{0301}"),
    Lease(id: "long", label: "build"),
  ]
  let mixedWant = [
    "Baby is keeping your Mac awake for:",
    "  a     cafe\u{0301}   until released",
    "  long  build  until released",
  ].joined(separator: "\n")
  let mixedOutput = formatStatus(mixed)
  #expect(mixedOutput == mixedWant)
  #expect(mixedOutput.unicodeScalars.elementsEqual(mixedWant.unicodeScalars))
}

@Test func padsNonASCIIIDsWithoutTruncation() {
  let leases = [
    Lease(id: "🤖", label: "one"),
    Lease(id: "🤖🤖", label: "two"),
  ]
  let want = [
    "Baby is keeping your Mac awake for:",
    "  🤖   one  until released",
    "  🤖🤖  two  until released",
  ].joined(separator: "\n")
  let output = formatStatus(leases)
  #expect(output == want)
  #expect(!output.contains("\u{FFFD}"))
}

@Test func padsByCharacterCountWithoutTruncating() {
  #expect(pad("🤖", to: 1) == "🤖")
  #expect(pad("🤖🤖", to: 1) == "🤖🤖")
  #expect(pad("🤖", to: 3) == "🤖  ")
  #expect(pad("e\u{0301}", to: 2).unicodeScalars.elementsEqual("e\u{0301} ".unicodeScalars))
  #expect(pad("👨‍👩‍👧‍👦", to: 2) == "👨‍👩‍👧‍👦 ")
}
