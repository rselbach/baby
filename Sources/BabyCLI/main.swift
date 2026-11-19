// Command line client for Baby: keeps the Mac awake for agents and scripts by
// holding leases over Baby's control socket.
import BabyControl
import Darwin
import Foundation

func fail(_ message: String, status: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data("baby: \(message)\n".utf8))
  exit(status)
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
    print(formatStatus(leases))
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
