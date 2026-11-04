// Command line client for Baby: keeps the Mac awake for agents and scripts by
// holding leases over Baby's control socket.
import BabyControl
import Darwin
import Foundation

struct CLIError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

func fail(_ message: String, status: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data("baby: \(message)\n".utf8))
  exit(status)
}

// send sends request to Baby, opening it first when launch is set and Baby
// isn't running.
func send(_ request: ControlRequest, launch: Bool) throws -> ControlResponse {
  let response: ControlResponse
  do {
    response = try ControlClient.send(request)
  } catch ControlError.notRunning where launch {
    try openBaby()
    response = try waitForBaby(request)
  }
  if let error = response.error { throw CLIError(message: error) }
  return response
}

// openBaby opens the Baby.app this tool ships in, or the installed Baby,
// without activating it or its activate-on-launch setting.
func openBaby() throws {
  let process = Process()
  process.executableURL = URL(filePath: "/usr/bin/open")
  var arguments = ["-g"]
  if let app = containingApp() {
    arguments.append(app.path)
  } else {
    arguments += ["-b", "com.rselbach.baby"]
  }
  process.arguments = arguments + ["--args", "--asleep"]
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else { throw CLIError(message: "could not open Baby") }
}

// containingApp returns the app when this tool runs from X.app/Contents/Helpers.
func containingApp() -> URL? {
  guard let path = Bundle.main.executablePath else { return nil }
  let helpers = URL(filePath: path).resolvingSymlinksInPath().deletingLastPathComponent()
  let app = helpers.deletingLastPathComponent().deletingLastPathComponent()
  guard helpers.lastPathComponent == "Helpers", app.pathExtension == "app" else { return nil }
  return app
}

func waitForBaby(_ request: ControlRequest) throws -> ControlResponse {
  for _ in 0..<100 {
    do {
      return try ControlClient.send(request)
    } catch ControlError.notRunning {
      usleep(100_000)
    }
  }
  throw CLIError(message: "Baby did not start")
}

// processName returns the executable name of pid, if it can be read.
func processName(_ pid: Int32) -> String? {
  var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
  guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
    let path = String(utf8String: buffer)
  else {
    return nil
  }
  return URL(filePath: path).lastPathComponent
}

func holdRequest(_ options: HoldOptions, pid: Int32?, label: String?) -> ControlRequest {
  ControlRequest(
    command: .hold, id: options.id, label: options.label ?? label, seconds: options.seconds,
    pid: pid)
}

// run holds a lease on this process and then becomes command, so the lease
// ends exactly when command exits.
func run(_ options: HoldOptions, command: [String]) -> Never {
  let label = URL(filePath: command[0]).lastPathComponent
  do {
    _ = try send(holdRequest(options, pid: getpid(), label: label), launch: true)
  } catch {
    FileHandle.standardError.write(
      Data("baby: warning: not keeping the Mac awake: \(error.localizedDescription)\n".utf8))
  }
  var argv = command.map { strdup($0) } + [nil]
  execvp(command[0], &argv)
  let code = errno
  fail("\(command[0]): \(String(cString: strerror(code)))", status: code == ENOENT ? 127 : 126)
}

struct Status: Encodable {
  let running: Bool
  let awake: Bool
  let leases: [Lease]
}

func printStatus(_ leases: [Lease]) {
  guard !leases.isEmpty else {
    print("Baby is not keeping your Mac awake.")
    return
  }
  print("Baby is keeping your Mac awake for:")
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
    let id = lease.id.padding(toLength: idWidth, withPad: " ", startingAt: 0)
    let label = lease.label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
    print("  \(id)  \(label)  \(details.joined(separator: ", "))")
  }
}

func status(json: Bool) throws {
  var leases: [Lease]?
  do {
    leases = try send(ControlRequest(command: .status), launch: false).leases ?? []
  } catch ControlError.notRunning {
    leases = nil
  }
  guard json else {
    guard let leases else {
      print("Baby is not running.")
      return
    }
    printStatus(leases)
    return
  }
  let status = Status(
    running: leases != nil, awake: leases?.isEmpty == false, leases: leases ?? [])
  print(String(decoding: try ControlCoding.encoder().encode(status), as: UTF8.self))
}

func main() {
  let command: Command
  do {
    command = try Command.parse(Array(CommandLine.arguments.dropFirst()))
  } catch {
    fail("\(error.message)\n\n\(usage)", status: 2)
  }
  do {
    switch command {
    case .help:
      print(usage)
    case .run(let options, let command):
      run(options, command: command)
    case .hold(let options):
      let label = options.pid.flatMap(processName)
      let response = try send(holdRequest(options, pid: options.pid, label: label), launch: true)
      print(response.lease?.id ?? "")
    case .release(let id):
      do {
        _ = try send(ControlRequest(command: .release, id: id), launch: false)
      } catch ControlError.notRunning {
        // nothing is held while Baby isn't running
      }
    case .status(let json):
      try status(json: json)
    }
  } catch {
    fail(error.localizedDescription)
  }
}

main()
