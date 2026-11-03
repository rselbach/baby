import Foundation
import Security

/// Why a downloaded app bundle was rejected.
public enum BundleCheckError: LocalizedError, Equatable {
  case notABundle
  case mismatch(String)
  case requiresNewerOS(String)
  case signature(String)

  public var errorDescription: String? {
    switch self {
    case .notABundle: "The update does not contain Baby.app."
    case .mismatch(let key): "The update's \(key) does not match the feed."
    case .requiresNewerOS(let minimum): "The update requires macOS \(minimum)."
    case .signature(let reason): "The update's code signature is not valid: \(reason)"
    }
  }
}

/// Checks that an unpacked Baby.app is the release the feed promised.
public enum BundleCheck {
  /// Verifies the bundle's Info.plist against `release` and its code
  /// signature against `requirement` (Developer ID, our team, notarized).
  @concurrent
  public static func verify(
    app: URL, release: Release, os: OSVersion = .current,
    requirement: String = UpdateConfig.codeRequirement
  ) async throws {
    let values = try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values?.isDirectory == true, values?.isSymbolicLink == false else {
      throw BundleCheckError.notABundle
    }
    let plistURL = app.appending(components: "Contents", "Info.plist")
    guard let data = try? Data(contentsOf: plistURL),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { throw BundleCheckError.notABundle }

    func string(_ key: String) -> String? { plist[key] as? String }
    guard string("CFBundleIdentifier") == UpdateConfig.bundleIdentifier else {
      throw BundleCheckError.mismatch("bundle identifier")
    }
    guard string("CFBundleShortVersionString") == release.version else {
      throw BundleCheckError.mismatch("version")
    }
    guard string("CFBundleVersion") == String(release.build) else {
      throw BundleCheckError.mismatch("build")
    }
    guard let executable = string("CFBundleExecutable"), !executable.isEmpty,
      !executable.contains("/"), !executable.hasPrefix(".")
    else { throw BundleCheckError.mismatch("executable") }
    guard let minimumString = string("LSMinimumSystemVersion"),
      let minimum = OSVersion(minimumString)
    else { throw BundleCheckError.mismatch("minimum system version") }
    guard minimum <= os else { throw BundleCheckError.requiresNewerOS(minimumString) }

    try checkSignature(app: app, requirement: requirement)
  }

  // checkSignature is the API form of
  // `codesign --verify --deep --strict -R=<requirement>`.
  private static func checkSignature(app: URL, requirement: String) throws {
    var code: SecStaticCode?
    var status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
    guard status == errSecSuccess, let code else {
      throw BundleCheckError.signature(describe(status))
    }
    var secRequirement: SecRequirement?
    status = SecRequirementCreateWithString(requirement as CFString, [], &secRequirement)
    guard status == errSecSuccess, let secRequirement else {
      throw BundleCheckError.signature(describe(status))
    }
    let flags = SecCSFlags(
      rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
    var error: Unmanaged<CFError>?
    status = SecStaticCodeCheckValidityWithErrors(code, flags, secRequirement, &error)
    guard status == errSecSuccess else {
      let reason = error?.takeRetainedValue().localizedDescription ?? describe(status)
      throw BundleCheckError.signature(reason)
    }
  }

  private static func describe(_ status: OSStatus) -> String {
    SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
  }
}
