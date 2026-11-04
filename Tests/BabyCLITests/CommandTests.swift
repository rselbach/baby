import Testing

@testable import BabyCLI

@Test func parsesCommands() throws {
  let cases: [String: ([String], Command)] = [
    "run": (["run", "make", "test"], .run(HoldOptions(), command: ["make", "test"])),
    "run with options": (
      ["run", "--for", "1h", "--label", "Greendale", "--id=build", "make", "-j8"],
      .run(HoldOptions(seconds: 3600, id: "build", label: "Greendale"), command: ["make", "-j8"])
    ),
    "run after --": (
      ["run", "--label", "tests", "--", "--weird-binary", "--flag"],
      .run(HoldOptions(label: "tests"), command: ["--weird-binary", "--flag"])
    ),
    "hold": (["hold"], .hold(HoldOptions())),
    "hold with options": (
      ["hold", "--for=30m", "--pid", "4821", "--id", "claude", "--label", "Claude Code"],
      .hold(HoldOptions(seconds: 1800, pid: 4821, id: "claude", label: "Claude Code"))
    ),
    "release": (["release", "claude"], .release(id: "claude")),
    "status": (["status"], .status(json: false)),
    "status json": (["status", "--json"], .status(json: true)),
    "help": (["help"], .help),
    "dash help": (["--help"], .help),
  ]
  for (name, tc) in cases {
    let (arguments, want) = tc
    #expect(try Command.parse(arguments) == want, "\(name)")
  }
}

@Test func rejectsBadCommandLines() {
  let cases: [String: ([String], String)] = [
    "nothing": ([], "missing command"),
    "unknown command": (["nap"], "unknown command nap"),
    "run without command": (["run", "--for", "5m"], "run needs a command"),
    "run with empty --": (["run", "--"], "run needs a command"),
    "run with pid": (["run", "--pid", "1", "make"], "unknown option --pid"),
    "hold positional": (["hold", "make"], "unexpected argument make"),
    "hold --": (["hold", "--"], "unexpected --"),
    "missing value": (["hold", "--for"], "--for needs a value"),
    "bad duration": (["hold", "--for", "30"], "invalid duration 30; try 30m or 1h30m"),
    "bad pid": (["hold", "--pid", "-3"], "invalid process ID -3"),
    "zero pid": (["hold", "--pid", "0"], "invalid process ID 0"),
    "release nothing": (["release"], "release needs exactly one lease ID"),
    "release two": (["release", "a", "b"], "release needs exactly one lease ID"),
    "release option": (["release", "--all"], "release needs exactly one lease ID"),
    "status option": (["status", "--yaml"], "status only accepts --json"),
  ]
  for (name, tc) in cases {
    let (arguments, want) = tc
    #expect(throws: UsageError(message: want), "\(name)") { try Command.parse(arguments) }
  }
}

@Test func parsesDurations() {
  let cases: [String: Double?] = [
    "90s": 90, "45m": 2700, "2h": 7200, "1d": 86400, "1h30m": 5400, "1.5h": 5400,
    "0.5s": 0.5, "30": nil, "": nil, "m": nil, "0m": nil, "5x": nil, "1.2.3m": nil,
    "-5m": nil, "5m30": nil, "٣m": nil,
  ]
  for (text, want) in cases {
    #expect(Command.parseDuration(text) == want, "\(text)")
  }
}
