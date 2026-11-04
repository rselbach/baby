import AppKit
import BabyControl
import BabyUpdate
import SwiftUI
import os

/// Owns the menu bar item, the leases that keep the Mac awake, and the
/// caffeinate process that runs while any lease is held.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  // carries every lease into the updated Baby, base64-encoded JSON
  private static let leasesPrefix = "--leases="
  private let statusItem = NSStatusBar.system.statusItem(
    withLength: NSStatusItem.squareLength)
  private let menu = NSMenu()
  private let durations = NSMenu()
  private let updateItem = NSMenuItem(
    title: "Check for Updates…", action: #selector(performUpdateAction), keyEquivalent: "")
  private let updater = Updater()
  private let presets = ActivationPresets()
  private let log = Logger(subsystem: "com.rselbach.baby", category: "control")
  private var leases = LeaseSet()
  private var leaseItems: [NSMenuItem] = []
  private var caffeinate: Process?
  private var expiryTimer: Timer?
  private var processWatchers: [Int32: any DispatchSourceProcess] = [:]
  private var server: ControlServer?
  private var settingsWindow: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    durations.autoenablesItems = false
    let activateItem = NSMenuItem(title: "Activate for", action: nil, keyEquivalent: "")
    activateItem.submenu = durations
    menu.addItem(activateItem)
    menu.addItem(.separator())
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

    let editMenu = NSMenu(title: "Edit")
    for (title, action, key) in [
      ("Cut", #selector(NSText.cut(_:)), "x"),
      ("Copy", #selector(NSText.copy(_:)), "c"),
      ("Paste", #selector(NSText.paste(_:)), "v"),
      ("Select All", #selector(NSText.selectAll(_:)), "a"),
    ] {
      editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
    }
    let editMenuItem = NSMenuItem()
    editMenuItem.submenu = editMenu

    let windowMenu = NSMenu()
    windowMenu.addItem(
      withTitle: "Close", action: #selector(NSWindow.performClose(_:)),
      keyEquivalent: "w")
    let windowMenuItem = NSMenuItem()
    windowMenuItem.submenu = windowMenu

    let mainMenu = NSMenu()
    mainMenu.addItem(appMenuItem)
    mainMenu.addItem(editMenuItem)
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
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    update()
    restoreLaunchState()
    startServer()
    updater?.start()
  }

  // Relaunch arguments preserve the live state across an update,
  // overriding the normal launch preference. Earlier Babys relaunch with
  // --awake or --awake-until=; newer ones pass every lease in --leases=.
  private func restoreLaunchState() {
    let args = CommandLine.arguments
    if let argument = args.first(where: { $0.hasPrefix(Self.leasesPrefix) }) {
      let encoded = argument.dropFirst(Self.leasesPrefix.count)
      do {
        // invalid base64 decodes to nothing, which the JSON decoder rejects
        let data = Data(base64Encoded: String(encoded)) ?? Data()
        for lease in try ControlCoding.decoder().decode([Lease].self, from: data) {
          leases.hold(lease)
        }
      } catch {
        log.error("could not restore leases: \(error.localizedDescription, privacy: .public)")
      }
      presentFailure(apply())
      return
    }
    let deadlinePrefix = "--awake-until="
    if let argument = args.first(where: { $0.hasPrefix(deadlinePrefix) }) {
      if let timestamp = TimeInterval(argument.dropFirst(deadlinePrefix.count)),
        timestamp.isFinite
      {
        holdForUser(until: Date(timeIntervalSince1970: timestamp))
      }
    } else if args.contains("--awake")
      || (!args.contains("--asleep")
        && UserDefaults.standard.bool(forKey: SettingsKey.activateOnLaunch))
    {
      holdForUser(until: nil)
    }
  }

  private func startServer() {
    do {
      server = try ControlServer(url: ControlSocket.defaultURL) { [weak self] request in
        self?.handle(request) ?? ControlResponse(error: "Baby is quitting.")
      }
    } catch {
      log.error("control socket unavailable: \(error.localizedDescription, privacy: .public)")
    }
  }

  // handle answers a request from the control socket.
  private func handle(_ request: ControlRequest) -> ControlResponse {
    switch request.command {
    case .hold:
      let lease: Lease
      do {
        lease = try Lease(holding: request, now: Date(), isRunning: processIsRunning)
      } catch {
        return ControlResponse(error: error.message)
      }
      leases.hold(lease)
      if let error = apply() {
        return ControlResponse(error: error.localizedDescription)
      }
      return ControlResponse(lease: lease)
    case .release:
      guard let id = request.id else {
        return ControlResponse(error: "Name the lease to release.")
      }
      guard id != LeaseSet.userID else {
        return ControlResponse(error: "The lease ID \"user\" is reserved for Baby's menu.")
      }
      // releasing a lease that already ended succeeds, so retries are safe
      leases.removeAll { $0.id == id }
      apply()
      return ControlResponse()
    case .status:
      apply()
      return ControlResponse(leases: leases.leases)
    }
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    for item in leaseItems {
      menu.removeItem(item)
    }
    leaseItems = []
    if !leases.isEmpty {
      leaseItems.append(.sectionHeader(title: "Keeping Awake For"))
      leaseItems.append(contentsOf: leases.leases.map(leaseMenuItem))
      leaseItems.append(.separator())
    }
    for (index, item) in leaseItems.enumerated() {
      menu.insertItem(item, at: index)
    }
    durations.removeAllItems()
    for minutes in [0] + presets.minutes {
      let title = minutes == 0 ? "Permanent (default)" : ActivationPresets.title(for: minutes)
      let item = NSMenuItem(
        title: title, action: #selector(activateFor(_:)), keyEquivalent: "")
      item.target = self
      item.tag = minutes * 60
      durations.addItem(item)
    }
    guard let updater else { return }
    updateItem.title = updater.state.actionTitle
    updateItem.isEnabled = updater.state.actionEnabled
  }

  func applicationWillTerminate(_ notification: Notification) {
    server?.stop()
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
            presets: presets,
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
        if await updater.restartToUpdate(launchArguments: {
          guard !self.leases.isEmpty else { return ["--asleep"] }
          do {
            let data = try ControlCoding.encoder().encode(self.leases.leases)
            return [Self.leasesPrefix + data.base64EncodedString()]
          } catch {
            return ["--awake"]
          }
        }) {
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

  // toggle holds the user's lease while the Mac may sleep, and otherwise
  // ends every lease: the user always wins over agents.
  private func toggle() {
    guard leases.isEmpty else {
      leases.removeAll { _ in true }
      apply()
      return
    }
    holdForUser(until: nil)
  }

  @objc private func activateFor(_ sender: NSMenuItem) {
    holdForUser(
      until: sender.tag == 0 ? nil : Date().addingTimeInterval(TimeInterval(sender.tag)))
  }

  @objc private func releaseLease(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    leases.removeAll { $0.id == id }
    apply()
  }

  @objc private func didWake() {
    // timers don't count time asleep, so deadlines may have passed
    apply()
  }

  private func holdForUser(until deadline: Date?) {
    if let deadline, deadline <= Date() { return }
    leases.hold(Lease(id: LeaseSet.userID, label: "You", deadline: deadline))
    presentFailure(apply())
  }

  private func presentFailure(_ error: (any Error)?) {
    guard let error else { return }
    NSApp.activate()
    NSAlert(error: error).runModal()
  }

  // apply drops finished leases, then makes caffeinate, the expiry timer, the
  // process watchers, and the menu bar item match the rest. If caffeinate
  // can't start, it ends every lease and returns why.
  @discardableResult
  private func apply() -> (any Error)? {
    leases.removeFinished(now: Date(), isRunning: processIsRunning)
    var failure: (any Error)?
    if leases.isEmpty {
      stopCaffeinate()
    } else if caffeinate == nil {
      do {
        try startCaffeinate()
      } catch {
        leases.removeAll { _ in true }
        failure = error
      }
    }
    scheduleExpiry()
    watchProcesses()
    update()
    return failure
  }

  private func startCaffeinate() throws {
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
    try process.run()
    caffeinate = process
  }

  private func stopCaffeinate() {
    guard let running = caffeinate else { return }
    caffeinate = nil
    running.terminate()
  }

  // caffeinateExited ends every lease when caffeinate dies on its own.
  private func caffeinateExited(_ id: ObjectIdentifier) {
    guard let running = caffeinate, ObjectIdentifier(running) == id else {
      return
    }
    caffeinate = nil
    leases.removeAll { _ in true }
    apply()
  }

  private func scheduleExpiry() {
    expiryTimer?.invalidate()
    expiryTimer = nil
    guard let deadline = leases.nextDeadline else { return }
    let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.apply()
        return
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    expiryTimer = timer
  }

  // watchProcesses ends a lease as soon as its process exits.
  private func watchProcesses() {
    let pids = Set(leases.leases.compactMap(\.pid))
    for (pid, watcher) in processWatchers where !pids.contains(pid) {
      watcher.cancel()
      processWatchers[pid] = nil
    }
    for pid in pids where processWatchers[pid] == nil {
      let watcher = DispatchSource.makeProcessSource(
        identifier: pid, eventMask: .exit, queue: .main)
      watcher.setEventHandler { [weak self] in
        MainActor.assumeIsolated { self?.processExited(pid) }
      }
      watcher.resume()
      processWatchers[pid] = watcher
      // a process that exited before the watcher started never reports it
      if !processIsRunning(pid) {
        DispatchQueue.main.async { [weak self] in self?.processExited(pid) }
      }
    }
  }

  // processExited ends the leases tied to pid. It can't rely on
  // removeFinished: an exited process stays visible until its parent reaps it.
  private func processExited(_ pid: Int32) {
    leases.removeAll { $0.pid == pid }
    apply()
  }

  private func leaseMenuItem(_ lease: Lease) -> NSMenuItem {
    var title = lease.label
    if let deadline = lease.deadline {
      title += " — until \(Self.describe(deadline))"
    }
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let submenu = NSMenu()
    submenu.autoenablesItems = false
    if let pid = lease.pid {
      let detail = NSMenuItem(title: "While process \(pid) runs", action: nil, keyEquivalent: "")
      detail.isEnabled = false
      submenu.addItem(detail)
    }
    let release = NSMenuItem(
      title: "Release", action: #selector(releaseLease(_:)), keyEquivalent: "")
    release.target = self
    release.representedObject = lease.id
    submenu.addItem(release)
    item.submenu = submenu
    return item
  }

  // describe names a deadline by its time, adding the date unless it's today.
  private static func describe(_ deadline: Date) -> String {
    guard Calendar.current.isDateInToday(deadline) else {
      return deadline.formatted(date: .abbreviated, time: .shortened)
    }
    return deadline.formatted(date: .omitted, time: .shortened)
  }

  private func update() {
    let awake = !leases.isEmpty
    guard let button = statusItem.button else { return }
    let image = NSImage(named: awake ? "baby-on" : "baby-off")
    image?.isTemplate = true
    image?.accessibilityDescription = awake ? "Sleep prevented" : "Sleep allowed"
    button.image = image
    button.toolTip = toolTip
  }

  private var toolTip: String {
    let others = leases.leases.filter { $0.id != LeaseSet.userID }.map(\.label)
    guard others.isEmpty else {
      return "Baby: keeping your Mac awake for \(others.formatted(.list(type: .and)))"
    }
    guard let user = leases.leases.first else { return "Baby: sleep allowed" }
    guard let deadline = user.deadline else { return "Baby: keeping your Mac awake" }
    return "Baby: keeping your Mac awake until \(Self.describe(deadline))"
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
