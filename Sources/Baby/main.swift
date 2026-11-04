import AppKit
import BabyUpdate
import SwiftUI

/// Owns the menu bar item and the caffeinate process that keeps the Mac awake.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let statusItem = NSStatusBar.system.statusItem(
    withLength: NSStatusItem.squareLength)
  private let menu = NSMenu()
  private let updateItem = NSMenuItem(
    title: "Check for Updates…", action: #selector(performUpdateAction), keyEquivalent: "")
  private let updater = Updater()
  private var caffeinate: Process?
  private var settingsWindow: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let settingsItem = NSMenuItem(
      title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
    settingsItem.target = self
    menu.addItem(settingsItem)
    if updater != nil {
      updateItem.target = self
      menu.addItem(updateItem)
    }
    menu.addItem(.separator())
    menu.addItem(
      NSMenuItem(
        title: "Quit Baby", action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"))
    // Accessory apps show no main menu, but its key equivalents still work
    // in the settings window.
    let appMenu = NSMenu()
    let mainSettingsItem = NSMenuItem(
      title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
    mainSettingsItem.target = self
    appMenu.addItem(mainSettingsItem)
    appMenu.addItem(
      withTitle: "Quit Baby", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    let appMenuItem = NSMenuItem()
    appMenuItem.submenu = appMenu

    let windowMenu = NSMenu()
    windowMenu.addItem(
      withTitle: "Close", action: #selector(NSWindow.performClose(_:)),
      keyEquivalent: "w")
    let windowMenuItem = NSMenuItem()
    windowMenuItem.submenu = windowMenu

    let mainMenu = NSMenu()
    mainMenu.addItem(appMenuItem)
    mainMenu.addItem(windowMenuItem)
    NSApp.mainMenu = mainMenu
    menu.autoenablesItems = false
    menu.delegate = self
    statusItem.button?.target = self
    statusItem.button?.action = #selector(statusItemClicked)
    statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    statusItem.button?.setAccessibilityCustomActions([
      NSAccessibilityCustomAction(name: "Show Menu") { [weak self] in
        self?.showStatusMenu()
        return true
      }
    ])
    update()
    // --awake and --asleep preserve the live state across an update relaunch,
    // overriding the normal launch preference.
    let args = CommandLine.arguments
    let shouldStart =
      if args.contains("--awake") {
        true
      } else if args.contains("--asleep") {
        false
      } else {
        UserDefaults.standard.bool(forKey: SettingsKey.activateOnLaunch)
      }
    if shouldStart {
      start()
    }
    updater?.start()
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    guard let updater else { return }
    updateItem.title = updater.state.actionTitle
    updateItem.isEnabled = updater.state.actionEnabled
  }

  func applicationWillTerminate(_ notification: Notification) {
    caffeinate?.terminate()
  }

  // statusItemClicked toggles on left click and shows the menu on right,
  // control, or option click.
  @objc private func statusItemClicked() {
    let event = NSApp.currentEvent
    let wantsMenu =
      event?.type == .rightMouseUp
      || event?.modifierFlags.intersection([.control, .option]).isEmpty == false
    guard wantsMenu else {
      toggle()
      return
    }
    showStatusMenu()
  }

  // Attaching the menu only for this click keeps left clicks as toggles.
  private func showStatusMenu() {
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  @objc private func showSettings() {
    if settingsWindow == nil {
      let window = NSWindow(
        contentViewController: NSHostingController(
          rootView: SettingsView(
            updater: updater,
            updateAction: { [weak self] in self?.performUpdateAction() })))
      window.title = "Baby Settings"
      window.styleMask = [.titled, .closable]
      window.isReleasedWhenClosed = false
      window.center()
      settingsWindow = window
    }
    NSApp.activate()
    settingsWindow?.makeKeyAndOrderFront(nil)
  }

  // performUpdateAction does what the update item offers: restart into a
  // staged update, open a release that can't be installed in place, or check.
  @objc private func performUpdateAction() {
    guard let updater else { return }
    switch updater.state {
    case .ready:
      Task {
        if await updater.restartToUpdate(isAwake: { self.caffeinate != nil }) {
          NSApp.terminate(nil)
        } else {
          presentUpdateResult()
        }
      }
    case .available(_, let page):
      NSWorkspace.shared.open(page)
    default:
      Task {
        await updater.check()
        presentUpdateResult()
      }
    }
  }

  private func presentUpdateResult() {
    guard let updater else { return }
    let alert = NSAlert()
    switch updater.state {
    case .upToDate:
      alert.messageText = "Baby is up to date."
      alert.informativeText = "You're running Baby \(updater.version) (\(updater.build))."
    case .ready(let version):
      alert.messageText = "Baby \(version) is ready to install."
      alert.informativeText = "Baby will restart to finish updating."
      alert.addButton(withTitle: "Restart Now")
      alert.addButton(withTitle: "Later")
    case .available(let version, _):
      alert.messageText = "Baby \(version) is available."
      alert.informativeText =
        "Baby can't update itself where it is. Download the new version and move it to Applications."
      alert.addButton(withTitle: "Download")
      alert.addButton(withTitle: "Later")
    case .failed(let reason), .stranded(let reason):
      alert.messageText = "Baby couldn't update."
      alert.informativeText = reason
      alert.alertStyle = .warning
    case .requiresNewerOS:
      alert.messageText = "Baby can't update."
      alert.informativeText = updater.state.caption ?? ""
    default:
      return
    }
    NSApp.activate()
    guard alert.runModal() == .alertFirstButtonReturn, alert.buttons.count == 2 else {
      return
    }
    performUpdateAction()
  }

  private func toggle() {
    guard let running = caffeinate else {
      start()
      return
    }
    caffeinate = nil
    running.terminate()
    update()
  }

  private func start() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
    // -d display, -i idle, -s system (on AC power). -w ties caffeinate's
    // lifetime to ours so a crash never leaves the Mac stuck awake.
    process.arguments = [
      "-dis", "-w", String(ProcessInfo.processInfo.processIdentifier),
    ]
    let id = ObjectIdentifier(process)
    process.terminationHandler = { [weak self] _ in
      Task { @MainActor in self?.caffeinateExited(id) }
    }
    do {
      try process.run()
    } catch {
      NSApp.activate()
      NSAlert(error: error).runModal()
      return
    }
    caffeinate = process
    update()
  }

  // caffeinateExited resets state when caffeinate dies on its own.
  private func caffeinateExited(_ id: ObjectIdentifier) {
    guard let running = caffeinate, ObjectIdentifier(running) == id else {
      return
    }
    caffeinate = nil
    update()
  }

  private func update() {
    let awake = caffeinate != nil
    guard let button = statusItem.button else { return }
    let image = NSImage(named: awake ? "baby-on" : "baby-off")
    image?.isTemplate = true
    image?.accessibilityDescription = awake ? "Sleep prevented" : "Sleep allowed"
    button.image = image
    button.toolTip = awake ? "Baby: keeping your Mac awake" : "Baby: sleep allowed"
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
