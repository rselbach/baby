// Release-side companion to Baby's updater: signs the update feed and checks
// feeds and app bundles with the same code the app uses.
import BabyUpdate
import CryptoKit
import Foundation

let usage = """
  usage:
    baby-update-tool sign-feed --version V --build N --minimum-os M
        --notes-url URL --zip PATH --zip-url URL --dmg PATH --dmg-url URL --out FILE
        [--after LIVE_FILE] [--published-at RFC3339]
    baby-update-tool refresh-feed LIVE_FILE --out FILE
    baby-update-tool verify-feed FILE [--version V] [--build N]
        [--after LIVE_FILE] [--download]
    baby-update-tool verify-app APP --version V --build N [--ad-hoc]
    baby-update-tool generate-key --seed-out FILE

  sign-feed and refresh-feed read base64 Ed25519 seeds on stdin, one per
  line: the legacy key older builds trust and every key this build trusts.
  generate-key writes a new seed to FILE and prints its public key.
  """

struct ToolError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

// Arguments splits positional arguments from --flag value pairs, rejecting
// unknown flags so typos cannot silently skip optional checks.
struct Arguments {
  var positional: [String] = []
  var options: [String: String] = [:]
  var switches: Set<String> = []

  init(
    _ args: some Sequence<String>, options knownOptions: Set<String>,
    switches knownSwitches: Set<String> = [], positionalCount: Int
  ) throws {
    var iterator = args.makeIterator()
    while let arg = iterator.next() {
      guard arg.hasPrefix("-") else {
        positional.append(arg)
        continue
      }
      guard arg.hasPrefix("--") else {
        throw ToolError(message: "unknown option \(arg)")
      }
      let name = String(arg.dropFirst(2))
      if knownSwitches.contains(name) {
        switches.insert(name)
        continue
      }
      guard knownOptions.contains(name) else {
        throw ToolError(message: "unknown option \(arg)")
      }
      guard let value = iterator.next() else {
        throw ToolError(message: "\(arg) needs a value")
      }
      options[name] = value
    }
    guard positional.count == positionalCount else {
      throw ToolError(message: usage)
    }
  }

  func require(_ name: String) throws -> String {
    guard let value = options[name] else { throw ToolError(message: "missing --\(name)") }
    return value
  }

  func requireBuild() throws -> Int {
    guard let build = Int(try require("build")), build > 0 else {
      throw ToolError(message: "--build must be a positive integer")
    }
    return build
  }
}

// readSigningKeys reads seeds from stdin and returns them legacy key first,
// so it signs the `signature` field older builds read. It refuses keys Baby
// doesn't know and insists on every key a feed needs.
func readSigningKeys() throws -> [Curve25519.Signing.PrivateKey] {
  let input = FileHandle.standardInput.readDataToEndOfFile()
  var keys: [String: Curve25519.Signing.PrivateKey] = [:]
  for line in String(decoding: input, as: UTF8.self).split(whereSeparator: \.isNewline) {
    let text = line.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { continue }
    guard let seed = Data(base64Encoded: text), seed.count == 32 else {
      throw ToolError(message: "stdin must hold base64 32-byte Ed25519 seeds, one per line")
    }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    let id = key.publicKey.rawRepresentation.base64EncodedString()
    guard id == UpdateConfig.legacyPublicKey || UpdateConfig.publicKeys.contains(id) else {
      throw ToolError(message: "the signing key \(id) is not one Baby trusts")
    }
    keys[id] = key
  }
  let needed = [UpdateConfig.legacyPublicKey] + UpdateConfig.publicKeys
  var ordered: [Curve25519.Signing.PrivateKey] = []
  for id in needed where !ordered.contains(where: {
    $0.publicKey.rawRepresentation.base64EncodedString() == id
  }) {
    guard let key = keys[id] else {
      throw ToolError(message: "missing the signing key for \(id)")
    }
    ordered.append(key)
  }
  return ordered
}

// liveKeys are the keys a live feed may be signed with: a feed signed
// before a key rotation carries only the legacy signature.
func liveKeys() throws -> [Curve25519.Signing.PublicKey] {
  try [Feed.legacyPublicKey()] + Feed.publicKeys()
}

// checkReadable confirms both older builds and this one accept feed.
func checkReadable(_ feed: Data) throws {
  _ = try Feed.open(feed, publicKeys: [try Feed.legacyPublicKey()])
  _ = try Feed.open(feed, publicKeys: try Feed.publicKeys())
}

func sha256Hex(of url: URL) throws -> (size: Int64, digest: String) {
  let handle = try FileHandle(forReadingFrom: url)
  defer { try? handle.close() }
  var hasher = SHA256()
  var size: Int64 = 0
  while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
    hasher.update(data: chunk)
    size += Int64(chunk.count)
  }
  return (size, hasher.finalize().map { String(format: "%02x", $0) }.joined())
}

func signFeed(_ args: Arguments) throws {
  let keys = try readSigningKeys()
  let artifacts = try [("zip", "app-zip"), ("dmg", "dmg")].map { option, kind in
    let file = URL(filePath: try args.require(option))
    let (size, digest) = try sha256Hex(of: file)
    var artifact = Artifact(
      arch: "arm64", minimumOS: try args.require("minimum-os"),
      url: try args.require("\(option)-url"), size: size, sha256: digest)
    artifact.kind = kind
    return artifact
  }
  let live = try args.options["after"].map { try Data(contentsOf: URL(filePath: $0)) }
  let (feed, release) = try Feed.publish(
    version: try args.require("version"),
    build: try args.requireBuild(),
    publishedAt: args.options["published-at"],
    notesURL: try args.require("notes-url"),
    artifacts: artifacts,
    privateKeys: keys,
    after: live,
    publicKeys: try liveKeys())
  try checkReadable(feed)
  try feed.write(to: URL(filePath: try args.require("out")), options: .atomic)
  print("signed \(release.version) (\(release.build)), \(artifacts.count) artifacts")
}

func refreshFeed(_ args: Arguments) throws {
  let keys = try readSigningKeys()
  let live = try Data(contentsOf: URL(filePath: args.positional[0]))
  let (feed, release) = try Feed.refresh(
    live, privateKeys: keys, publicKeys: try liveKeys())
  try checkReadable(feed)
  try feed.write(to: URL(filePath: try args.require("out")), options: .atomic)
  let expiry = release.expiresAt ?? "never"
  print(
    feed == live
      ? "feed still fresh: \(release.version) (\(release.build)) expires \(expiry)"
      : "refreshed \(release.version) (\(release.build)) to expire \(expiry)")
}

func generateKey(_ args: Arguments) throws {
  let path = try args.require("seed-out")
  let key = Curve25519.Signing.PrivateKey()
  // a new file only its owner can read, never one that already exists
  let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
  guard fd >= 0 else {
    throw ToolError(message: "could not create \(path): \(String(cString: strerror(errno)))")
  }
  let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  try handle.write(contentsOf: Data((key.rawRepresentation.base64EncodedString() + "\n").utf8))
  try handle.close()
  print(key.publicKey.rawRepresentation.base64EncodedString())
}

func verifyFeed(_ args: Arguments) async throws {
  let path = args.positional[0]
  let data = try Data(contentsOf: URL(filePath: path))
  try checkReadable(data)
  let release = try Feed.open(data)
  try release.checkFresh()
  if let version = args.options["version"], version != release.version {
    throw ToolError(message: "feed version is \(release.version), not \(version)")
  }
  if args.options["build"] != nil, try args.requireBuild() != release.build {
    throw ToolError(message: "feed build is \(release.build)")
  }
  if let livePath = args.options["after"] {
    let current = try Feed.open(
      try Data(contentsOf: URL(filePath: livePath)), publicKeys: try liveKeys())
    try release.verifySupersedes(current)
  }
  print("feed verified: \(release.version) (\(release.build))")
  guard args.switches.contains("download") else { return }
  let transport = Transport(userAgent: "baby-update-tool")
  let folder = FileManager.default.temporaryDirectory
    .appending(path: "baby-update-tool-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  for artifact in release.artifacts {
    try await transport.download(artifact, to: folder.appending(path: "artifact"))
    print("downloaded and verified \(artifact.url)")
  }
}

func verifyApp(_ args: Arguments) async throws {
  let path = args.positional[0]
  let release = Release(
    version: try args.require("version"), build: try args.requireBuild(),
    publishedAt: "", notesURL: nil, artifacts: [])
  // an ad hoc build can only be held to a valid signature, not to our team
  let requirement =
    args.switches.contains("ad-hoc")
    ? "identifier \"\(UpdateConfig.bundleIdentifier)\"" : UpdateConfig.codeRequirement
  try await BundleCheck.verify(
    app: URL(filePath: path), release: release, requirement: requirement)
  print("app verified: \(path)")
}

do {
  let rest = CommandLine.arguments.dropFirst(2)
  switch CommandLine.arguments.dropFirst().first {
  case "sign-feed":
    try signFeed(
      try Arguments(
        rest,
        options: [
          "version", "build", "minimum-os", "notes-url", "zip", "zip-url", "out",
          "dmg", "dmg-url", "published-at", "after",
        ],
        positionalCount: 0))
  case "refresh-feed":
    try refreshFeed(try Arguments(rest, options: ["out"], positionalCount: 1))
  case "generate-key":
    try generateKey(try Arguments(rest, options: ["seed-out"], positionalCount: 0))
  case "verify-feed":
    try await verifyFeed(
      try Arguments(
        rest, options: ["version", "build", "after"], switches: ["download"],
        positionalCount: 1))
  case "verify-app":
    try await verifyApp(
      try Arguments(
        rest, options: ["version", "build"], switches: ["ad-hoc"], positionalCount: 1))
  default:
    throw ToolError(message: usage)
  }
} catch {
  FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
  exit(1)
}
