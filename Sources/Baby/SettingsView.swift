import ServiceManagement
import SwiftUI

/// UserDefaults keys for Baby's settings.
enum SettingsKey {
  /// Whether Baby starts preventing sleep as soon as it launches.
  static let activateOnLaunch = "activateOnLaunch"
}

/// The settings window content.
struct SettingsView: View {
  /// The updater, or nil for builds that never update.
  let updater: Updater?
  /// Runs the updater's current action, such as checking or restarting.
  let updateAction: @MainActor () -> Void
  @AppStorage(SettingsKey.activateOnLaunch) private var activateOnLaunch = false
  @State private var loginStatus = SMAppService.mainApp.status
  @State private var loginError: String?

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
      if let updater {
        Divider()
        updates(updater)
      }
    }
    .padding(30)
    .frame(width: 420, alignment: .leading)
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
