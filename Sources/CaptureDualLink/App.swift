import AppKit
import SwiftUI
import CoreServices

@main
enum CaptureDualLinkApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        NSWindow.allowsAutomaticWindowTabbing = false
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var picker: NSPanel?
    private var model: AppModel?
    private var probe: CaptureProbe?
    private var startup: HomeWiFiController?
    private var startupPanel: NSPanel?
    private var setupPanel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--self-test"),
           CommandLine.arguments.indices.contains(index + 1) {
            probe = CaptureProbe(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            probe?.run()
            return
        }
        let startup = HomeWiFiController()
        self.startup = startup
        startup.onAway = { [weak self] in self?.showPicker() }
        startup.onChange = { [weak self] in self?.updateStatus() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuBarIcon.image
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatus()
        createMainMenu()
        // A login launch watches quietly at home. Manual launches always open normally.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginLaunch = event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !startup.enabled || !loginLaunch { showPicker() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPicker(); return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if setupPanel?.isVisible == true { Task { await model?.refreshSources() } }
    }

    private func createMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Capture DualLink…", action: #selector(showPicker), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Setup Guide…", action: #selector(showSetupGuide), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Automatic Startup…", action: #selector(showAutomaticStartup), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Capture DualLink", action: #selector(quitApp), keyEquivalent: "q").target = self
        appItem.submenu = appMenu; main.addItem(appItem)
        let windowItem = NSMenuItem()
        let windows = NSMenu(title: "Window")
        windows.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windows; main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windows
    }

    private func updateStatus() {
        let count = model?.mirrorCount ?? 0
        statusItem?.button?.title = count > 0 ? " \(count)" : ""
        let automation = startup?.enabled == true ? "\n\(startup?.status ?? "")" : ""
        statusItem?.button?.toolTip = "Capture DualLink · \(count) active copies\nClick to choose a window. Right-click for actions.\(automation)"
    }

    @objc private func statusClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let title = NSMenuItem(title: "Capture DualLink", action: nil, keyEquivalent: "")
            title.isEnabled = false; menu.addItem(title)
            menu.addItem(withTitle: "Duplicate a Window…", action: #selector(showPicker), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Setup Guide…", action: #selector(showSetupGuide), keyEquivalent: "").target = self
            let autoStart = NSMenuItem(title: "Automatic Startup…", action: #selector(showAutomaticStartup), keyEquivalent: "")
            autoStart.target = self; autoStart.state = startup?.enabled == true ? .on : .off
            menu.addItem(autoStart)
            if let model, !model.mirrors.isEmpty {
                menu.addItem(.separator())
                for mirror in model.mirrors.values.sorted(by: { ($0.window?.title ?? "") < ($1.window?.title ?? "") }) {
                    let item = NSMenuItem(title: mirror.window?.title ?? "Copy", action: #selector(revealCopy(_:)), keyEquivalent: "")
                    item.target = self; item.representedObject = mirror.id; menu.addItem(item)
                }
                menu.addItem(withTitle: "Close All Copies", action: #selector(closeCopies), keyEquivalent: "").target = self
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Screen Recording Settings…", action: #selector(permissionSettings), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Quit Capture DualLink", action: #selector(quitApp), keyEquivalent: "q").target = self
            if let button = statusItem.button {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
            }
        } else if picker?.isVisible == true {
            picker?.orderOut(nil)
        } else { showPicker() }
    }

    @objc func showPicker() {
        guard probe == nil else { return }
        guard UserDefaults.standard.bool(forKey: "hasCompletedSetupGuide") else { showSetupGuide(); return }
        let model = ensureModel()
        if picker == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 500),
                                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            panel.title = "Capture DualLink"
            panel.appearance = NSAppearance(named: .aqua)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            panel.contentView = NSHostingView(rootView: PickerView(model: model, onShowGuide: { [weak self] in self?.showSetupGuide() }))
            panel.center()
            picker = panel
        }
        picker?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Task { await model.refreshSources() }
    }

    @objc private func showSetupGuide() {
        guard probe == nil else { return }
        let model = ensureModel()
        if setupPanel == nil {
            let height = min(740, (NSScreen.main?.visibleFrame.height ?? 820) - 64)
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 820, height: height),
                                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = "Welcome to Capture DualLink"
            panel.appearance = NSAppearance(named: .aqua)
            panel.styleMask.insert(.fullSizeContentView)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.minSize = NSSize(width: 780, height: 590)
            panel.contentView = NSHostingView(rootView: SetupGuideView(model: model, onContinue: { [weak self] in
                UserDefaults.standard.set(true, forKey: "hasCompletedSetupGuide")
                self?.setupPanel?.close()
                self?.showPicker()
            }))
            panel.center()
            setupPanel = panel
        }
        setupPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Task { await model.refreshSources() }
    }

    /// Avoid allocating Metal or enumerating windows for the idle login watcher.
    private func ensureModel() -> AppModel {
        if let model { return model }
        let model = AppModel()
        self.model = model
        model.onCountChange = { [weak self] in self?.updateStatus() }
        model.onShowPicker = { [weak self] in self?.showPicker() }
        model.onDuplicated = { [weak self] pid in
            self?.picker?.orderOut(nil)
            AppModel.returnFocus(to: pid)
        }
        return model
    }

    @objc private func showAutomaticStartup() {
        guard let startup else { return }
        if startupPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 450, height: 460),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Automatic Startup"
            panel.appearance = NSAppearance(named: .aqua)
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: AutoStartView(startup: startup))
            panel.center()
            startupPanel = panel
        }
        startupPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func revealCopy(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let mirror = model?.mirrors[id] else { return }
        mirror.window?.deminiaturize(nil); mirror.window?.orderFrontRegardless()
    }
    @objc private func permissionSettings() { ensureModel().openPermissionSettings() }
    @objc private func closeCopies() { model?.closeAll() }
    @objc private func quitApp() { model?.closeAll(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { startup?.shutdown(); model?.shutdown() }
}
