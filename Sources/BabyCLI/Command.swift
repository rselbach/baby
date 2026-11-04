import Foundation

let usage = """
  usage:
    baby run [--for DURATION] [--id ID] [--label LABEL] [--] COMMAND [ARG...]
        Run COMMAND, keeping the Mac awake until it exits.
    baby hold [--for DURATION] [--pid PID] [--id ID] [--label LABEL]
        Keep the Mac awake until released, DURATION passes, or PID exits.
        Holding an existing ID replaces that lease. Prints the lease ID.
    baby release ID
        Release a lease. Releasing a lease that already ended succeeds.
    baby status [--json]
        Show whether Baby is keeping the Mac awake, and for whom.

  DURATION combines whole or decimal numbers with d, h, m, or s, such as
  90s, 45m, or 1h30m. Baby opens if it isn't running.
  """

/// What the command line asks for.
enum Command: Equatable {
  case run(HoldOptions, command: [String])
  case hold(HoldOptions)
  case release(id: String)
  case status(json: Bool)
  case help
}

/// The options that shape a lease.
struct HoldOptions: Equatable {
  var seconds: Double?
  var pid: Int32?
  var id: String?
  var label: String?
}

/// A command line Baby can't act on.
struct UsageError: LocalizedError, Equatable {
  let message: String
  var errorDescription: String? { message }
}

extension Command {
  /// Parses the arguments that follow the program name.
  static func parse(_ arguments: [String]) throws(UsageError) -> Command {
    guard let name = arguments.first else { throw UsageError(message: "missing command") }
    let rest = Array(arguments.dropFirst())
    switch name {
    case "run":
      let (options, command) = try parseOptions(
        rest, allowed: ["--for", "--id", "--label"], takesCommand: true)
      guard !command.isEmpty else { throw UsageError(message: "run needs a command") }
      return .run(options, command: command)
    case "hold":
      let (options, _) = try parseOptions(
        rest, allowed: ["--for", "--pid", "--id", "--label"], takesCommand: false)
      return .hold(options)
    case "release":
      guard rest.count == 1, let id = rest.first, !id.hasPrefix("-") else {
        throw UsageError(message: "release needs exactly one lease ID")
      }
      return .release(id: id)
    case "status":
      switch rest {
      case []: return .status(json: false)
      case ["--json"]: return .status(json: true)
      default: throw UsageError(message: "status only accepts --json")
      }
    case "help", "-h", "--help":
      return .help
    default:
      throw UsageError(message: "unknown command \(name)")
    }
  }

  // parseOptions reads options until "--" or, when takesCommand, the first
  // positional argument, and returns the arguments after them.
  private static func parseOptions(
    _ arguments: [String], allowed: Set<String>, takesCommand: Bool
  ) throws(UsageError) -> (HoldOptions, [String]) {
    var options = HoldOptions()
    var index = arguments.startIndex
    while index < arguments.endIndex {
      let argument = arguments[index]
      index += 1
      if argument == "--" {
        guard takesCommand else { throw UsageError(message: "unexpected --") }
        return (options, Array(arguments[index...]))
      }
      guard argument.hasPrefix("-") else {
        guard takesCommand else {
          throw UsageError(message: "unexpected argument \(argument)")
        }
        return (options, Array(arguments[(index - 1)...]))
      }
      var name = argument
      var value: String?
      if let equals = argument.firstIndex(of: "=") {
        name = String(argument[..<equals])
        value = String(argument[argument.index(after: equals)...])
      }
      guard allowed.contains(name) else { throw UsageError(message: "unknown option \(name)") }
      if value == nil, index < arguments.endIndex {
        value = arguments[index]
        index += 1
      }
      guard let value else { throw UsageError(message: "\(name) needs a value") }
      switch name {
      case "--for":
        guard let seconds = parseDuration(value) else {
          throw UsageError(message: "invalid duration \(value); try 30m or 1h30m")
        }
        options.seconds = seconds
      case "--pid":
        guard let pid = Int32(value), pid > 0 else {
          throw UsageError(message: "invalid process ID \(value)")
        }
        options.pid = pid
      case "--id":
        options.id = value
      default:
        options.label = value
      }
    }
    return (options, [])
  }

  /// Parses durations such as "90s", "45m", "2h", or "1h30m" into seconds.
  /// Every number needs a unit.
  static func parseDuration(_ text: String) -> Double? {
    let units: [Character: Double] = ["d": 86400, "h": 3600, "m": 60, "s": 1]
    var total = 0.0
    var number = ""
    for character in text {
      if character.isASCII, character.isNumber || character == "." {
        number.append(character)
        continue
      }
      guard let value = Double(number), let unit = units[character] else { return nil }
      total += value * unit
      number = ""
    }
    guard number.isEmpty, total > 0, total.isFinite else { return nil }
    return total
  }
}
