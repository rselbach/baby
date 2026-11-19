import BabyControl
import Foundation

struct Status: Encodable {
  let running: Bool
  let awake: Bool
  let leases: [Lease]
}

// formatStatus formats the active leases for terminal output.
func formatStatus(_ leases: [Lease]) -> String {
  guard !leases.isEmpty else {
    return "Baby is not keeping your Mac awake."
  }
  var lines = ["Baby is keeping your Mac awake for:"]
  let idWidth = leases.map(\.id.count).max() ?? 0
  let labelWidth = leases.map(\.label.count).max() ?? 0
  for lease in leases {
    var details: [String] = []
    if let deadline = lease.deadline {
      let date: Date.FormatStyle.DateStyle =
        Calendar.current.isDateInToday(deadline) ? .omitted : .abbreviated
      details.append("until \(deadline.formatted(date: date, time: .shortened))")
    }
    if let pid = lease.pid {
      details.append("while process \(pid) runs")
    }
    if details.isEmpty {
      details.append("until released")
    }
    let id = pad(lease.id, to: idWidth)
    let label = pad(lease.label, to: labelWidth)
    lines.append("  \(id)  \(label)  \(details.joined(separator: ", "))")
  }
  return lines.joined(separator: "\n")
}

// pad appends spaces so text is at least width Swift Characters wide.
// Avoids String.padding(toLength:...), which counts UTF-16 code units and
// truncates or splits emoji and combining sequences.
func pad(_ text: String, to width: Int) -> String {
  text + String(repeating: " ", count: max(0, width - text.count))
}
