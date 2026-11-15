import BabyControl
import Darwin
import Foundation

struct CLIError: LocalizedError, Equatable {
  let message: String
  var errorDescription: String? { message }
}

/// How the tool reaches Baby. Tests replace the pieces.
struct BabyConnection {
  /// Sends one request to a running Baby.
  var send: (ControlRequest) throws -> ControlResponse = { try ControlClient.send($0) }
  /// Opens Baby when it isn't running.
  var open: () throws -> Void = openBaby
  /// Waits between attempts to reach a Baby that is starting.
  var pause: () -> Void = { _ = usleep(100_000) }
  /// How many times to try a Baby that is starting before giving up.
  var attempts = 100
}

// send sends request to Baby, opening it first when launch is set and Baby
// isn't running.
func send(
  _ request: ControlRequest, launch: Bool, via connection: BabyConnection = BabyConnection()
) throws -> ControlResponse {
  let response: ControlResponse
  do {
    response = try connection.send(request)
  } catch ControlError.notRunning where launch {
    try connection.open()
    response = try waitForBaby(request, via: connection)
  }
  if let error = response.error { throw CLIError(message: error) }
  return response
}

func waitForBaby(_ request: ControlRequest, via connection: BabyConnection) throws
  -> ControlResponse
{
  for _ in 0..<connection.attempts {
    do {
      return try connection.send(request)
    } catch ControlError.notRunning {
      connection.pause()
    }
  }
  throw CLIError(message: "Baby did not start")
}

// openBaby opens the Baby.app this tool ships in, or the installed Baby,
// without activating it or its activate-on-launch setting.
func openBaby() throws {
  let process = Process()
  process.executableURL = URL(filePath: "/usr/bin/open")
  process.arguments = openArguments(app: containingApp(of: Bundle.main.executablePath))
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else { throw CLIError(message: "could not open Baby") }
}

// openArguments are the arguments to open(1) that start app, or the
// installed Baby when app is nil, in the background and asleep.
func openArguments(app: URL?) -> [String] {
  var arguments = ["-g"]
  if let app {
    arguments.append(app.path)
  } else {
    arguments += ["-b", "com.rselbach.baby"]
  }
  return arguments + ["--args", "--asleep"]
}

// containingApp returns the app when executable is X.app/Contents/Helpers/baby,
// following the link Install puts in ~/.local/bin.
func containingApp(of executable: String?) -> URL? {
  guard let executable else { return nil }
  let helpers = URL(filePath: executable).resolvingSymlinksInPath().deletingLastPathComponent()
  let contents = helpers.deletingLastPathComponent()
  let app = contents.deletingLastPathComponent()
  guard helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents",
    app.pathExtension == "app"
  else { return nil }
  return app
}
