import AppKit
import BabyUpdate
import ServiceManagement
import SwiftUI

/// UserDefaults keys for Baby's settings.
enum SettingsKey {
  /// Whether Baby starts preventing sleep as soon as it launches.
  static let activateOnLaunch = "activateOnLaunch"
}

/// The settings window content.
struct SettingsView: View {
  /// Saved durations shared with the activation menu.
  let presets: ActivationPresets
  /// The updater, or nil for builds that never update.
  let updater: Updater?
  /// Runs the updater's current action, such as checking or restarting.
  let updateAction: @MainActor () -> Void
  @AppStorage(SettingsKey.activateOnLaunch) private var activateOnLaunch = false
  @State private var loginStatus = SMAppService.mainApp.status
  @State private var loginError: String?
  @State private var presetMinutes = ""
  @State private var toolInstalled = false
  @State private var toolError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      option(
        "Start at Login",
        detail: "Automatically opens Baby when you log in.",
        isOn: Binding(
          get: { loginStatus == .enabled || loginStatus == .requiresApproval },
          set: setStartAtLogin))
      if loginStatus == .requiresApproval {
        Button("Approve in Login Items…") {
          SMAppService.openSystemSettingsLoginItems()
        }
        .padding(.leading, 20)
      }
      if let loginError {
        Text(loginError)
          .font(.callout)
          .foregroundStyle(.red)
          .padding(.leading, 20)
      }
      option(
        "Activate on Launch",
        detail: "Immediately starts preventing sleep when Baby opens.",
        isOn: $activateOnLaunch)
      Divider()
      presetEditor
      if let helper = CommandLineTool.helper {
        Divider()
        commandLineTool(helper)
      }
      if let updater {
        Divider()
        updates(updater)
      }
    }
    .padding(30)
    .frame(width: 420, alignment: .leading)
    .onAppear { loginStatus = SMAppService.mainApp.status }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      loginStatus = SMAppService.mainApp.status
    }
  }

  private var presetEditor: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Temporary activation presets")
        .font(.headline)
      Text("Choose these durations from Activate for.")
        .font(.callout)
        .foregroundStyle(.secondary)
      if presets.minutes.isEmpty {
        Text("No temporary presets. Add one below.")
          .foregroundStyle(.secondary)
      } else {
        ScrollView {
          VStack(spacing: 6) {
            ForEach(presets.minutes, id: \.self) { minutes in
              HStack {
                Text(ActivationPresets.title(for: minutes))
                Spacer()
                Button {
                  presets.remove(minutes: minutes)
                } label: {
                  Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(ActivationPresets.title(for: minutes)) preset")
              }
              .frame(height: 22)
            }
          }
        }
        .frame(height: min(CGFloat(presets.minutes.count) * 28, 168))
      }
      HStack {
        TextField("Minutes", text: $presetMinutes)
          .frame(width: 100)
          .accessibilityLabel("Preset duration in minutes")
          .onSubmit(addPreset)
        Button("Add", action: addPreset)
          .disabled(minutesToAdd == nil)
      }
      if !presetMinutes.isEmpty, minutesToAdd == nil {
        Text(presetFeedback)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var parsedMinutes: Int? {
    guard let minutes = Int(presetMinutes.trimmingCharacters(in: .whitespacesAndNewlines)),
      (1...ActivationPresets.maximumMinutes).contains(minutes)
    else {
      return nil
    }
    return minutes
  }

  private var minutesToAdd: Int? {
    guard let minutes = parsedMinutes, !presets.minutes.contains(minutes) else { return nil }
    return minutes
  }

  private var presetFeedback: String {
    if parsedMinutes != nil {
      return "This preset already exists."
    }
    return "Enter whole minutes between 1 and \(ActivationPresets.maximumMinutes)."
  }

  private func addPreset() {
    guard let minutes = minutesToAdd else { return }
    presets.add(minutes: minutes)
    presetMinutes = ""
  }

  private func commandLineTool(_ helper: URL) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Command line tool")
        .font(.headline)
      Text("Lets agents and scripts keep your Mac awake, as in `baby run make test`.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Install") {
          do {
            try CommandLineTool.install(helper)
            toolError = nil
          } catch {
            toolError = error.localizedDescription
          }
          toolInstalled = CommandLineTool.isInstalled(helper)
        }
        .disabled(toolInstalled)
        Text(toolInstalled ? "Installed in ~/.local/bin" : "Adds baby to ~/.local/bin")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      if let toolError {
        Text(toolError)
          .font(.callout)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .onAppear { toolInstalled = CommandLineTool.isInstalled(helper) }
  }

  private func updates(_ updater: Updater) -> some View {
    @Bindable var updater = updater
    return VStack(alignment: .leading, spacing: 12) {
      Toggle("Check for updates automatically", isOn: $updater.automaticChecks)
        .toggleStyle(.checkbox)
      HStack {
        Button(updater.state.actionTitle, action: updateAction)
          .disabled(!updater.state.actionEnabled)
        Spacer()
        Text("Version \(updater.version) (\(updater.build))")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      if let caption = updater.state.caption {
        Text(caption)
          .font(.callout)
          .foregroundStyle(updater.state.isProblem ? .orange : .secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func option(_ title: String, detail: String, isOn: Binding<Bool>)
    -> some View
  {
    VStack(alignment: .leading, spacing: 4) {
      Toggle(title, isOn: isOn)
        .toggleStyle(.checkbox)
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.leading, 20)
    }
  }

  // setStartAtLogin registers or removes Baby as a login item.
  private func setStartAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      loginError = nil
    } catch {
      loginError = error.localizedDescription
    }
    loginStatus = SMAppService.mainApp.status
  }
}
