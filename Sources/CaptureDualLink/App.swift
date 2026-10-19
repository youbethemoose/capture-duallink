import AppKit
import SwiftUI

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--self-test"),
           CommandLine.arguments.indices.contains(index + 1) {
            probe = CaptureProbe(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            probe?.run()
            return
        }
        let model = AppModel()
        self.model = model
        model.onCountChange = { [weak self] in self?.updateStatus() }
        model.onShowPicker = { [weak self] in self?.showPicker() }
        model.onDuplicated = { [weak self] pid in
            self?.picker?.orderOut(nil)
            AppModel.returnFocus(to: pid)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Capture DualLink")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatus()
        createMainMenu()
        showPicker()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPicker(); return true
    }

    private func createMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Capture DualLink…", action: #selector(showPicker), keyEquivalent: ",").target = self
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
        statusItem?.button?.toolTip = "Capture DualLink · \(count) active copies\nClick to choose a window. Right-click for actions."
    }

    @objc private func statusClicked(_ sender: Any?) {
        guard let model else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let title = NSMenuItem(title: "Capture DualLink", action: nil, keyEquivalent: "")
            title.isEnabled = false; menu.addItem(title)
            menu.addItem(withTitle: "Duplicate a Window…", action: #selector(showPicker), keyEquivalent: "").target = self
            if !model.mirrors.isEmpty {
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
        guard let model else { return } // Self-test runs have no picker.
        if picker == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 500),
                                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            panel.title = "Capture DualLink"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            panel.contentView = NSHostingView(rootView: PickerView(model: model, onHide: { [weak panel] in panel?.orderOut(nil) }))
            panel.center()
            picker = panel
        }
        picker?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Task { await model.refreshSources() }
    }

    @objc private func revealCopy(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let mirror = model?.mirrors[id] else { return }
        mirror.window?.deminiaturize(nil); mirror.window?.orderFrontRegardless()
    }
    @objc private func permissionSettings() { model?.openPermissionSettings() }
    @objc private func closeCopies() { model?.closeAll() }
    @objc private func quitApp() { model?.closeAll(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}
