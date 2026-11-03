import AppKit
import SwiftUI
import MetalKit
import CoreImage
import DualLinkCore

enum ViewerCommand: Int {
    case fit, fill, grid, fillDisplay, trim, resetTrim, keepOnTop, duplicate, controlSource
}

final class MirrorOptions: ObservableObject {
    @Published var mode: ImageFit = .fit
    @Published var showGrid = false
    @Published var controlSource = false
}

/// Shared by every copy of one source: the fixed chrome to trim, in source points.
final class TrimModel: ObservableObject {
    let appName: String
    @Published var trim: SourceTrim
    init(appName: String, trim: SourceTrim) { self.appName = appName; self.trim = trim }
}

/// A viewer that can never become the key or main window, so clicking or tapping it never
/// takes keyboard focus from Capture One: shortcuts such as ⌘K keep reaching Capture One.
final class ViewerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Controls inside a window that never becomes key must act on the first click.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onPointerActivity: (() -> Void)?
    var onMenu: (() -> NSMenu)?
    var shouldRender: (() -> Bool)?
    var onSourceEvent: ((NSEvent) -> Void)?
    private(set) var capturedFrame: CapturedFrame?
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
        // .activeAlways: DualLink is normally not the active app.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ frame: CapturedFrame) {
        capturedFrame = frame
        frameImage = frame.image
        pictureArea = frame.pictureArea
        needsDisplay = true
    }

    func discardLiveFrame() { capturedFrame = nil; frameImage = nil; redrawPending = false }

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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if options.controlSource { onSourceEvent?(event); return }
        if event.clickCount == 2 { onDoubleClick?() } else { onClick?() }
    }
    override func mouseUp(with event: NSEvent) { if options.controlSource { onSourceEvent?(event) } }
    override func mouseDragged(with event: NSEvent) { if options.controlSource { onSourceEvent?(event) } }
    override func rightMouseDown(with event: NSEvent) {
        if options.controlSource { onSourceEvent?(event) } else { super.rightMouseDown(with: event) }
    }
    override func rightMouseUp(with event: NSEvent) { if options.controlSource { onSourceEvent?(event) } }
    override func rightMouseDragged(with event: NSEvent) { if options.controlSource { onSourceEvent?(event) } }
    override func otherMouseDown(with event: NSEvent) { if options.controlSource { onSourceEvent?(event) } }
    override func otherMouseUp(with event: NSEvent) { if options.controlSource { onSourceEvent?(event) } }
    override func otherMouseDragged(with event: NSEvent) { if options.controlSource { onSourceEvent?(event) } }
    override func scrollWheel(with event: NSEvent) { if options.controlSource { onSourceEvent?(event) } }
    override func mouseMoved(with event: NSEvent) {
        onPointerActivity?()
        if options.controlSource { onSourceEvent?(event) }
    }
    override func mouseEntered(with event: NSEvent) { onPointerActivity?() }
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }
}

/// Small controls over the bottom of a copy. They appear on click, tap or hover and hide
/// again after a few seconds; as an overlay they never change the viewer's drawable size.
final class ViewerOverlay: NSVisualEffectView {
    var onCommand: ((ViewerCommand) -> Void)?
    var onMore: ((NSView) -> Void)?
    private(set) var buttons: [ViewerCommand: NSButton] = [:]
    private var more: NSButton!

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        setAccessibilityLabel("Viewer Controls")
        setAccessibilityRole(.group)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        func button(_ title: String, symbol: String?, label: String, action: Selector) -> NSButton {
            let button = FirstMouseButton(title: title, target: self, action: action)
            button.bezelStyle = .recessed
            button.controlSize = .large
            button.font = .systemFont(ofSize: 13, weight: .semibold)
            button.contentTintColor = .white
            button.setAccessibilityLabel(label)
            button.toolTip = label
            if let symbol { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label); button.imagePosition = .imageOnly }
            button.heightAnchor.constraint(equalToConstant: 40).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            stack.addArrangedSubview(button)
            return button
        }
        let specifications: [(ViewerCommand, String, String?, String)] = [
            (.fit, "Fit", nil, "Fit or Fill"),
            (.grid, "", "grid", "Rule of Thirds Grid"),
            (.controlSource, "Control", nil, "Control Source"),
            (.fillDisplay, "", "arrow.up.left.and.arrow.down.right", "Fill Display")
        ]
        for (command, title, symbol, label) in specifications {
            let control = button(title, symbol: symbol, label: label, action: #selector(clicked(_:)))
            control.tag = command.rawValue
            buttons[command] = control
        }
        more = button("", symbol: "ellipsis", label: "More Options", action: #selector(showMore(_:)))
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(options: MirrorOptions, fillingDisplay: Bool) {
        buttons[.fit]?.title = options.mode == .fit ? "Fit" : "Fill"
        buttons[.grid]?.contentTintColor = options.showGrid ? .systemTeal : .white
        buttons[.controlSource]?.contentTintColor = options.controlSource ? .systemTeal : .white
        buttons[.controlSource]?.title = options.controlSource ? "Control On" : "Control"
        buttons[.controlSource]?.setAccessibilityValue(options.controlSource ? "On" : "Off")
        buttons[.fillDisplay]?.image = NSImage(systemSymbolName: fillingDisplay ? "arrow.down.right.and.arrow.up.left"
                                                                                : "arrow.up.left.and.arrow.down.right",
                                               accessibilityDescription: fillingDisplay ? "Exit Fill Display" : "Fill Display")
        buttons[.fillDisplay]?.toolTip = fillingDisplay ? "Exit Fill Display (or double-click)" : "Fill Display (or double-click)"
    }

    @objc private func clicked(_ sender: NSButton) {
        guard let command = ViewerCommand(rawValue: sender.tag) else { return }
        onCommand?(command)
    }
    @objc private func showMore(_ sender: NSButton) { onMore?(sender) }
}

final class MirrorWindowController: NSWindowController, NSWindowDelegate, NSMenuDelegate {
    let id = UUID()
    let sourceID: CGWindowID
    let options = MirrorOptions()
    let trimModel: TrimModel
    let surface: MirrorSurface
    let overlay = ViewerOverlay()
    let mouseControl: SourceMouseControl
    var onClose: ((UUID) -> Void)?
    var onDuplicate: (() -> Void)?
    var onRequestFrame: (() -> CapturedFrame?)?
    var onActivityChange: (() -> Void)?
    /// Called when the trim panel closes, so focus can go back to the source app.
    var onTrimFinished: (() -> Void)?
    private let status = NSTextField(wrappingLabelWithString: "Connecting to window…")
    private var trimPanel: NSPanel?
    private var observation: Any?
    private var screenObserver: NSObjectProtocol?
    private var trimCloseObserver: NSObjectProtocol?
    private var hideOverlay: Timer?
    private var hasImage = false
    private var optionsUpdatePending = false
    private(set) var acceptedFrames = 0
    private var closed = false
    private let sequence: Int
    private var windowed: (frame: NSRect, style: NSWindow.StyleMask, level: NSWindow.Level)?
    var isFillingDisplay: Bool { windowed != nil }
    var wantsLiveFrames: Bool {
        !closed && window?.isVisible == true && window?.isMiniaturized != true &&
            window?.occlusionState.contains(.visible) == true
    }

    init(sourceID: CGWindowID, title: String, sequence: Int, engine: RenderEngine, trimModel: TrimModel,
         sourceProcessID: pid_t? = nil) {
        self.sourceID = sourceID; self.sequence = sequence; self.trimModel = trimModel
        mouseControl = SourceMouseControl(windowID: sourceID, processID: sourceProcessID)
        surface = MirrorSurface(engine: engine, options: options)
        let window = ViewerPanel(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "\(title) · Copy \(sequence)"
        window.minSize = NSSize(width: 320, height: 180)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isFloatingPanel = false
        window.collectionBehavior = [.managed, .fullScreenAuxiliary]
        window.tabbingMode = .disallowed
        window.delegate = self
        window.contentView = surface
        surface.onClick = { [weak self] in self?.revealOverlay() }
        surface.onPointerActivity = { [weak self] in self?.revealOverlay() }
        surface.onDoubleClick = { [weak self] in self?.toggleFillDisplay() }
        surface.onMenu = { [weak self] in self?.makeMenu() ?? NSMenu() }
        surface.shouldRender = { [weak self] in self?.wantsLiveFrames ?? false }
        surface.onSourceEvent = { [weak self] in self?.sendToSource($0) }
        status.font = .systemFont(ofSize: 15, weight: .medium)
        status.textColor = .white
        status.alignment = .center
        status.maximumNumberOfLines = 4
        status.backgroundColor = .black.withAlphaComponent(0.85)
        status.drawsBackground = true
        status.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(status)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isHidden = true
        overlay.onCommand = { [weak self] in self?.perform($0); self?.revealOverlay() }
        overlay.onMore = { [weak self] anchor in
            guard let self else { return }
            self.makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 4), in: anchor)
        }
        surface.addSubview(overlay)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: surface.widthAnchor, multiplier: 0.8),
            overlay.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            overlay.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -16)
        ])
        observation = options.objectWillChange.sink { [weak self] in
            guard let self, !self.optionsUpdatePending else { return }
            self.optionsUpdatePending = true
            DispatchQueue.main.async {
                self.optionsUpdatePending = false
                guard !self.closed else { return }
                self.surface.needsDisplay = true
                self.updateControls()
            }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitToScreenIfFilling() }
        }
        window.center()
        window.setFrameOrigin(NSPoint(x: window.frame.minX + CGFloat((sequence - 1) % 6) * 24,
                                      y: window.frame.minY - CGFloat((sequence - 1) % 6) * 24))
        updateControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        for observer in [screenObserver, trimCloseObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(observer) }
    }

    func receive(_ frame: CapturedFrame) {
        guard wantsLiveFrames else { return }
        acceptedFrames += 1
        hasImage = true
        surface.update(frame)
        status.isHidden = true
    }

    func showStatus(_ message: String?) {
        if message != nil { hasImage = false; mouseControl.cancel() }
        status.stringValue = message ?? ""
        status.isHidden = message == nil
    }

    private func revealOverlay() {
        overlay.isHidden = false
        hideOverlay?.invalidate()
        hideOverlay = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.overlay.isHidden = true }
        }
    }

    func windowDidChangeScreen(_ notification: Notification) { fitToScreenIfFilling(); visibilityChanged() }
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
        onActivityChange?()
    }

    func releaseLiveFrame() {
        mouseControl.cancel()
        hasImage = false
        surface.discardLiveFrame()
    }

    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        hideOverlay?.invalidate()
        trimPanel?.close()
        releaseLiveFrame()
        onClose?(id)
    }

    // MARK: Fill Display

    /// Covers the copy's whole display, menu bar included, without a fullscreen Space.
    /// Native fullscreen would make DualLink the active app and take Capture One's shortcuts.
    func toggleFillDisplay() {
        guard let window else { return }
        if let windowed {
            window.styleMask = windowed.style
            window.level = windowed.level
            window.hasShadow = true
            window.setFrame(windowed.frame, display: true)
            self.windowed = nil
        } else {
            guard let screen = window.screen ?? NSScreen.main else { return }
            windowed = (window.frame, window.styleMask, window.level)
            window.styleMask = [.borderless, .nonactivatingPanel]
            window.level = .statusBar
            window.hasShadow = false
            window.setFrame(screen.frame, display: true)
        }
        surface.needsDisplay = true
        updateControls()
    }

    private func fitToScreenIfFilling() {
        guard isFillingDisplay, let window, let screen = window.screen ?? NSScreen.main,
              window.frame != screen.frame else { return }
        window.setFrame(screen.frame, display: true)
    }

    // MARK: Commands and menus

    private func item(_ title: String, _ action: Selector, value: Any? = nil, checked: Bool = false,
                      enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
        item.target = self; item.representedObject = value; item.state = checked ? .on : .off
        return item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for mode in ImageFit.allCases {
            menu.addItem(item(mode.rawValue, #selector(setFit(_:)), value: mode.rawValue, checked: options.mode == mode))
        }
        menu.addItem(item("Rule of Thirds Grid", #selector(toggleGrid), checked: options.showGrid))
        menu.addItem(item(isFillingDisplay ? "Exit Fill Display" : "Fill Display", #selector(fillDisplay)))
        menu.addItem(item("Control Source", #selector(toggleSourceControl), checked: options.controlSource))
        menu.addItem(.separator())
        menu.addItem(item("Trim \(trimModel.appName) Toolbar…", #selector(showTrim)))
        menu.addItem(item("Reset Trim", #selector(resetTrim), enabled: trimModel.trim != .none))
        menu.addItem(.separator())
        let displays = NSMenu()
        for screen in NSScreen.screens {
            displays.addItem(item(screen.localizedName, #selector(moveToScreen(_:)), value: screen.displayID,
                                  checked: screen == window?.screen))
        }
        let move = NSMenuItem(title: "Move to Display", action: nil, keyEquivalent: "")
        move.submenu = displays; menu.addItem(move)
        menu.addItem(item("Keep on Top", #selector(toggleFloating), checked: (windowed?.level ?? window?.level) == .floating,
                          enabled: !isFillingDisplay))
        menu.addItem(.separator())
        menu.addItem(item("Create Another Copy", #selector(duplicate), enabled: onDuplicate != nil))
        menu.addItem(item("Close Copy", #selector(closeCopy)))
        return menu
    }

    func perform(_ command: ViewerCommand) {
        switch command {
        case .fit: options.mode = options.mode == .fit ? .fill : .fit // The overlay's Fit button toggles.
        case .fill: options.mode = .fill
        case .grid: toggleGrid()
        case .fillDisplay: toggleFillDisplay()
        case .trim: showTrim()
        case .resetTrim: resetTrim()
        case .keepOnTop: toggleFloating()
        case .duplicate: duplicate()
        case .controlSource: toggleSourceControl()
        }
    }

    private func updateControls() {
        overlay.update(options: options, fillingDisplay: isFillingDisplay)
    }
    @objc private func setFit(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ImageFit(rawValue: raw) else { return }
        options.mode = mode
    }
    @objc private func toggleGrid() { options.showGrid.toggle() }
    @objc private func toggleSourceControl() {
        guard SourceMouseControl.isSupported else {
            let alert = NSAlert(); alert.messageText = "Mouse control is unavailable on this macOS version."
            alert.runModal(); return
        }
        options.controlSource.toggle()
        if !options.controlSource { mouseControl.cancel() }
        else if !SourceMouseControl.hasPermission { SourceMouseControl.explainPermission() }
        updateControls()
    }

    private func sendToSource(_ event: NSEvent) {
        guard hasImage, let frame = surface.capturedFrame, wantsLiveFrames else { mouseControl.cancel(); return }
        if !SourceMouseControl.hasPermission,
           mouseControl.processID != ProcessInfo.processInfo.processIdentifier {
            if event.type == .leftMouseDown || event.type == .rightMouseDown { SourceMouseControl.explainPermission() }
            return
        }
        var point = surface.convert(event.locationInWindow, from: nil)
        if surface.isFlipped { point.y = surface.bounds.height - point.y }
        guard let mapped = ImageGeometry.sourcePoint(point, viewerSize: surface.bounds.size,
                                                      imageSize: frame.nativeSize, sourceRect: frame.sourceRect,
                                                      mode: options.mode, clamp: mouseControl.isDragging) else { return }
        mouseControl.send(event, point: mapped, sourceSize: frame.sourceSize)
    }
    @objc private func fillDisplay() { toggleFillDisplay() }
    @objc private func toggleFloating() {
        guard !isFillingDisplay else { return }
        window?.level = window?.level == .floating ? .normal : .floating
    }
    @objc private func duplicate() { onDuplicate?() }
    @objc private func closeCopy() { window?.close() }
    @objc private func resetTrim() { trimModel.trim = .none }
    @objc private func moveToScreen(_ sender: NSMenuItem) {
        // Match by display ID: the screen list may have changed since the menu opened.
        guard let id = sender.representedObject as? CGDirectDisplayID,
              let screen = NSScreen.screens.first(where: { $0.displayID == id }), let window else { return }
        window.setFrame(isFillingDisplay ? screen.frame : screen.visibleFrame, display: true, animate: !isFillingDisplay)
    }
    /// The one place DualLink comes to the front: sliders need a key window.
    /// Closing the panel hands focus back to the source app.
    @objc private func showTrim() {
        if let trimPanel { NSApp.activate(); trimPanel.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 360),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Trim \(trimModel.appName)"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar + 1 // Above a copy that is filling its display.
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: TrimEditor(model: trimModel, onDone: { [weak panel] in panel?.close() }))
        trimCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTrimFinished?() }
        }
        if let screen = window?.screen {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 190, y: screen.visibleFrame.midY - 180))
        } else { panel.center() }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
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
    var onDone: () -> Void
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
            HStack {
                Button("Reset Trim") { model.trim = .none }
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 380, height: 360)
    }
}
