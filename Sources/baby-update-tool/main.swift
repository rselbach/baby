// Release-side companion to Baby's updater: signs the update feed and checks
// feeds and app bundles with the same code the app uses.
import BabyUpdate
import CryptoKit
import Foundation

let usage = """
  usage:
    baby-update-tool sign-feed --version V --build N --minimum-os M
        --notes-url URL --zip PATH --zip-url URL --out FILE
        [--published-at RFC3339]   (base64 Ed25519 seed on stdin)
    baby-update-tool verify-feed FILE [--version V] [--build N] [--download]
    baby-update-tool verify-app APP --version V --build N [--ad-hoc]
  """

struct ToolError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

// Arguments splits positional arguments from --flag value pairs; flags
// listed in switches take no value.
struct Arguments {
  var positional: [String] = []
  var options: [String: String] = [:]
  var switches: Set<String> = []

  init(_ args: some Sequence<String>, switches known: Set<String>) throws {
    var iterator = args.makeIterator()
    while let arg = iterator.next() {
      guard arg.hasPrefix("--") else {
        positional.append(arg)
        continue
      }
      let name = String(arg.dropFirst(2))
      if known.contains(name) {
        switches.insert(name)
        continue
      }
      guard let value = iterator.next() else {
        throw ToolError(message: "\(arg) needs a value")
      }
      options[name] = value
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

func readSigningKey() throws -> Curve25519.Signing.PrivateKey {
  let input = FileHandle.standardInput.readDataToEndOfFile()
  let text = String(decoding: input, as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard let seed = Data(base64Encoded: text), seed.count == 32 else {
    throw ToolError(message: "stdin must hold a base64 32-byte Ed25519 seed")
  }
  let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
  guard key.publicKey.rawRepresentation.base64EncodedString() == UpdateConfig.publicKey
  else { throw ToolError(message: "the signing key does not match Baby's public key") }
  return key
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
  let key = try readSigningKey()
  let zip = URL(filePath: try args.require("zip"))
  let (size, digest) = try sha256Hex(of: zip)
  let publishedAt =
    args.options["published-at"] ?? ISO8601DateFormatter().string(from: Date())
  let release = Release(
    version: try args.require("version"),
    build: try args.requireBuild(),
    publishedAt: publishedAt,
    notesURL: try args.require("notes-url"),
    artifacts: [
      Artifact(
        arch: "arm64", minimumOS: try args.require("minimum-os"),
        url: try args.require("zip-url"), size: size, sha256: digest)
    ])
  try release.validate()
  let feed = try Feed.seal(release, privateKey: key)
  // round trip through the app's own verifier before anything is published
  guard try Feed.open(feed) == release else {
    throw ToolError(message: "the sealed feed does not round trip")
  }
  try feed.write(to: URL(filePath: try args.require("out")), options: .atomic)
  print("signed \(release.version) (\(release.build)), \(size) bytes, sha256 \(digest)")
}

func verifyFeed(_ args: Arguments) async throws {
  guard let path = args.positional.first else { throw ToolError(message: usage) }
  let release = try Feed.open(try Data(contentsOf: URL(filePath: path)))
  if let version = args.options["version"], version != release.version {
    throw ToolError(message: "feed version is \(release.version), not \(version)")
  }
  if args.options["build"] != nil, try args.requireBuild() != release.build {
    throw ToolError(message: "feed build is \(release.build)")
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
  guard let path = args.positional.first else { throw ToolError(message: usage) }
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
  let command = CommandLine.arguments.dropFirst().first
  let args = try Arguments(
    CommandLine.arguments.dropFirst(2), switches: ["download", "ad-hoc"])
  switch command {
  case "sign-feed": try signFeed(args)
  case "verify-feed": try await verifyFeed(args)
  case "verify-app": try await verifyApp(args)
  default: throw ToolError(message: usage)
  }
} catch {
  FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
  exit(1)
}
