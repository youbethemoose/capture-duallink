import AppKit
import SwiftUI
import MetalKit
import CoreImage
import DualLinkCore

enum ViewerCommand: Int {
    case fit, fill, grid, trim, resetTrim, keepOnTop, duplicate, fullscreen
}

/// Accessory apps have no application menu bar. Temporarily become a regular app
/// while native fullscreen Spaces exist, so the system can reveal our menus.
@MainActor
private final class FullscreenMenus {
    static let shared = FullscreenMenus()
    private var windows: Set<UUID> = []

    func enter(_ id: UUID) {
        windows.insert(id)
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
    }

    func leave(_ id: UUID) {
        windows.remove(id)
        if windows.isEmpty, NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

final class MirrorOptions: ObservableObject {
    @Published var mode: ImageFit = .fit
    @Published var showGrid = false
}

/// Shared by every copy of one source: the fixed chrome to trim, in source points.
final class TrimModel: ObservableObject {
    let appName: String
    @Published var trim: SourceTrim
    init(appName: String, trim: SourceTrim) { self.appName = appName; self.trim = trim }
}

/// One shared GPU context for every viewer, with no video encoding or disk writes.
final class RenderEngine {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let context: CIContext
    /// Matches the capture so wide-gamut Live View colors reach each display unclipped.
    let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device; self.queue = queue
        queue.label = "Capture DualLink Rendering"
        context = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false, .name: "Capture DualLink"])
    }
}

final class MirrorSurface: MTKView, MTKViewDelegate {
    let engine: RenderEngine
    let options: MirrorOptions
    var frameImage: CIImage?
    var pictureArea: CGRect?
    var onDoubleClick: (() -> Void)?
    var onMenu: (() -> NSMenu)?
    var shouldRender: (() -> Bool)?
    private let inFlight = DispatchSemaphore(value: 2)
    private var redrawPending = false
    private(set) var droppedRenders = 0
    private(set) var totalGPUTime: Double = 0
    private(set) var completedFrames = 0
    private var gridCache: (picture: CGRect, size: CGSize, lineWidth: CGFloat, image: CIImage)?

    init(engine: RenderEngine, options: MirrorOptions) {
        self.engine = engine; self.options = options
        super.init(frame: .zero, device: engine.device)
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        colorspace = engine.colorSpace
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        autoResizeDrawable = true
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ frame: CapturedFrame) {
        frameImage = frame.image
        pictureArea = frame.pictureArea
        needsDisplay = true
    }

    func discardLiveFrame() { frameImage = nil; redrawPending = false }

    func draw(in view: MTKView) {
        guard shouldRender?() != false, drawableSize.width > 0, drawableSize.height > 0 else { return }
        guard inFlight.wait(timeout: .now()) == .success else {
            droppedRenders += 1; redrawPending = true; return
        }
        guard let drawable = currentDrawable, let command = engine.queue.makeCommandBuffer() else {
            inFlight.signal(); return
        }
        let bounds = CGRect(origin: .zero, size: drawableSize)
        let retainedImage = frameImage
        let output = renderedImage(size: drawableSize)
        engine.context.render(output, to: drawable.texture, commandBuffer: command,
                              bounds: bounds, colorSpace: engine.colorSpace)
        command.present(drawable)
        let gate = inFlight
        command.addCompletedHandler { [weak self, retainedImage] command in
            withExtendedLifetime(retainedImage) {}
            gate.signal()
            let time = max(0, command.gpuEndTime - command.gpuStartTime)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.completedFrames += 1
                self.totalGPUTime += time
                if self.redrawPending {
                    self.redrawPending = false
                    self.needsDisplay = true
                }
            }
        }
        command.commit()
    }

    func renderedImage(size: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        let black = CIImage(color: .black).cropped(to: bounds)
        guard let frameImage else { return black }
        let source = frameImage.extent.size
        let placement = ImageGeometry.placement(source: source, destination: size, mode: options.mode)
        guard placement.width > 0, placement.height > 0 else { return black }
        let transform = CGAffineTransform(a: placement.width / source.width, b: 0,
                                          c: 0, d: placement.height / source.height,
                                          tx: placement.minX, ty: placement.minY)
        var output = frameImage.transformed(by: transform).composited(over: black).cropped(to: bounds)
        if options.showGrid {
            // Thirds of the camera picture, not of Capture One's surrounding background.
            let picture = ImageGeometry.map(pictureArea ?? CGRect(origin: .zero, size: source),
                                            source: source, into: placement)
            output = gridImage(picture: picture, size: size).composited(over: output).cropped(to: bounds)
        }
        return output
    }

    /// Four procedural lines, cached until geometry changes. No per-frame CPU bitmap drawing.
    private func gridImage(picture: CGRect, size: CGSize) -> CIImage {
        let width = max(1, window?.backingScaleFactor ?? 1)
        if let cache = gridCache, cache.picture == picture, cache.size == size, cache.lineWidth == width {
            return cache.image
        }
        let bounds = CGRect(origin: .zero, size: size)
        let visible = picture.intersection(bounds)
        var grid = CIImage.empty()
        for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
            for vertical in [true, false] {
                let center = vertical ? picture.minX + picture.width * fraction : picture.minY + picture.height * fraction
                for (thickness, color) in [(width * 3, CIColor(red: 0, green: 0, blue: 0, alpha: 0.45)),
                                           (width, CIColor(red: 1, green: 1, blue: 1, alpha: 0.7))] {
                    let line = vertical ? CGRect(x: center - thickness / 2, y: picture.minY, width: thickness, height: picture.height)
                                        : CGRect(x: picture.minX, y: center - thickness / 2, width: picture.width, height: thickness)
                    let clipped = line.intersection(visible)
                    if !clipped.isEmpty { grid = CIImage(color: color).cropped(to: clipped).composited(over: grid) }
                }
            }
        }
        grid = grid.cropped(to: bounds)
        gridCache = (picture, size, width, grid)
        return grid
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Sidecar may have a different backing scale from the MacBook's display.
        drawableSize = convertToBacking(bounds).size
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { onDoubleClick?() }
    }
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, window?.styleMask.contains(.fullScreen) == true {
            onDoubleClick?()
        } else { super.keyDown(with: event) }
    }
    override var acceptsFirstResponder: Bool { true }
}

final class MirrorWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuDelegate, NSMenuItemValidation {
    let id = UUID()
    let sourceID: CGWindowID
    let options = MirrorOptions()
    let trimModel: TrimModel
    let surface: MirrorSurface
    var onClose: ((UUID) -> Void)?
    var onDuplicate: (() -> Void)?
    var onFullscreenStateChange: ((Bool) -> Void)?
    var onRequestFrame: (() -> CapturedFrame?)?
    var onActivityChange: (() -> Void)?
    private let status = NSTextField(wrappingLabelWithString: "Connecting to window…")
    private var trimPanel: NSPanel?
    private var observation: Any?
    private var hasImage = false
    private var optionsUpdatePending = false
    private(set) var acceptedFrames = 0
    private var closed = false
    private let sequence: Int
    private var fitControl: NSToolbarItemGroup?
    private var fullscreenControl: NSToolbarItem?
    private var gridControl: NSToolbarItem?
    private var levelBeforeFullscreen: NSWindow.Level?
    private var transitioningFullscreen = false
    private(set) var fullscreenPresentationOptions: NSApplication.PresentationOptions = []
    var wantsLiveFrames: Bool {
        !closed && (transitioningFullscreen ||
            (window?.isVisible == true && window?.isMiniaturized != true && window?.occlusionState.contains(.visible) == true))
    }

    private static let fitID = NSToolbarItem.Identifier("duallink.fit")
    private static let trimID = NSToolbarItem.Identifier("duallink.trim")
    private static let optionsID = NSToolbarItem.Identifier("duallink.options")
    private static let fullscreenID = NSToolbarItem.Identifier("duallink.fullscreen")
    private static let gridID = NSToolbarItem.Identifier("duallink.grid")

    init(sourceID: CGWindowID, title: String, sequence: Int, engine: RenderEngine, trimModel: TrimModel) {
        self.sourceID = sourceID; self.sequence = sequence; self.trimModel = trimModel
        surface = MirrorSurface(engine: engine, options: options)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "\(title) · Copy \(sequence)"
        window.minSize = NSSize(width: 240, height: 160)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.tabbingMode = .disallowed
        window.delegate = self
        window.contentView = surface
        let toolbar = NSToolbar(identifier: "CaptureDualLink.Viewer")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbarStyle = .unifiedCompact
        window.toolbar = toolbar
        surface.onDoubleClick = { [weak self] in self?.fullscreen() }
        surface.onMenu = { [weak self] in self?.makeMenu() ?? NSMenu() }
        surface.shouldRender = { [weak self] in
            guard let self else { return false }
            return !self.closed && self.window?.isVisible == true && self.window?.isMiniaturized != true &&
                self.window?.occlusionState.contains(.visible) == true
        }
        status.font = .systemFont(ofSize: 15, weight: .medium)
        status.textColor = .white
        status.alignment = .center
        status.maximumNumberOfLines = 4
        status.backgroundColor = .black.withAlphaComponent(0.85)
        status.drawsBackground = true
        status.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(status)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: surface.widthAnchor, multiplier: 0.8)
        ])
        observation = options.objectWillChange.sink { [weak self] in
            guard let self, !self.optionsUpdatePending else { return }
            self.optionsUpdatePending = true
            DispatchQueue.main.async {
                self.optionsUpdatePending = false
                guard !self.closed else { return }
                self.surface.needsDisplay = true
                self.updateToolbar()
            }
        }
        window.center()
        window.setFrameOrigin(NSPoint(x: window.frame.minX + CGFloat((sequence - 1) % 6) * 24,
                                      y: window.frame.minY - CGFloat((sequence - 1) % 6) * 24))
        updateToolbar()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func receive(_ frame: CapturedFrame) {
        guard wantsLiveFrames else { return }
        acceptedFrames += 1
        let firstFrame = !hasImage
        hasImage = true
        surface.update(frame)
        status.isHidden = true
        if firstFrame { updateToolbar() }
    }

    func showStatus(_ message: String?) {
        status.stringValue = message ?? ""
        status.isHidden = message == nil
    }

    func windowDidChangeScreen(_ notification: Notification) { visibilityChanged() }
    func windowDidBecomeKey(_ notification: Notification) { window?.makeFirstResponder(surface); visibilityChanged() }
    func windowDidChangeOcclusionState(_ notification: Notification) { visibilityChanged() }
    func windowDidMiniaturize(_ notification: Notification) { visibilityChanged() }
    func windowDidDeminiaturize(_ notification: Notification) { visibilityChanged() }

    private func visibilityChanged() {
        guard !closed else { return }
        if wantsLiveFrames {
            if let frame = onRequestFrame?() { receive(frame) }
        } else {
            releaseLiveFrame()
        }
        updateToolbar()
        onActivityChange?()
    }

    func releaseLiveFrame() {
        hasImage = false
        surface.discardLiveFrame()
    }
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        var options = proposedOptions
        options.subtract([.hideDock, .hideMenuBar])
        options.formUnion([.fullScreen, .autoHideDock, .autoHideMenuBar, .autoHideToolbar])
        fullscreenPresentationOptions = options
        return options
    }
    func windowWillEnterFullScreen(_ notification: Notification) {
        transitioningFullscreen = true
        levelBeforeFullscreen = window?.level
        window?.level = .normal
        FullscreenMenus.shared.enter(id)
    }
    func windowDidEnterFullScreen(_ notification: Notification) {
        transitioningFullscreen = false
        updateToolbar()
        onFullscreenStateChange?(true)
    }
    func windowWillExitFullScreen(_ notification: Notification) { transitioningFullscreen = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        transitioningFullscreen = false
        restoreWindowedState()
        onFullscreenStateChange?(false)
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        transitioningFullscreen = false
        restoreWindowedState()
    }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { transitioningFullscreen = false }
    private func restoreWindowedState() {
        if let levelBeforeFullscreen { window?.level = levelBeforeFullscreen }
        levelBeforeFullscreen = nil
        FullscreenMenus.shared.leave(id)
        updateToolbar()
    }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        FullscreenMenus.shared.leave(id)
        trimPanel?.close()
        releaseLiveFrame()
        onClose?(id)
    }

    private func item(_ title: String, _ action: Selector, value: Any? = nil, checked: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; item.representedObject = value; item.state = checked ? .on : .off
        return item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for mode in ImageFit.allCases {
            menu.addItem(item(mode.rawValue, #selector(setFit(_:)), value: mode.rawValue, checked: options.mode == mode))
        }
        menu.addItem(item("Rule of Thirds Grid", #selector(toggleGrid), checked: options.showGrid))
        menu.addItem(.separator())
        menu.addItem(item("Trim \(trimModel.appName) Toolbar…", #selector(showTrim)))
        menu.addItem(item("Reset Trim", #selector(resetTrim)))
        menu.addItem(.separator())
        let displays = NSMenu()
        for screen in NSScreen.screens {
            displays.addItem(item(screen.localizedName, #selector(moveToScreen(_:)), value: screen.displayID))
        }
        let move = NSMenuItem(title: "Move to Display", action: nil, keyEquivalent: "")
        move.submenu = displays; menu.addItem(move)
        menu.addItem(item(window?.styleMask.contains(.fullScreen) == true ? "Exit Full Screen" : "Enter Full Screen", #selector(fullscreen)))
        menu.addItem(item("Keep on Top", #selector(toggleFloating), checked: window?.level == .floating))
        menu.addItem(.separator())
        menu.addItem(item("Create Another Copy", #selector(duplicate)))
        menu.addItem(item("Close Copy", #selector(closeCopy)))
        return menu
    }

    func perform(_ command: ViewerCommand) {
        switch command {
        case .fit: options.mode = .fit
        case .fill: options.mode = .fill
        case .grid: toggleGrid()
        case .trim: showTrim()
        case .resetTrim: resetTrim()
        case .keepOnTop: toggleFloating()
        case .duplicate: duplicate()
        case .fullscreen: fullscreen()
        }
    }

    func validate(_ item: NSMenuItem, command: ViewerCommand) -> Bool {
        item.state = .off
        switch command {
        case .fit: item.state = options.mode == .fit ? .on : .off
        case .fill: item.state = options.mode == .fill ? .on : .off
        case .grid: item.state = options.showGrid ? .on : .off
        case .trim:
            item.title = "Trim \(trimModel.appName) Toolbar…"
        case .resetTrim: return trimModel.trim != .none
        case .keepOnTop:
            item.state = window?.level == .floating ? .on : .off
            return window?.styleMask.contains(.fullScreen) != true
        case .duplicate: return onDuplicate != nil
        case .fullscreen:
            item.title = window?.styleMask.contains(.fullScreen) == true ? "Exit Full Screen" : "Enter Full Screen"
            return !transitioningFullscreen
        }
        return true
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.fitID, .flexibleSpace, Self.gridID, Self.trimID, Self.optionsID, Self.fullscreenID]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == Self.fitID {
            let group = NSToolbarItemGroup(itemIdentifier: identifier, titles: ["Fit", "Fill"],
                                          selectionMode: .selectOne, labels: nil, target: self,
                                          action: #selector(changeToolbarFit(_:)))
            group.label = "Image Fit"
            group.toolTip = "Fit: entire image · Fill: crop to window (⌘1 / ⌘2)"
            group.selectedIndex = ImageFit.allCases.firstIndex(of: options.mode) ?? 0
            fitControl = group
            return group
        }
        if identifier == Self.optionsID {
            let control = NSMenuToolbarItem(itemIdentifier: identifier)
            control.label = "Viewer Options"
            control.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Viewer Options")
            control.menu = makeMenu()
            control.menu.delegate = self
            return control
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.target = self
        item.autovalidates = false
        switch identifier {
        case Self.gridID:
            gridControl = item
            item.label = "Rule of Thirds Grid"; item.toolTip = "Toggle grid for this copy (⌘G)"
            item.image = NSImage(systemSymbolName: "grid", accessibilityDescription: "Rule of Thirds Grid")
            item.action = #selector(toggleGrid)
        case Self.trimID:
            item.label = "Trim Toolbar"; item.toolTip = "Trim the source app's toolbar from every copy (⌘K)"
            item.image = NSImage(systemSymbolName: "crop", accessibilityDescription: "Trim Toolbar")
            item.action = #selector(showTrim)
        case Self.fullscreenID:
            fullscreenControl = item
            item.label = "Full Screen"; item.toolTip = "Enter Full Screen (⌃⌘F); Escape to exit"
            item.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Full Screen")
            item.action = #selector(fullscreen)
        default: return nil
        }
        return item
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let fresh = makeMenu()
        for item in fresh.items { fresh.removeItem(item); menu.addItem(item) }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(resetTrim): return trimModel.trim != .none
        case #selector(fullscreen): return !transitioningFullscreen
        case #selector(toggleFloating): return window?.styleMask.contains(.fullScreen) != true
        case #selector(duplicate): return onDuplicate != nil
        default: return true
        }
    }
    private func updateToolbar() {
        fitControl?.selectedIndex = ImageFit.allCases.firstIndex(of: options.mode) ?? 0
        gridControl?.image = NSImage(systemSymbolName: options.showGrid ? "grid.circle.fill" : "grid",
                                     accessibilityDescription: options.showGrid ? "Hide Grid" : "Show Grid")
        gridControl?.toolTip = options.showGrid ? "Hide grid for this copy (⌘G)" : "Show grid for this copy (⌘G)"
        let full = window?.styleMask.contains(.fullScreen) == true
        fullscreenControl?.image = NSImage(systemSymbolName: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                          accessibilityDescription: full ? "Exit Full Screen" : "Enter Full Screen")
        fullscreenControl?.toolTip = full ? "Exit Full Screen (Escape or ⌃⌘F)" : "Enter Full Screen (⌃⌘F)"
        fullscreenControl?.isEnabled = !transitioningFullscreen
    }
    @objc private func changeToolbarFit(_ sender: NSToolbarItemGroup) {
        guard ImageFit.allCases.indices.contains(sender.selectedIndex) else { return }
        options.mode = ImageFit.allCases[sender.selectedIndex]
    }
    @objc private func setFit(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ImageFit(rawValue: raw) else { return }
        options.mode = mode
    }
    @objc private func toggleGrid() { options.showGrid.toggle() }
    @objc private func fullscreen() {
        guard !transitioningFullscreen else { return }
        window?.toggleFullScreen(nil)
    }
    @objc private func toggleFloating() { window?.level = window?.level == .floating ? .normal : .floating }
    @objc private func duplicate() { onDuplicate?() }
    @objc private func closeCopy() { window?.close() }
    @objc private func resetTrim() { trimModel.trim = .none }
    @objc private func moveToScreen(_ sender: NSMenuItem) {
        // Match by display ID: the screen list may have changed since the menu opened.
        guard let id = sender.representedObject as? CGDirectDisplayID,
              let screen = NSScreen.screens.first(where: { $0.displayID == id }), let window else { return }
        window.setFrame(screen.visibleFrame, display: true, animate: true)
    }
    @objc private func showTrim() {
        if let trimPanel { trimPanel.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 360),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Trim \(trimModel.appName)"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: TrimEditor(model: trimModel))
        window?.addChildWindow(panel, ordered: .above)
        panel.center(); panel.makeKeyAndOrderFront(nil)
        trimPanel = panel
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private struct TrimEditor: View {
    @ObservedObject var model: TrimModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Trim \(model.appName)'s toolbar").font(.headline)
            Text("Remove fixed controls around Live View, in points. Gray bars around the camera picture are found automatically, and the grid follows the picture. Applies to every copy and is remembered on this Mac.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach([("Top", \SourceTrim.top), ("Left", \SourceTrim.left),
                     ("Bottom", \SourceTrim.bottom), ("Right", \SourceTrim.right)], id: \.0) { label, path in
                HStack {
                    Text(label).frame(width: 52, alignment: .leading)
                    Slider(value: Binding(get: { model.trim[keyPath: path] },
                                          set: { model.trim[keyPath: path] = $0.rounded() }), in: 0...300)
                    Text("\(Int(model.trim[keyPath: path])) pt")
                        .monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            }
            Button("Reset Trim") { model.trim = .none }
        }
        .padding(22).frame(width: 380, height: 360)
    }
}
