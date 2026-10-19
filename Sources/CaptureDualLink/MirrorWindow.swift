import AppKit
import SwiftUI
import MetalKit
import CoreImage
import DualLinkCore

enum ViewerCommand: Int {
    case fit, fill, actualPixels, crop, resetCrop, matchAspect, pixelSize
    case fullscreen, keepOnTop, pixelInfo, pause, duplicate
    case grid, zoomIn, zoomOut, resetZoom
    case quickControls
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
            NSApp.activate(ignoringOtherApps: true)
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
    @Published var crop: ImageCrop = .none
    @Published var showInfo = true
    @Published var paused = false
    @Published var showGrid = false
    @Published var viewport: ImageViewport = .identity
    @Published var showQuickControls = true

    func setFit(_ mode: ImageFit) {
        self.mode = mode
        viewport = .identity
    }
}

/// One shared GPU context for every viewer, with no video encoding or disk writes.
final class RenderEngine {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let context: CIContext
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device; self.queue = queue
        queue.label = "Capture DualLink Rendering"
        context = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false, .name: "Capture DualLink"])
    }

    struct Snapshot {
        let image: CIImage
        let texture: MTLTexture
    }

    /// One full-resolution GPU copy on Freeze. No camera buffers are retained by a paused viewer.
    func snapshot(_ image: CIImage) -> Snapshot? {
        let size = image.extent.size
        guard size.width > 0, size.height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: Int(size.width), height: Int(size.height), mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer(),
              let copy = CIImage(mtlTexture: texture, options: [.colorSpace: colorSpace]) else { return nil }
        command.label = "Freeze image at native pixels"
        context.render(image, to: texture, commandBuffer: command,
                       bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        command.addCompletedHandler { [image] _ in withExtendedLifetime(image) {} }
        command.commit()
        return Snapshot(image: copy, texture: texture)
    }
}

final class MirrorSurface: MTKView, MTKViewDelegate, NSGestureRecognizerDelegate {
    let engine: RenderEngine
    let options: MirrorOptions
    var frameImage: CIImage?
    var onDoubleClick: (() -> Void)?
    var onMenu: (() -> NSMenu)?
    var onSizeChange: (() -> Void)?
    var onFreeze: (() -> Void)?
    var onGrid: (() -> Void)?
    var shouldRender: (() -> Bool)?
    private let inFlight = DispatchSemaphore(value: 2)
    private var redrawPending = false
    private(set) var submittedFrames = 0
    private(set) var droppedRenders = 0
    private(set) var totalGPUTime: Double = 0
    private(set) var completedFrames = 0
    private var dragPoint: CGPoint?
    private var gridCache: (placement: CGRect, size: CGSize, lineWidth: CGFloat, image: CIImage)?

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
        // Touch recognizers are additive: mouse/Pencil and older trackpad events keep their existing path.
        if #available(macOS 27, *) {
            let pan = NSPanGestureRecognizer(target: self, action: #selector(touchPan(_:)))
            let pinch = NSMagnificationGestureRecognizer(target: self, action: #selector(touchPinch(_:)))
            let doubleTap = NSClickGestureRecognizer(target: self, action: #selector(touchDoubleTap(_:)))
            doubleTap.numberOfClicksRequired = 2
            for recognizer in [pan, pinch, doubleTap] as [NSGestureRecognizer] {
                recognizer.allowedTouchTypes = .direct
                recognizer.delegate = self
                addGestureRecognizer(recognizer)
            }
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ image: CIImage) {
        guard !options.paused else { return }
        frameImage = image
        needsDisplay = true
    }

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
        submittedFrames += 1
        command.commit()
    }

    func discardLiveFrame() { frameImage = nil; redrawPending = false }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        false // Direct Sidecar touches only; don't also consume mouse/Pencil/trackpad events.
    }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldReceive touch: NSTouch) -> Bool {
        touch.type == .direct
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        let hit = hitTest(gestureRecognizer.location(in: self))
        return hit === self && frameImage != nil
    }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        gestureRecognizers.contains(gestureRecognizer) && gestureRecognizers.contains(otherGestureRecognizer)
    }
    @objc private func touchPan(_ recognizer: NSPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        let scale = window?.backingScaleFactor ?? 1
        pan(by: CGPoint(x: translation.x * scale, y: translation.y * scale))
        recognizer.setTranslation(.zero, in: self)
    }
    @objc private func touchPinch(_ recognizer: NSMagnificationGestureRecognizer) {
        zoom(by: max(0.05, 1 + recognizer.magnification), anchor: convertToBacking(recognizer.location(in: self)))
        recognizer.magnification = 0
    }
    @objc private func touchDoubleTap(_ recognizer: NSClickGestureRecognizer) { onDoubleClick?() }

    func renderedImage(size: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        let black = CIImage(color: .black).cropped(to: bounds)
        var output = black
        if let frameImage {
            let crop = options.crop.rect(in: frameImage.extent.size)
            let image = frameImage.cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            let placement = ImageGeometry.placement(source: crop.size, destination: size, mode: options.mode,
                                                     viewport: options.viewport)
            if placement.width > 0, placement.height > 0 {
                let transform = CGAffineTransform(a: placement.width / crop.width, b: 0,
                                                 c: 0, d: placement.height / crop.height,
                                                 tx: placement.minX, ty: placement.minY)
                output = image.transformed(by: transform).composited(over: black).cropped(to: bounds)
                if options.showGrid {
                    output = gridImage(placement: placement, size: size).composited(over: output).cropped(to: bounds)
                }
            }
        }
        return output
    }

    /// Four procedural lines, cached until geometry changes. No per-frame CPU bitmap drawing.
    private func gridImage(placement: CGRect, size: CGSize) -> CIImage {
        let width = max(1, window?.backingScaleFactor ?? 1)
        if let cache = gridCache, cache.placement == placement, cache.size == size, cache.lineWidth == width {
            return cache.image
        }
        let bounds = CGRect(origin: .zero, size: size)
        var grid = CIImage.empty()
        for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
            for vertical in [true, false] {
                let center = vertical ? placement.minX + placement.width * fraction : placement.minY + placement.height * fraction
                for (thickness, color) in [(width * 3, CIColor(red: 0, green: 0, blue: 0, alpha: 0.45)),
                                           (width, CIColor(red: 1, green: 1, blue: 1, alpha: 0.7))] {
                    let line = vertical ? CGRect(x: center - thickness / 2, y: placement.minY, width: thickness, height: placement.height)
                                        : CGRect(x: placement.minX, y: center - thickness / 2, width: placement.width, height: thickness)
                    let clipped = line.intersection(bounds)
                    if !clipped.isEmpty { grid = CIImage(color: color).cropped(to: clipped).composited(over: grid) }
                }
            }
        }
        grid = grid.cropped(to: bounds)
        gridCache = (placement, size, width, grid)
        return grid
    }

    func zoom(by factor: CGFloat, anchor: CGPoint? = nil) {
        guard let image = frameImage else { return }
        options.viewport = options.viewport.zoomed(by: factor, source: options.crop.rect(in: image.extent.size).size,
                                                   destination: drawableSize, mode: options.mode, anchor: anchor)
    }

    func pan(by delta: CGPoint) {
        guard let image = frameImage else { return }
        options.viewport = options.viewport.panned(by: delta, source: options.crop.rect(in: image.extent.size).size,
                                                   destination: drawableSize, mode: options.mode)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { onSizeChange?() }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Sidecar may have a different backing scale from the MacBook's display.
        drawableSize = convertToBacking(bounds).size
        needsDisplay = true
        onSizeChange?()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { dragPoint = nil; onDoubleClick?() }
        else { dragPoint = convertToBacking(convert(event.locationInWindow, from: nil)) }
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convertToBacking(convert(event.locationInWindow, from: nil))
        if let previous = dragPoint { pan(by: CGPoint(x: point.x - previous.x, y: point.y - previous.y)) }
        dragPoint = point
    }
    override func mouseUp(with event: NSEvent) { dragPoint = nil }
    override func magnify(with event: NSEvent) {
        zoom(by: max(0.05, 1 + event.magnification), anchor: convertToBacking(convert(event.locationInWindow, from: nil)))
    }
    override func scrollWheel(with event: NSEvent) {
        let scale = (window?.backingScaleFactor ?? 1) * (event.hasPreciseScrollingDeltas ? 1 : 10)
        pan(by: CGPoint(x: event.scrollingDeltaX * scale, y: event.scrollingDeltaY * scale))
    }
    override func changeMode(with event: NSEvent) { onGrid?() }
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if event.keyCode == 53, window?.styleMask.contains(.fullScreen) == true {
            onDoubleClick?()
        } else if event.charactersIgnoringModifiers == " ", modifiers.isEmpty {
            onFreeze?()
        } else { super.keyDown(with: event) }
    }
    override var acceptsFirstResponder: Bool { true }
}

final class MirrorWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSTouchBarDelegate, NSMenuDelegate, NSMenuItemValidation {
    let id = UUID()
    let sourceID: CGWindowID
    let options = MirrorOptions()
    let surface: MirrorSurface
    let floatingControls = ViewerControls()
    var onClose: ((UUID) -> Void)?
    var onDuplicate: (() -> Void)?
    var onFullscreenStateChange: ((Bool) -> Void)?
    var onRequestFrame: (() -> CapturedFrame?)?
    var onActivityChange: (() -> Void)?
    private let info = NSTextField(labelWithString: "Waiting for source… · Right-click for options")
    private let status = NSTextField(wrappingLabelWithString: "Connecting to window…")
    private var cropPanel: NSPanel?
    private var observation: Any?
    private var currentImage: CIImage?
    private var frozenImage: RenderEngine.Snapshot?
    private var sourceSize: CGSize = .zero
    private var optionsUpdatePending = false
    private var lastControls: ControlState?
    private(set) var infoRefreshCount = 0
    private(set) var acceptedFrames = 0
    private(set) var suppressedFrames = 0
    private var lastInfo = ""
    private var infoBottom: NSLayoutConstraint?
    private var closed = false
    private let sequence: Int
    private var fitControl: NSToolbarItemGroup?
    private var pauseControl: NSToolbarItem?
    private var fullscreenControl: NSToolbarItem?
    private var gridControl: NSToolbarItem?
    private var zoomControl: NSSegmentedControl?
    private var touchGrid: NSButton?
    private var touchZoomOut: NSButton?
    private var touchFit: NSButton?
    private var touchZoomIn: NSButton?
    private var touchPause: NSButton?
    private var levelBeforeFullscreen: NSWindow.Level?
    private var transitioningFullscreen = false
    private var fullscreenInfoVisible = false
    private(set) var fullscreenPresentationOptions: NSApplication.PresentationOptions = []
    private var pixelInfoVisible: Bool {
        window?.styleMask.contains(.fullScreen) == true ? fullscreenInfoVisible : options.showInfo
    }
    var wantsLiveFrames: Bool {
        !closed && !options.paused && (transitioningFullscreen ||
            (window?.isVisible == true && window?.isMiniaturized != true && window?.occlusionState.contains(.visible) == true))
    }
    var hasOwnedFrozenImage: Bool { frozenImage != nil }

    private struct ControlState: Equatable {
        let mode: ImageFit
        let zoom: CGFloat
        let basePosition: Bool
        let grid: Bool
        let paused: Bool
        let quick: Bool
        let image: Bool
        let fullscreen: Bool
        let transitioning: Bool
    }
    private static let fitID = NSToolbarItem.Identifier("duallink.fit")
    private static let cropID = NSToolbarItem.Identifier("duallink.crop")
    private static let pauseID = NSToolbarItem.Identifier("duallink.pause")
    private static let optionsID = NSToolbarItem.Identifier("duallink.options")
    private static let fullscreenID = NSToolbarItem.Identifier("duallink.fullscreen")
    private static let gridID = NSToolbarItem.Identifier("duallink.grid")
    private static let zoomID = NSToolbarItem.Identifier("duallink.zoom")
    static let touchGridID = NSTouchBarItem.Identifier("duallink.touch.grid")
    static let touchZoomID = NSTouchBarItem.Identifier("duallink.touch.zoom")
    static let touchZoomOutID = NSTouchBarItem.Identifier("duallink.touch.zoomOut")
    static let touchFitID = NSTouchBarItem.Identifier("duallink.touch.fit")
    static let touchZoomInID = NSTouchBarItem.Identifier("duallink.touch.zoomIn")
    static let touchPauseID = NSTouchBarItem.Identifier("duallink.touch.pause")

    init(sourceID: CGWindowID, title: String, sequence: Int, engine: RenderEngine) {
        self.sourceID = sourceID; self.sequence = sequence
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
        surface.onFreeze = { [weak self] in self?.togglePaused() }
        surface.onGrid = { [weak self] in self?.toggleGrid() }
        surface.onMenu = { [weak self] in self?.makeMenu() ?? NSMenu() }
        surface.shouldRender = { [weak self] in
            guard let self else { return false }
            return !self.closed && self.window?.isVisible == true && self.window?.isMiniaturized != true &&
                self.window?.occlusionState.contains(.visible) == true
        }
        surface.onSizeChange = { [weak self] in
            DispatchQueue.main.async { self?.updateInfo() }
        }
        info.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        info.textColor = .white.withAlphaComponent(0.8)
        info.backgroundColor = .black.withAlphaComponent(0.75)
        info.drawsBackground = true
        info.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 15, weight: .medium)
        status.textColor = .white
        status.alignment = .center
        status.maximumNumberOfLines = 4
        status.backgroundColor = .black.withAlphaComponent(0.85)
        status.drawsBackground = true
        for label in [info, status] {
            label.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(label)
        }
        floatingControls.translatesAutoresizingMaskIntoConstraints = false
        floatingControls.onCommand = { [weak self] in self?.perform($0) }
        surface.addSubview(floatingControls)
        let infoBottom = info.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -10)
        self.infoBottom = infoBottom
        NSLayoutConstraint.activate([
            info.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 12),
            infoBottom,
            info.trailingAnchor.constraint(lessThanOrEqualTo: surface.trailingAnchor, constant: -12),
            status.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: surface.widthAnchor, multiplier: 0.8),
            floatingControls.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            floatingControls.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -16),
            floatingControls.leadingAnchor.constraint(greaterThanOrEqualTo: surface.leadingAnchor, constant: 8),
            floatingControls.trailingAnchor.constraint(lessThanOrEqualTo: surface.trailingAnchor, constant: -8)
        ])
        observation = options.objectWillChange.sink { [weak self] in
            guard let self, !self.optionsUpdatePending else { return }
            self.optionsUpdatePending = true
            DispatchQueue.main.async {
                self.optionsUpdatePending = false
                guard !self.closed else { return }
                self.surface.needsDisplay = true
                self.updateInfo()
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
        guard wantsLiveFrames else { suppressedFrames += 1; return }
        acceptedFrames += 1
        let firstFrame = currentImage == nil
        let resized = sourceSize != frame.image.extent.size
        sourceSize = frame.image.extent.size
        frozenImage = nil
        currentImage = frame.image
        surface.update(frame.image)
        status.isHidden = true
        if resized || firstFrame { updateInfo() }
        if firstFrame { updateToolbar() }
    }

    func showStatus(_ message: String?) {
        status.stringValue = message ?? ""
        status.isHidden = message == nil
    }

    func windowDidChangeScreen(_ notification: Notification) { updateInfo(); visibilityChanged() }
    func windowDidResize(_ notification: Notification) { updateInfo() }
    func windowDidBecomeKey(_ notification: Notification) { window?.makeFirstResponder(surface); visibilityChanged() }
    func windowDidChangeOcclusionState(_ notification: Notification) { visibilityChanged() }
    func windowDidMiniaturize(_ notification: Notification) { visibilityChanged() }
    func windowDidDeminiaturize(_ notification: Notification) { visibilityChanged() }

    private func visibilityChanged() {
        guard !closed else { return }
        if wantsLiveFrames {
            if let frame = onRequestFrame?() { receive(frame) }
        } else if !options.paused {
            currentImage = nil
            frozenImage = nil
            surface.discardLiveFrame()
        }
        updateToolbar()
        onActivityChange?()
    }

    func releaseLiveFrame() {
        guard !options.paused else { return }
        currentImage = nil; frozenImage = nil
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
        fullscreenInfoVisible = false
        levelBeforeFullscreen = window?.level
        window?.level = .normal
        FullscreenMenus.shared.enter(id)
    }
    func windowDidEnterFullScreen(_ notification: Notification) {
        transitioningFullscreen = false
        updateToolbar(); updateInfo()
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
        updateToolbar(); updateInfo()
    }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        FullscreenMenus.shared.leave(id)
        cropPanel?.close()
        surface.discardLiveFrame(); currentImage = nil; frozenImage = nil
        onClose?(id)
    }

    private func updateInfo() {
        // Pixel information is independent of the overlay and the native toolbar.
        info.isHidden = !pixelInfoVisible
        guard pixelInfoVisible else { return }
        infoRefreshCount += 1
        let source = options.crop.rect(in: sourceSize).size
        let target = surface.convertToBacking(surface.bounds).size
        let mode = options.mode == .actualPixels ? "1:1" : (options.mode == .fit ? "Fit" : "Fill")
        let scale = window?.backingScaleFactor ?? 1
        let zoom = options.viewport.zoom > 1 ? " · \(zoomLabel) zoom" : ""
        let text = " \(Int(source.width)) × \(Int(source.height)) → \(Int(target.width)) × \(Int(target.height)) px · \(mode)\(zoom) · \(Int(scale))× display\(options.paused ? " · Frozen" : "") "
        if text != lastInfo { info.stringValue = text; lastInfo = text }
    }

    private func item(_ title: String, _ action: Selector, value: Any? = nil, checked: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; item.representedObject = value; item.state = checked ? .on : .off
        return item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for mode in ImageFit.allCases {
            menu.addItem(item(mode.rawValue, #selector(setFit(_:)), value: mode.rawValue,
                              checked: options.mode == mode && options.viewport == .identity))
        }
        menu.addItem(.separator())
        menu.addItem(item("Rule of Thirds Grid", #selector(toggleGrid), checked: options.showGrid))
        menu.addItem(item("Zoom In", #selector(zoomIn)))
        menu.addItem(item("Zoom Out", #selector(zoomOut)))
        menu.addItem(item("Reset Zoom", #selector(resetZoom)))
        menu.addItem(item("Show Floating Controls", #selector(toggleQuickControls), checked: options.showQuickControls))
        menu.addItem(.separator())
        menu.addItem(item("Crop Image…", #selector(showCrop)))
        menu.addItem(item("Reset Crop", #selector(resetCrop)))
        menu.addItem(item("Match Source Aspect Ratio", #selector(matchAspect)))
        menu.addItem(item("Set Viewer Size in Pixels…", #selector(setPixelSize)))
        menu.addItem(.separator())
        let displays = NSMenu()
        for (index, screen) in NSScreen.screens.enumerated() {
            displays.addItem(item("\(index + 1). \(screen.localizedName)", #selector(moveToScreen(_:)), value: index))
        }
        let move = NSMenuItem(title: "Move to Display", action: nil, keyEquivalent: "")
        move.submenu = displays; menu.addItem(move)
        menu.addItem(item(window?.styleMask.contains(.fullScreen) == true ? "Exit Full Screen" : "Enter Full Screen", #selector(fullscreen)))
        menu.addItem(item("Keep on Top", #selector(toggleFloating), checked: window?.level == .floating))
        menu.addItem(item("Show Pixel Information", #selector(toggleInfo), checked: pixelInfoVisible))
        menu.addItem(item(options.paused ? "Resume" : "Freeze Image", #selector(togglePaused)))
        menu.addItem(.separator())
        menu.addItem(item("Create Another Copy", #selector(duplicate)))
        menu.addItem(item("Close Copy", #selector(closeCopy)))
        return menu
    }

    func perform(_ command: ViewerCommand) {
        switch command {
        case .fit: options.setFit(.fit)
        case .fill: options.setFit(.fill)
        case .actualPixels: options.setFit(.actualPixels)
        case .crop: showCrop()
        case .resetCrop: resetCrop()
        case .matchAspect: matchAspect()
        case .pixelSize: setPixelSize()
        case .fullscreen: fullscreen()
        case .keepOnTop: toggleFloating()
        case .pixelInfo: toggleInfo()
        case .pause: togglePaused()
        case .duplicate: duplicate()
        case .grid: toggleGrid()
        case .zoomIn: zoomIn()
        case .zoomOut: zoomOut()
        case .resetZoom: resetZoom()
        case .quickControls: toggleQuickControls()
        }
    }

    func validate(_ item: NSMenuItem, command: ViewerCommand) -> Bool {
        item.state = .off
        switch command {
        case .fit: item.state = options.mode == .fit && options.viewport == .identity ? .on : .off
        case .fill: item.state = options.mode == .fill && options.viewport == .identity ? .on : .off
        case .actualPixels: item.state = options.mode == .actualPixels && options.viewport == .identity ? .on : .off
        case .grid: item.state = options.showGrid ? .on : .off
        case .quickControls: item.state = options.showQuickControls ? .on : .off
        case .zoomIn: return currentImage != nil && options.viewport.zoom < 8
        case .zoomOut: return currentImage != nil && options.viewport.zoom > 1
        case .resetZoom: return currentImage != nil && options.viewport != .identity
        case .pause:
            item.title = options.paused ? "Resume Live View" : "Freeze Image"
            return options.paused || currentImage != nil
        case .fullscreen:
            item.title = window?.styleMask.contains(.fullScreen) == true ? "Exit Full Screen" : "Enter Full Screen"
            return !transitioningFullscreen
        case .pixelInfo: item.state = pixelInfoVisible ? .on : .off
        case .keepOnTop:
            item.state = window?.level == .floating ? .on : .off
            return window?.styleMask.contains(.fullScreen) != true
        case .pixelSize, .matchAspect:
            return currentImage != nil && window?.styleMask.contains(.fullScreen) != true
        case .crop, .resetCrop: return currentImage != nil
        case .duplicate: return onDuplicate != nil
        }
        return true
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.fitID, Self.zoomID, .flexibleSpace, Self.gridID, Self.cropID, Self.pauseID, Self.optionsID, Self.fullscreenID]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == Self.fitID {
            let group = NSToolbarItemGroup(itemIdentifier: identifier, titles: ["Fit", "Fill", "1:1"],
                                          selectionMode: .selectOne, labels: nil, target: self,
                                          action: #selector(changeToolbarFit(_:)))
            group.label = "Image Fit"
            group.toolTip = "Fit: entire image · Fill: crop to window · 1:1: actual pixels (⌘1 / ⌘2 / ⌘3)"
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
        if identifier == Self.zoomID {
            let item = NSToolbarItem(itemIdentifier: identifier)
            let control = NSSegmentedControl(labels: ["−", zoomLabel, "+"], trackingMode: .momentary,
                                             target: self, action: #selector(changeToolbarZoom(_:)))
            control.setWidth(28, forSegment: 0); control.setWidth(48, forSegment: 1); control.setWidth(28, forSegment: 2)
            control.setAccessibilityLabel("Viewer zoom")
            control.toolTip = "Zoom out / Reset zoom / Zoom in. Drag the image to pan."
            zoomControl = control
            item.view = control; item.label = "Zoom"; item.visibilityPriority = .high
            return item
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
        case Self.cropID:
            item.label = "Crop Image"; item.toolTip = "Crop this copy (⌘K)"
            item.image = NSImage(systemSymbolName: "crop", accessibilityDescription: "Crop Image")
            item.action = #selector(showCrop)
        case Self.pauseID:
            pauseControl = item
            item.label = "Freeze Image"; item.toolTip = "Freeze / Resume (Space)"
            item.image = NSImage(systemSymbolName: "pause", accessibilityDescription: "Freeze Image")
            item.action = #selector(togglePaused)
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
        case #selector(togglePaused): return options.paused || currentImage != nil
        case #selector(zoomIn): return currentImage != nil && options.viewport.zoom < 8
        case #selector(zoomOut): return currentImage != nil && options.viewport.zoom > 1
        case #selector(resetZoom): return currentImage != nil && options.viewport != .identity
        case #selector(setPixelSize), #selector(matchAspect):
            return currentImage != nil && window?.styleMask.contains(.fullScreen) != true
        case #selector(showCrop), #selector(resetCrop): return currentImage != nil
        case #selector(fullscreen): return !transitioningFullscreen
        case #selector(toggleFloating): return window?.styleMask.contains(.fullScreen) != true
        case #selector(duplicate): return onDuplicate != nil
        default: return true
        }
    }
    private func updateToolbar(force: Bool = false) {
        let state = ControlState(mode: options.mode, zoom: options.viewport.zoom,
            basePosition: options.viewport == .identity, grid: options.showGrid, paused: options.paused,
            quick: options.showQuickControls, image: currentImage != nil,
            fullscreen: window?.styleMask.contains(.fullScreen) == true, transitioning: transitioningFullscreen)
        guard force || state != lastControls else { return }
        lastControls = state
        // These are overlay-only changes: the Metal view's constraints and drawable size stay intact.
        floatingControls.isHidden = !options.showQuickControls
        floatingControls.update(options: options, hasImage: currentImage != nil)
        infoBottom?.constant = options.showQuickControls ? -80 : -10
        fitControl?.selectedIndex = options.viewport == .identity ? (ImageFit.allCases.firstIndex(of: options.mode) ?? 0) : -1
        zoomControl?.setLabel(zoomLabel, forSegment: 1)
        zoomControl?.setEnabled(currentImage != nil && options.viewport.zoom > 1, forSegment: 0)
        zoomControl?.setEnabled(currentImage != nil, forSegment: 1)
        zoomControl?.setEnabled(currentImage != nil && options.viewport.zoom < 8, forSegment: 2)
        gridControl?.image = NSImage(systemSymbolName: options.showGrid ? "grid.circle.fill" : "grid",
                                     accessibilityDescription: options.showGrid ? "Hide Grid" : "Show Grid")
        gridControl?.toolTip = options.showGrid ? "Hide grid for this copy (⌘G)" : "Show grid for this copy (⌘G)"
        touchGrid?.state = options.showGrid ? .on : .off
        touchGrid?.bezelColor = options.showGrid ? .systemTeal : nil
        touchZoomOut?.isEnabled = currentImage != nil && options.viewport.zoom > 1
        touchFit?.isEnabled = currentImage != nil
        touchZoomIn?.isEnabled = currentImage != nil && options.viewport.zoom < 8
        touchPause?.title = options.paused ? "Resume" : "Freeze"
        touchPause?.isEnabled = options.paused || currentImage != nil
        pauseControl?.isEnabled = options.paused || currentImage != nil
        pauseControl?.image = NSImage(systemSymbolName: options.paused ? "play" : "pause",
                                     accessibilityDescription: options.paused ? "Resume Live View" : "Freeze Image")
        pauseControl?.label = options.paused ? "Resume Live View" : "Freeze Image"
        let full = window?.styleMask.contains(.fullScreen) == true
        fullscreenControl?.image = NSImage(systemSymbolName: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                          accessibilityDescription: full ? "Exit Full Screen" : "Enter Full Screen")
        fullscreenControl?.toolTip = full ? "Exit Full Screen (Escape or ⌃⌘F)" : "Enter Full Screen (⌃⌘F)"
        fullscreenControl?.isEnabled = !transitioningFullscreen
    }
    @objc private func changeToolbarFit(_ sender: NSToolbarItemGroup) {
        guard ImageFit.allCases.indices.contains(sender.selectedIndex) else { return }
        options.setFit(ImageFit.allCases[sender.selectedIndex])
    }

    private var zoomLabel: String { Double(options.viewport.zoom).formatted(.number.precision(.fractionLength(0...2))) + "×" }
    @objc private func changeToolbarZoom(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: zoomOut()
        case 1: resetZoom()
        case 2: zoomIn()
        default: break
        }
    }
    @objc private func toggleGrid() { options.showGrid.toggle() }
    @objc private func zoomIn() { surface.zoom(by: 1.25) }
    @objc private func zoomOut() { surface.zoom(by: 1 / 1.25) }
    @objc private func resetZoom() { options.viewport = .identity }
    @objc private func toggleQuickControls() {
        options.showQuickControls.toggle()
        updateToolbar()
    }

    /// Sidecar exposes these native controls to fingers even on systems predating direct window touch.
    override func makeTouchBar() -> NSTouchBar? {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [.flexibleSpace, Self.touchGridID, Self.touchZoomID, Self.touchPauseID, .flexibleSpace]
        bar.principalItemIdentifier = Self.touchZoomID
        return bar
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        if identifier == Self.touchZoomID {
            let specifications: [(NSTouchBarItem.Identifier, String, String, Selector)] = [
                (Self.touchZoomOutID, "−", "Zoom Out", #selector(zoomOut)),
                (Self.touchFitID, "Fit", "Fit Image", #selector(touchFitImage)),
                (Self.touchZoomInID, "+", "Zoom In", #selector(zoomIn))
            ]
            let items = specifications.map { id, title, label, action -> NSTouchBarItem in
                let item = NSCustomTouchBarItem(identifier: id)
                let button = NSButton(title: title, target: self, action: action)
                button.setAccessibilityLabel(label)
                item.view = button
                if id == Self.touchZoomOutID { touchZoomOut = button }
                else if id == Self.touchFitID { touchFit = button }
                else { touchZoomIn = button }
                return item
            }
            let group = NSGroupTouchBarItem(identifier: identifier, items: items)
            group.prefersEqualWidths = true
            group.preferredItemWidth = 64
            updateToolbar(force: true)
            return group
        }
        let item = NSCustomTouchBarItem(identifier: identifier)
        switch identifier {
        case Self.touchGridID:
            let button = NSButton(title: "Grid", target: self, action: #selector(toggleGrid))
            button.setButtonType(.toggle)
            button.setAccessibilityLabel("Rule of Thirds Grid")
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
            touchGrid = button; item.view = button
        case Self.touchPauseID:
            let button = NSButton(title: "Freeze", target: self, action: #selector(togglePaused))
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
            touchPause = button; item.view = button
        default: return nil
        }
        updateToolbar(force: true)
        return item
    }

    @objc private func touchFitImage() { options.setFit(.fit) }

    @objc private func setFit(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ImageFit(rawValue: raw) else { return }
        options.setFit(mode)
    }
    @objc private func fullscreen() {
        guard !transitioningFullscreen else { return }
        window?.toggleFullScreen(nil)
    }
    @objc private func toggleFloating() { window?.level = window?.level == .floating ? .normal : .floating }
    @objc private func toggleInfo() {
        if window?.styleMask.contains(.fullScreen) == true {
            fullscreenInfoVisible.toggle()
            updateInfo()
        } else { options.showInfo.toggle() }
    }
    @objc private func togglePaused() {
        if options.paused {
            options.paused = false
            // Keep the owned snapshot visible until the first fresh frame arrives.
            if let frame = onRequestFrame?() { receive(frame) }
        } else {
            if frozenImage != nil {
                options.paused = true
                updateToolbar(); onActivityChange?()
                return
            }
            guard let image = currentImage, let snapshot = surface.engine.snapshot(image) else {
                showStatus("Could not freeze this image at full resolution. Live view continues.")
                return
            }
            frozenImage = snapshot
            currentImage = snapshot.image
            surface.frameImage = snapshot.image
            options.paused = true
            surface.needsDisplay = true
        }
        updateToolbar()
        onActivityChange?()
    }
    @objc private func duplicate() { onDuplicate?() }
    @objc private func closeCopy() { window?.close() }
    @objc private func resetCrop() { options.crop = .none }
    @objc private func moveToScreen(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int, NSScreen.screens.indices.contains(index), let window else { return }
        window.setFrame(NSScreen.screens[index].visibleFrame, display: true, animate: true)
    }
    @objc private func matchAspect() {
        guard let window, let image = currentImage else { return }
        let size = options.crop.rect(in: image.extent.size).size
        let width = surface.bounds.width
        window.setContentSize(NSSize(width: width, height: max(100, width * size.height / size.width)))
    }
    @objc private func setPixelSize() {
        guard let window else { return }
        let size = surface.convertToBacking(surface.bounds).size
        let alert = NSAlert()
        alert.messageText = "Viewer size in pixels"
        alert.informativeText = "Set the image area's pixel dimensions on this display. Moving it to another display automatically adapts to that display's pixel density."
        alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
        let width = NSTextField(string: "\(Int(size.width))")
        let height = NSTextField(string: "\(Int(size.height))")
        width.placeholderString = "Width"; height.placeholderString = "Height"
        let stack = NSStackView(views: [width, NSTextField(labelWithString: "×"), height])
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: 26)
        stack.orientation = .horizontal; stack.distribution = .fillProportionally
        alert.accessoryView = stack
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn,
                  let w = Int(width.stringValue), let h = Int(height.stringValue),
                  (240...8192).contains(w), (160...8192).contains(h) else { return }
            let scale = window.backingScaleFactor
            window.setContentSize(NSSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale))
        }
    }
    @objc private func showCrop() {
        if let cropPanel { cropPanel.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 340),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Crop · Copy \(sequence)"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: CropEditor(options: options))
        window?.addChildWindow(panel, ordered: .above)
        panel.center(); panel.makeKeyAndOrderFront(nil)
        cropPanel = panel
    }
}

private struct CropEditor: View {
    @ObservedObject var options: MirrorOptions
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Show only the camera image").font(.headline)
            Text("Trim controls from this copy. The original window stays as it is.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach([("Left", \ImageCrop.left), ("Top", \ImageCrop.top),
                     ("Right", \ImageCrop.right), ("Bottom", \ImageCrop.bottom)], id: \.0) { label, path in
                HStack {
                    Text(label).frame(width: 48, alignment: .leading)
                    Slider(value: Binding(get: { options.crop[keyPath: path] },
                                          set: { options.crop[keyPath: path] = $0 }), in: 0...0.45)
                    Text("\(Int(options.crop[keyPath: path] * 100))%")
                        .monospacedDigit().frame(width: 36, alignment: .trailing)
                }
            }
            Button("Reset Crop") { options.crop = .none }
        }
        .padding(22).frame(width: 360, height: 340)
    }
}
