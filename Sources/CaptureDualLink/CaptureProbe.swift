import AppKit
import ScreenCaptureKit
import CoreImage
import QuartzCore
import DualLinkCore
import Darwin

/// Developer integration check. It captures only this app's own calibration window,
/// drawn like Capture One's Live View: a busy toolbar, a flat gray background and a
/// noisy 4:3 picture. `currentProcess` is Apple's API for content that needs no
/// screen-recording consent.
@MainActor
final class CaptureProbe {
    let directory: URL
    private var source: NSWindow?
    private var pattern: ProbePattern?
    private var session: CaptureSession?
    private var viewers: [MirrorWindowController] = []
    private let trimModel = TrimModel(appName: "Calibration", trim: SourceTrim(top: Double(ProbePattern.toolbar)))
    private var checks: [String] = []
    private var failure: String?
    private var finished = false
    private var engine: RenderEngine?
    private var metadata: [String: String] = [:]
    private var samples: [String: String] = [:]
    private var performance: [String: Any] = [:]
    private var verificationModel: AppModel?
    private var animationTimer: Timer?
    private var geometryReports = 0
    private let readback = CGColorSpace(name: CGColorSpace.sRGB)!

    private struct ProbeError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    init(directory: URL) { self.directory = directory }

    func run() {
        guard #available(macOS 14.4, *) else { finish(error: "Self-test requires macOS 14.4."); return }
        guard let engine = RenderEngine() else { finish(error: "Metal unavailable"); return }
        self.engine = engine
        let source = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        source.title = "DualLink Calibration Source"
        source.isReleasedWhenClosed = false
        source.isOpaque = false
        source.backgroundColor = .clear
        source.hasShadow = false
        let pattern = ProbePattern()
        source.contentView = pattern
        source.makeKeyAndOrderFront(nil)
        self.source = source; self.pattern = pattern
        Task { [self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                try await verifyCapture(engine: engine, source: source)
                if failure == nil { await verifyMouseControl() }
                if CommandLine.arguments.contains("--check-performance"), failure == nil {
                    await verifyPipeline()
                    await verifyCaptureLifecycle()
                }
                if CommandLine.arguments.contains("--check-fill-display") ||
                    CommandLine.arguments.contains("--check-fullscreen"), failure == nil {
                    verifyFocusAndFillDisplay()
                }
                finish(error: failure)
            } catch { finish(error: error.localizedDescription) }
        }
        Task {
            try? await Task.sleep(for: .seconds(CommandLine.arguments.contains("--check-performance") ? 90 : 30))
            if !finished { finish(error: failure ?? "Timed out waiting for captured calibration frames.") }
        }
    }

    // MARK: Capture, trim, detection and grid through the real pipeline

    private func verifyCapture(engine: RenderEngine, source: NSWindow) async throws {
        guard #available(macOS 14.4, *) else { return }
        let content = try await SCShareableContent.currentProcess
        guard let window = content.windows.first(where: { $0.windowID == CGWindowID(source.windowNumber) }) else {
            throw ProbeError("Own calibration window was unavailable to ScreenCaptureKit.")
        }
        let session = CaptureSession(source: WindowSource(window: window), detail: .native, fps: 30, trim: trimModel.trim)
        self.session = session
        session.onMetadata = { [weak self] in self?.metadata = $0 }
        session.onFrame = { [weak self] frame in self?.viewers.forEach { $0.receive(frame) } }
        session.onStatus = { [weak self, weak session] status in
            if let status, (session?.deliveredFrameCount ?? 0) > 0 { self?.finish(error: status) }
        }
        session.onGeometryChange = { [weak self] in
            self?.geometryReports += 1
            Task { await self?.refreshSource() }
        }
        for sequence in 1...2 {
            let viewer = MirrorWindowController(sourceID: window.windowID, title: "Calibration Copy",
                                                sequence: sequence, engine: engine, trimModel: trimModel)
            viewer.window?.level = .floating
            viewer.onRequestFrame = { [weak session] in session?.latestFrame }
            viewer.window?.setContentSize(NSSize(width: 640, height: 400))
            let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            viewer.window?.setFrameOrigin(NSPoint(x: area.minX + 20 + CGFloat(sequence - 1) * 670, y: area.minY + 60))
            viewer.showWindow(nil)
            viewers.append(viewer)
        }
        NSApp.activate()
        try await session.start(window: window)
        await waitUntil { session.latestFrame?.pictureArea != nil && self.viewers.allSatisfy { $0.surface.frameImage != nil } }
        guard let frame = session.latestFrame else { throw ProbeError("No calibration frame arrived.") }

        let scale = source.backingScaleFactor
        let size = frame.image.extent.size
        metadata["backingScale"] = "\(scale)"
        samples["trimmedSize"] = "\(size)"
        check(abs(size.width - 640 * scale) < 2 && abs(size.height - 360 * scale) < 2,
              "Toolbar trim removes exactly the trimmed points, at native pixels")
        let expected = expectedPicture(windowWidth: 640, scale: scale)
        samples["expectedPicture"] = "\(expected)"
        samples["detectedPicture"] = frame.pictureArea.map { "\($0)" } ?? "nil"
        check(frame.pictureArea.map { close($0, expected, slack: max(3, scale * 2)) } == true,
              "Detection finds the camera picture inside the flat background")
        let picture = frame.pictureArea ?? expected
        let tl = pixel(frame.image, x: picture.minX + picture.width * 0.25, y: picture.minY + picture.height * 0.75)
        let bl = pixel(frame.image, x: picture.minX + picture.width * 0.25, y: picture.minY + picture.height * 0.25)
        samples["topLeft"] = "\(tl)"; samples["bottomLeft"] = "\(bl)"
        check(tl[0] > 170 && tl[1] < 90 && tl[2] < 90, "Captured picture top-left stays red (orientation and P3 color)")
        check(bl[2] > 170 && bl[0] < 90, "Captured picture bottom-left stays blue")
        save(frame.image, name: "captured-trimmed.png", engine: engine)
        guard failure == nil else { return }

        verifyRendering(sourceSize: size, expected: expected, engine: engine)
        guard failure == nil else { return }

        // The trim is shared by every copy and applies to the next frame.
        trimModel.trim = .none
        session.trim = .none
        await waitUntil { abs((session.latestFrame?.image.extent.height ?? 0) - 400 * scale) < 2 }
        check(abs((session.latestFrame?.image.extent.height ?? 0) - 400 * scale) < 2,
              "Changing the trim updates the shared source area immediately")
        trimModel.trim = SourceTrim(top: Double(ProbePattern.toolbar))
        session.trim = trimModel.trim
        await waitUntil { abs((session.latestFrame?.image.extent.height ?? 0) - 360 * scale) < 2 }

        // Widen the source: the frame reports the change, capture follows, detection moves.
        let reports = geometryReports
        source.setContentSize(NSSize(width: 900, height: 400))
        pattern?.needsDisplay = true
        let wide = expectedPicture(windowWidth: 900, scale: scale)
        await waitUntil {
            guard let frame = session.latestFrame, let found = frame.pictureArea else { return false }
            return abs(frame.image.extent.width - 900 * scale) < 2 && self.close(found, wide, slack: max(3, scale * 2))
        }
        metadata["geometryReportsDuringResize"] = "\(geometryReports - reports)"
        samples["resizedPicture"] = session.latestFrame?.pictureArea.map { "\($0)" } ?? "nil"
        check(abs((session.latestFrame?.image.extent.width ?? 0) - 900 * scale) < 2,
              "Source resizing updates capture size and aspect ratio")
        check(geometryReports > reports, "Frame metadata reports the resize without waiting for the poll")
        check(session.latestFrame?.pictureArea.map { close($0, wide, slack: max(3, scale * 2)) } == true,
              "Detection follows the picture after the source is resized")
        check(viewers.allSatisfy { $0.surface.frameImage != nil }, "One capture feeds two independent viewers")
        if let image = session.latestFrame?.image { save(image, name: "resized-source.png", engine: engine) }
        await session.stop()
        check(session.latestFrame == nil, "Stopping releases the retained capture frame")
    }

    /// The calibration picture in trimmed-source pixels, Core Image coordinates.
    private func expectedPicture(windowWidth: CGFloat, scale: CGFloat) -> CGRect {
        let topLeft = ProbePattern.pictureRect(in: NSSize(width: windowWidth, height: 400))
            .offsetBy(dx: 0, dy: -ProbePattern.toolbar)
        let pixels = CGRect(x: topLeft.minX * scale, y: topLeft.minY * scale,
                            width: topLeft.width * scale, height: topLeft.height * scale)
        return ImageGeometry.flipped(pixels, height: 360 * scale)
    }

    private func verifyRendering(sourceSize size: CGSize, expected: CGRect, engine: RenderEngine) {
        let first = viewers[0], second = viewers[1]
        let target = CGSize(width: 1920, height: 1080)
        let placement = ImageGeometry.placement(source: size, destination: target, mode: .fit)
        let picture = ImageGeometry.map(expected, source: size, into: placement)
        let baseline = first.surface.renderedImage(size: target)
        first.options.showGrid = true
        let gridded = first.surface.renderedImage(size: target)
        save(gridded, name: "grid-follows-picture.png", engine: engine)
        // A white line over a saturated quadrant can't raise an already-full channel,
        // so compare overall brightness.
        func brightened(_ x: CGFloat, _ y: CGFloat) -> Bool {
            let a = pixel(baseline, x: x, y: y), b = pixel(gridded, x: x, y: y)
            return b.prefix(3).reduce(0) { $0 + Int($1) } > a.prefix(3).reduce(0) { $0 + Int($1) } + 120
        }
        func unchanged(_ x: CGFloat, _ y: CGFloat) -> Bool {
            zip(pixel(baseline, x: x, y: y), pixel(gridded, x: x, y: y)).allSatisfy { abs(Int($0.0) - Int($0.1)) <= 3 }
        }
        let thirdX = picture.minX + picture.width / 3, thirdY = picture.minY + picture.height / 3
        let probeY = picture.midY + 9, probeX = picture.midX + 9
        check(brightened(thirdX, probeY) && brightened(picture.minX + picture.width * 2 / 3, probeY),
              "Vertical grid lines sit at thirds of the camera picture")
        check(brightened(probeX, thirdY), "Horizontal grid lines sit at thirds of the camera picture")
        check(unchanged(placement.minX + placement.width / 3, probeY),
              "Grid ignores thirds of the whole window")
        check(unchanged((placement.minX + picture.minX) / 2, thirdY),
              "Grid stays out of the gray background bars")
        samples["gridPixel"] = "\(pixel(gridded, x: thirdX, y: probeY))"

        let otherGrid = second.surface.renderedImage(size: target)
        check(!second.options.showGrid &&
              zip(pixel(otherGrid, x: thirdX, y: probeY), pixel(baseline, x: thirdX, y: probeY))
                .allSatisfy { abs(Int($0.0) - Int($0.1)) <= 3 },
              "Grid is independent for each copy")
        first.options.showGrid = false

        let iPad = CGSize(width: 2048, height: 1536)
        let fit = first.surface.renderedImage(size: iPad)
        check(pixel(fit, x: 1024, y: 10).prefix(3).allSatisfy { $0 < 10 }, "Fit letterboxes a wide source on a 4:3 iPad")
        let fitPlacement = ImageGeometry.placement(source: size, destination: iPad, mode: .fit)
        check(pixel(fit, x: fitPlacement.minX + 1, y: fitPlacement.minY + 1).prefix(3).allSatisfy { $0 < 30 },
              "Rounded source corners blend into black with no white wedges")
        second.options.mode = .fill
        let filled = second.surface.renderedImage(size: iPad)
        check(pixel(filled, x: 1024, y: 10).prefix(3).contains { $0 > 20 }, "Fill reaches the viewer edge")
        check(first.options.mode == .fit, "Fit and Fill are independent for each copy")
        second.options.mode = .fit
    }

    private func refreshSource() async {
        guard #available(macOS 14.4, *), let session, let source else { return }
        let content = try? await SCShareableContent.currentProcess
        if let window = content?.windows.first(where: { $0.windowID == CGWindowID(source.windowNumber) }) {
            try? await session.refresh(window: window)
        }
    }

    // MARK: Production model, real ScreenCaptureKit, three live viewers

    private func verifyPipeline() async {
        guard #available(macOS 14.4, *), let source, let pattern else { return }
        for viewer in viewers { viewer.window?.orderOut(nil) }
        source.setContentSize(NSSize(width: 1600, height: 900))
        pattern.animate = true
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak pattern] _ in
            MainActor.assumeIsolated { pattern?.tick += 1; pattern?.needsDisplay = true }
        }
        let model = AppModel(persistPreferences: false, activeContent: { try await SCShareableContent.currentProcess })
        check(model.engine == nil, "An idle model allocates no Metal rendering context")
        model.detail = .native; model.fps = 30
        verificationModel = model
        do {
            let content = try await SCShareableContent.currentProcess
            guard let window = content.windows.first(where: { $0.windowID == CGWindowID(source.windowNumber) }) else {
                check(false, "Performance source is available"); return
            }
            let chosen = WindowSource(window: window)
            await model.duplicate(chosen)
            guard let session = model.sessions[chosen.id], let live = model.mirrors.values.first else {
                check(false, "Production model starts its capture stream"); return
            }
            live.trimModel.trim = SourceTrim(top: Double(ProbePattern.toolbar))
            live.perform(.duplicate); live.perform(.duplicate)
            let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let copies = Array(model.mirrors.values)
            for (index, viewer) in copies.enumerated() {
                viewer.window?.level = .floating
                viewer.window?.setContentSize(NSSize(width: min(460, area.width / 3.2), height: 300))
                viewer.window?.setFrameOrigin(NSPoint(x: area.minX + 12 + CGFloat(index) * (area.width / 3),
                                                      y: area.minY + 30))
                viewer.showWindow(nil)
            }
            let scale = source.backingScaleFactor
            let nativeSize = CGSize(width: 1600 * scale, height: (900 - ProbePattern.toolbar) * scale)
            await waitUntil { session.active && session.latestFrame?.image.extent.size == nativeSize }
            check(session.latestFrame?.image.extent.size == nativeSize,
                  "A trim set in one copy applies to the shared capture at native pixels")
            check(copies.count == 3 && model.sessions.count == 1, "Three viewers share one capture stream")
            check(copies.allSatisfy { ($0.surface.layer as? CAMetalLayer)?.maximumDrawableCount == 2 },
                  "Every viewer uses two full-resolution drawable buffers")
            await waitUntil { copies.allSatisfy { $0.surface.completedFrames > 0 } }
            let frames = session.deliveredFrameCount
            let renders = copies.map { $0.surface.completedFrames }
            let gpu = copies.reduce(0) { $0 + $1.surface.totalGPUTime }
            let dropped = copies.reduce(0) { $0 + $1.surface.droppedRenders }
            let footprint = physicalFootprint()
            let allocatedGPU = copies.first?.surface.engine.device.currentAllocatedSize ?? 0
            let cpu = cpuSeconds(), uptime = ProcessInfo.processInfo.systemUptime
            try? await Task.sleep(for: .seconds(5))
            let duration = ProcessInfo.processInfo.systemUptime - uptime
            let delivered = session.deliveredFrameCount - frames
            let completed = zip(copies, renders).map { $0.0.surface.completedFrames - $0.1 }
            let gpuTime = copies.reduce(0) { $0 + $1.surface.totalGPUTime } - gpu
            performance = ["scope": "Own animated calibration window; not a camera or physical Sidecar benchmark",
                "durationSeconds": duration, "nativeSourceWidth": nativeSize.width, "nativeSourceHeight": nativeSize.height,
                "liveViewers": copies.count, "captureStreams": model.sessions.count,
                "deliveredFrames": delivered, "deliveredFPS": Double(delivered) / duration,
                "cpuPercentOfOneCore": (cpuSeconds() - cpu) / duration * 100,
                "completedViewerRenders": completed.reduce(0, +),
                "meanGPUTimeMillisecondsPerRender": completed.reduce(0, +) > 0 ? gpuTime / Double(completed.reduce(0, +)) * 1000 : 0,
                "droppedRenderRequests": copies.reduce(0) { $0 + $1.surface.droppedRenders } - dropped,
                "physicalFootprintBytes": max(footprint, physicalFootprint()),
                "metalAllocatedBytes": max(allocatedGPU, copies.first?.surface.engine.device.currentAllocatedSize ?? 0),
                "detectedPicture": session.latestFrame?.pictureArea.map { "\($0)" } ?? "nil"]
            check(delivered >= 60, "Live capture keeps delivering frames to three viewers")
            check(completed.allSatisfy { $0 >= 30 }, "Every live viewer keeps rendering")
            check(session.latestFrame?.image.extent.size == nativeSize, "Stress test never reduces capture resolution")
            check(session.latestFrame?.pictureArea != nil, "Detection keeps running during live capture")

            live.options.showGrid = true; live.options.mode = .fill
            model.prepareForSleep()
            await waitUntil { !session.active && !session.starting }
            check(!session.active && session.latestFrame == nil, "Sleep releases the capture stream and live buffers")
            model.resumeAfterSleep()
            await waitUntil { session.active && session.latestFrame != nil }
            check(session.active && session.latestFrame?.image.extent.size == nativeSize,
                  "Wake restarts the same selected source at native resolution")
            check(live.options.showGrid && live.options.mode == .fill && live.trimModel.trim.top == Double(ProbePattern.toolbar),
                  "Wake preserves each copy's grid and fit, and the shared trim")

            for viewer in copies { viewer.window?.miniaturize(nil) }
            await waitUntil { !session.active }
            check(!session.active && copies.allSatisfy { $0.surface.frameImage == nil },
                  "Minimized viewers release live frames and stop capture")
            for viewer in copies { viewer.window?.deminiaturize(nil) }
            await waitUntil { session.active && copies.allSatisfy { $0.surface.frameImage != nil } }
            check(session.active && session.latestFrame?.image.extent.size == nativeSize,
                  "Restoring viewers resumes native pixels without recreating their settings")
            await verifyViewManagement(model: model, source: chosen)
            model.shutdown(); verificationModel = nil
            animationTimer?.invalidate(); animationTimer = nil
            for viewer in viewers { viewer.showWindow(nil) }
        } catch { check(false, "Pipeline verification: \(error.localizedDescription)") }
    }

    private func verifyViewManagement(model: AppModel, source: WindowSource) async {
        let copies = model.mirrors.values.sorted { $0.sequence < $1.sequence }
        guard copies.count == 3, let first = copies.first, let last = copies.last else {
            check(false, "View management has three calibration copies"); return
        }
        check(model.liveViews.map(\.name) == ["Live View 1", "Live View 2", "Live View 3"],
              "The manager lists exactly the open live views in numeric order")
        check(copies.allSatisfy { copy in model.liveViews.contains {
            $0.id == copy.id && $0.display == copy.window?.screen?.localizedName && $0.source == source.label
        } }, "Each live view reports its actual screen and source")

        // Exercise only our own windows; permission/source enumeration is unnecessary here.
        let permission = model.hasPermission
        model.hasPermission = false
        let picker = PickerWindowController(model: model, onShowGuide: {})
        defer { picker.close(); model.hasPermission = permission }
        picker.present()
        picker.present()
        if NSApp.isActive { await waitUntil { picker.window?.isKeyWindow == true } }
        samples["managerFocus"] = "active=\(NSApp.isActive), key=\(picker.window?.isKeyWindow == true), canBecomeKey=\(picker.window?.canBecomeKey == true)"
        check(picker.window?.isVisible == true && picker.window?.canBecomeKey == true &&
              (!NSApp.isActive || picker.window?.isKeyWindow == true),
              "Opening management twice keeps it visible and able to receive keyboard input")
        picker.window?.orderOut(nil)
        picker.present()
        check(picker.window?.isVisible == true, "Opening management restores a hidden panel")
        picker.close()
        picker.present()
        check(picker.window?.isVisible == true, "Opening management restores a closed panel")
        first.toggleFillDisplay()
        picker.present()
        check((picker.window?.level.rawValue ?? 0) > (first.window?.level.rawValue ?? 0),
              "Management stays reachable above a live view filling its display")
        first.toggleFillDisplay()
        if let screen = NSScreen.main, let window = picker.window {
            window.setFrameOrigin(CGPoint(x: screen.frame.maxX + 5000, y: screen.frame.minY))
            picker.present()
            check(NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) },
                  "Opening management brings an offscreen panel back onto a connected screen")
        }
        picker.window?.orderOut(nil)

        if NSScreen.screens.count > 1, let window = first.window,
           let other = NSScreen.screens.first(where: { $0 != window.screen }) {
            let original = window.frame
            window.setFrameOrigin(CGPoint(x: other.visibleFrame.minX + 20, y: other.visibleFrame.minY + 40))
            await waitUntil { model.liveViews.first { $0.id == first.id }?.display == other.localizedName }
            check(model.liveViews.first { $0.id == first.id }?.display == other.localizedName,
                  "Moving a view to another connected screen updates the manager")
            window.setFrame(original, display: true)
        }
        last.window?.miniaturize(nil)
        await waitUntil { model.liveViews.first { $0.id == last.id }?.state == "Minimized" }
        check(model.liveViews.first { $0.id == last.id }?.state == "Minimized",
              "Minimized live views remain listed with their state")
        model.showMirror(last.id)
        await waitUntil { last.window?.isMiniaturized == false && last.wantsLiveFrames }
        check(last.window?.isVisible == true && last.window?.isMiniaturized == false,
              "Show restores a minimized live view")
        if let screen = NSScreen.main, let window = last.window {
            let original = window.frame
            window.setFrameOrigin(CGPoint(x: screen.frame.maxX + 5000, y: screen.frame.minY))
            model.showMirror(last.id)
            check(NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) },
                  "Show brings a live view back from an unavailable display")
            window.setFrame(original, display: true)
        }

        model.closeMirror(first.id)
        check(model.mirrors[first.id] == nil && model.mirrorCount == 2 && model.liveViews.count == 2,
              "Close removes exactly the chosen live view from both the window and manager")
        last.perform(.duplicate)
        let reused = model.mirrors.values.first { $0.sequence == 1 }
        check(reused != nil && Set(model.liveViews.map(\.name)).count == 3,
              "A freed live-view number is reused without duplicating an open number")
        reused?.toggleFillDisplay()
        if let reused { model.closeMirror(reused.id) }
        check(model.mirrorCount == 2, "A view can be closed from management while filling its display")
        last.window?.miniaturize(nil)
        model.closeMirror(last.id)
        check(model.mirrors[last.id] == nil, "A minimized live view can be closed from management")
        let oldSession = model.sessions[source.id]
        model.closeAll()
        await waitUntil { oldSession?.active == false && oldSession?.latestFrame == nil }
        check(model.liveViews.isEmpty && model.sessions.isEmpty && model.mirrorCount == 0,
              "Close All clears the live-view list and releases the last capture session")
        check(model.engine == nil, "Closing the last view releases the model's rendering context and clears its caches")
        await model.duplicate(source)
        check(model.liveViews.map(\.name) == ["Live View 1"],
              "The first live view after closing all views starts at one")
        model.closeAll()
    }

    private func verifyMouseControl() async {
        guard let source, let pattern, let engine, let frame = viewers.first?.surface.capturedFrame else {
            check(false, "Mouse calibration has a captured source frame"); return
        }
        let viewer = MirrorWindowController(sourceID: CGWindowID(source.windowNumber), title: "Mouse Control Check",
                                            sequence: 1, engine: engine, trimModel: trimModel,
                                            sourceProcessID: ProcessInfo.processInfo.processIdentifier)
        defer { viewer.close(); pattern.onMouseEvent = nil }
        viewer.window?.level = .floating
        viewer.showWindow(nil)
        await waitUntil { viewer.wantsLiveFrames }
        viewer.receive(frame)
        viewer.options.controlSource = true
        var received: [(NSEvent.EventType, CGPoint, Int, CGFloat)] = []
        pattern.onMouseEvent = { event in
            received.append((event.type, pattern.convert(event.locationInWindow, from: nil),
                             event.type == .scrollWheel ? 0 : event.clickCount,
                             event.type == .scrollWheel ? event.scrollingDeltaY : 0))
        }
        let size = viewer.surface.bounds.size
        let placed = ImageGeometry.placement(source: frame.nativeSize, destination: size, mode: .fit)
        let point = CGPoint(x: placed.minX + placed.width / 4, y: placed.minY + placed.height * 0.75)
        let expected = CGPoint(x: frame.sourceRect.minX + frame.sourceRect.width / 4,
                               y: frame.sourceRect.minY + frame.sourceRect.height / 4)
        func event(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: viewer.surface.convert(point, to: nil), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: viewer.window!.windowNumber,
                               context: nil, eventNumber: 77, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        let drawable = viewer.surface.drawableSize
        viewer.surface.mouseDown(with: event(.leftMouseDown, at: point))
        viewer.surface.mouseUp(with: event(.leftMouseUp, at: point))
        await waitUntil { received.count >= 2 }
        check(received.count == 2 && abs((received.first?.1.x ?? -999) - expected.x) < 2 &&
              abs((received.first?.1.y ?? -999) - expected.y) < 2,
              "A click in a trimmed copy reaches the matching point in the original window")
        viewer.surface.mouseDown(with: event(.leftMouseDown, at: point, clicks: 2))
        viewer.surface.mouseUp(with: event(.leftMouseUp, at: point, clicks: 2))
        await waitUntil { received.count >= 4 }
        check(received.dropFirst(2).first?.2 == 2 && !viewer.isFillingDisplay,
              "Control Source sends double-clicks to the source instead of filling the display")
        viewer.surface.mouseDown(with: event(.leftMouseDown, at: point))
        let outside = CGPoint(x: -100, y: size.height + 100)
        viewer.surface.mouseDragged(with: event(.leftMouseDragged, at: outside))
        viewer.surface.mouseUp(with: event(.leftMouseUp, at: outside))
        await waitUntil { received.count >= 7 }
        check(received.count >= 7 && received[5].0 == .leftMouseDragged && received[6].0 == .leftMouseUp &&
              !viewer.mouseControl.isDragging, "Dragging beyond a copy still releases the source mouse button")
        let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: -3, wheel2: 0, wheel3: 0)!
        if let scrollEvent = NSEvent(cgEvent: scroll) {
            viewer.mouseControl.send(scrollEvent, point: expected, sourceSize: frame.sourceSize)
        }
        await waitUntil { received.contains { $0.0 == .scrollWheel } }
        check(received.contains { $0.0 == .scrollWheel && $0.3 < 0 }, "Scroll wheel reaches the original window")
        let beforeCancel = received.count
        viewer.surface.mouseDown(with: event(.leftMouseDown, at: point))
        viewer.mouseControl.cancel()
        await waitUntil { received.count >= beforeCancel + 2 }
        check(received.count >= beforeCancel + 2 && received.last?.0 == .leftMouseUp &&
              (received.last?.1.x ?? 0) < 0 && (received.last?.1.y ?? 0) < 0 && !viewer.mouseControl.isDragging,
              "Disabling source control releases a held mouse button")
        let rejected = !viewer.mouseControl.send(event(.leftMouseDown, at: point), point: expected,
                                                  sourceSize: CGSize(width: 1, height: 1))
        check(rejected, "A stale resized source rejects mouse input until its frame catches up")
        check(viewer.surface.drawableSize == drawable && viewer.window?.canBecomeKey == false,
              "Mouse controls preserve drawable resolution and never make the copy key")
        let beforePause = received.count
        viewer.showStatus("Source paused")
        viewer.surface.mouseDown(with: event(.leftMouseDown, at: point))
        viewer.surface.mouseUp(with: event(.leftMouseUp, at: point))
        try? await Task.sleep(for: .milliseconds(150))
        check(received.count == beforePause, "A paused source ignores clicks on its frozen picture")
        samples["mouseExpectedSourcePoint"] = "\(expected)"
        samples["mouseReceivedEvents"] = received.map { "\($0.0.rawValue):\($0.1)" }.joined(separator: ", ")
    }

    private func verifyCaptureLifecycle() async {
        guard #available(macOS 14.4, *), let source else { return }
        do {
            let content = try await SCShareableContent.currentProcess
            guard let window = content.windows.first(where: { $0.windowID == CGWindowID(source.windowNumber) }),
                  let other = content.windows.first(where: { $0.windowID != window.windowID }) else {
                throw ProbeError("Lifecycle calibration windows are unavailable.")
            }
            let chosen = WindowSource(window: window)
            let mismatched = CaptureSession(source: chosen, detail: .native, fps: 30)
            do {
                try await mismatched.start(window: other)
                check(false, "A capture session rejects a different source window")
            } catch {
                check(!mismatched.active, "A capture session rejects a different source window")
            }
            await mismatched.stop()

            var pending: CheckedContinuation<SCShareableContent, Error>?
            var reads = 0
            let model = AppModel(persistPreferences: false, activeContent: {
                reads += 1
                if reads == 1 { return try await withCheckedThrowingContinuation { pending = $0 } }
                return try await SCShareableContent.currentProcess
            })
            verificationModel = model
            let abandoned = Task { await model.duplicate(chosen) }
            await waitUntil { pending != nil }
            guard let pendingRead = pending, let connecting = model.mirrors.values.first else {
                model.shutdown(); abandoned.cancel()
                throw ProbeError("Could not hold the initial source lookup.")
            }
            connecting.close()
            await model.duplicate(chosen)
            let replacement = model.sessions[chosen.id]
            pendingRead.resume(throwing: ProbeError("Simulated delayed lookup failure"))
            await abandoned.value
            check(replacement != nil && model.sessions[chosen.id] === replacement && model.mirrorCount == 1,
                  "An abandoned connection cannot remove a newer copy of the same source")
            model.shutdown()
            await replacement?.stop()

            var failedLookup: CheckedContinuation<SCShareableContent, Error>?
            var openingReads = 0
            let failedModel = AppModel(persistPreferences: false, activeContent: {
                openingReads += 1
                if openingReads == 1 { return try await withCheckedThrowingContinuation { failedLookup = $0 } }
                return try await SCShareableContent.currentProcess
            })
            verificationModel = failedModel
            let failedConnection = Task { await failedModel.duplicate(chosen) }
            await waitUntil { failedLookup != nil }
            guard let failedRead = failedLookup, let failedCopy = failedModel.mirrors.values.first else {
                failedModel.shutdown(); failedConnection.cancel()
                throw ProbeError("Could not hold the failed connection lookup.")
            }
            failedCopy.perform(.duplicate)
            check(failedModel.mirrorCount == 2, "Another copy can join a connecting source")
            failedModel.applyCaptureSettings()
            try await Task.sleep(for: .milliseconds(150))
            check(openingReads == 1 && failedModel.sessions[chosen.id]?.active == false,
                  "Activity and settings refreshes do not start a second pending connection")
            failedRead.resume(throwing: ProbeError("Simulated initial connection failure"))
            await failedConnection.value
            check(failedModel.mirrors.isEmpty && failedModel.sessions.isEmpty,
                  "A failed initial connection cleans up every waiting copy")
            failedModel.shutdown()

            var sleepingLookup: CheckedContinuation<SCShareableContent, Error>?
            var sleepReads = 0
            let sleepingModel = AppModel(persistPreferences: false, activeContent: {
                sleepReads += 1
                if sleepReads == 1 { return try await withCheckedThrowingContinuation { sleepingLookup = $0 } }
                return try await SCShareableContent.currentProcess
            })
            verificationModel = sleepingModel
            let sleepingConnection = Task { await sleepingModel.duplicate(chosen) }
            await waitUntil { sleepingLookup != nil }
            guard let sleepingRead = sleepingLookup, let sleepingSession = sleepingModel.sessions[chosen.id] else {
                sleepingModel.shutdown(); sleepingConnection.cancel()
                throw ProbeError("Could not hold the sleeping connection lookup.")
            }
            sleepingModel.prepareForSleep()
            sleepingRead.resume(returning: content)
            await sleepingConnection.value
            check(!sleepingSession.active && !sleepingSession.starting && sleepingModel.mirrorCount == 1,
                  "A connection finishing its lookup during sleep stays stopped")
            sleepingModel.resumeAfterSleep()
            await waitUntil { sleepingSession.active && sleepingSession.latestFrame != nil }
            check(sleepingSession.active && sleepingSession.latestFrame != nil,
                  "Wake resumes a connection that was still opening at sleep")
            sleepingModel.shutdown()
            await sleepingSession.stop()

            var failReads = false, failedReads = 0
            let retryModel = AppModel(persistPreferences: false, activeContent: {
                if failReads { failedReads += 1; throw ProbeError("Simulated window-list outage") }
                return try await SCShareableContent.currentProcess
            })
            verificationModel = retryModel
            defer { retryModel.shutdown(); verificationModel = nil }
            await retryModel.duplicate(chosen)
            guard let retrySession = retryModel.sessions[chosen.id] else {
                throw ProbeError("Could not start the reconnect calibration.")
            }
            await waitUntil { retrySession.latestFrame != nil && retryModel.mirrors.values.contains { $0.wantsLiveFrames } }
            guard let pausedCopy = retryModel.mirrors.values.first, let pausedWindow = pausedCopy.window else {
                throw ProbeError("Could not find the paused-source calibration copy.")
            }
            let pauseMessage = "Source paused for calibration"
            retrySession.reportStatus(pauseMessage)
            check(retrySession.latestFrame == nil, "A paused source discards its reusable live frame")
            pausedCopy.options.controlSource = true
            pausedCopy.windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification))
            let click = NSEvent.mouseEvent(with: .leftMouseDown,
                                           location: CGPoint(x: pausedCopy.surface.bounds.midX, y: pausedCopy.surface.bounds.midY),
                                           modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: pausedWindow.windowNumber, context: nil,
                                           eventNumber: 0, clickCount: 1, pressure: 1)!
            pausedCopy.surface.mouseDown(with: click)
            check(!pausedCopy.mouseControl.isDragging,
                  "Visibility refresh cannot make a paused picture accept mouse input")
            pausedCopy.mouseControl.cancel(); pausedCopy.options.controlSource = false
            let copyIDs = Set(retryModel.mirrors.keys)
            pausedCopy.perform(.duplicate)
            let pausedExtra = retryModel.mirrors.values.first { !copyIDs.contains($0.id) }
            check(pausedExtra?.surface.subviews.compactMap { $0 as? NSTextField }.contains {
                $0.stringValue == pauseMessage && !$0.isHidden
            } == true, "A new copy inherits the source's paused status")
            let resumeCount = retrySession.deliveredFrameCount
            pattern?.tick += 1; pattern?.needsDisplay = true
            await waitUntil { retrySession.deliveredFrameCount > resumeCount && retrySession.latestFrame != nil }
            check(retrySession.latestFrame != nil && retrySession.statusMessage == nil,
                  "A fresh captured frame clears the paused status")
            await retrySession.stop()
            failReads = true
            retryModel.applyCaptureSettings()
            await waitUntil { failedReads > 0 }
            retryModel.applyCaptureSettings()
            try await Task.sleep(for: .milliseconds(150))
            check(failedReads == 1, "Window-list failures back off repeated reconnect requests")
            failReads = false
            retryModel.resumeAfterSleep()
            await waitUntil { retrySession.active && retrySession.latestFrame != nil }
            check(retrySession.active && retrySession.latestFrame != nil,
                  "Capture recovers after window listing becomes available again")
            retryModel.closeAll()
            await waitUntil { !retrySession.active && retrySession.latestFrame == nil }
            check(retryModel.sessions.isEmpty && retryModel.mirrors.isEmpty && retrySession.latestFrame == nil,
                  "Closing the last copy releases its session and live frame")
        } catch { check(false, "Capture lifecycle verification: \(error.localizedDescription)") }
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline, !finished {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
            Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    // MARK: Focus and Fill Display

    /// Copies must never take keyboard focus, so Capture One keeps its shortcuts (⌘K fires the camera).
    private func verifyFocusAndFillDisplay() {
        guard let viewer = viewers.first, let window = viewer.window, let screen = window.screen ?? NSScreen.main else {
            check(false, "Missing viewer for focus and Fill Display checks"); return
        }
        viewer.showWindow(nil)
        let originalFrame = window.frame
        viewer.options.mode = .fill
        viewer.options.showGrid = true
        window.level = .floating
        check(!window.canBecomeKey && !window.canBecomeMain, "Copies can never become the key or main window")
        check(window.styleMask.contains(.nonactivatingPanel), "Clicking a copy does not activate DualLink")

        // A real click and double-click through AppKit's event dispatch.
        let keyBefore = NSApp.keyWindow
        func click(_ count: Int) {
            let point = NSPoint(x: window.frame.width / 2, y: window.frame.height / 2)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil,
                                                  eventNumber: 0, clickCount: count, pressure: 1) {
                    window.sendEvent(event)
                }
            }
        }
        click(1)
        check(NSApp.keyWindow === keyBefore && NSApp.keyWindow !== window, "Clicking a copy leaves keyboard focus where it was")
        check(!viewer.overlay.isHidden, "Clicking a copy shows its controls")
        if let gridButton = viewer.overlay.buttons[.grid] {
            check(gridButton.acceptsFirstMouse(for: nil), "Overlay controls respond to the first click")
            gridButton.performClick(nil)
            check(!viewer.options.showGrid, "Overlay Grid button toggles this copy's grid")
            gridButton.performClick(nil)
        }

        click(2)
        let backing = viewer.surface.convertToBacking(viewer.surface.bounds).size
        samples["fillDisplayFrame"] = "\(window.frame) on \(screen.frame)"
        check(viewer.isFillingDisplay && window.frame == screen.frame, "Double-click fills the whole display, menu bar included")
        check(window.level.rawValue >= NSWindow.Level.statusBar.rawValue, "Fill Display sits above the menu bar")
        check(NSApp.keyWindow === keyBefore && NSApp.keyWindow !== window && NSApp.activationPolicy() == .regular,
              "Fill Display preserves keyboard focus with the Dock enabled")
        check(viewer.surface.drawableSize == backing, "Fill Display renders at the display's backing pixels")
        check(viewer.options.mode == .fill && viewer.options.showGrid, "Fill Display preserves the copy's fit and grid")
        click(2)
        check(!viewer.isFillingDisplay && window.styleMask.contains(.titled), "Double-click again restores the window")
        check(abs(window.frame.width - originalFrame.width) < 2 && abs(window.frame.height - originalFrame.height) < 2,
              "Leaving Fill Display restores the original window size")
        check(window.level == .floating, "Leaving Fill Display restores Keep on Top")

        window.setFrameOrigin(NSPoint(x: screen.frame.maxX + 5000, y: screen.frame.minY))
        viewer.toggleFillDisplay()
        viewer.toggleFillDisplay()
        check(NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) },
              "Leaving Fill Display keeps a copy reachable after its old display disappears")
        window.setFrame(originalFrame, display: true)
    }

    // MARK: Helpers

    private func close(_ a: CGRect, _ b: CGRect, slack: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= slack && abs(a.minY - b.minY) <= slack &&
        abs(a.maxX - b.maxX) <= slack && abs(a.maxY - b.maxY) <= slack
    }

    private func check(_ condition: Bool, _ name: String) {
        if condition { checks.append(name) } else if failure == nil { failure = name }
    }

    /// Reads back in sRGB so pure source colors keep familiar values.
    private func pixel(_ image: CIImage, x: CGFloat, y: CGFloat) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            engine?.context.render(image, toBitmap: buffer.baseAddress!, rowBytes: 4,
                                   bounds: CGRect(x: floor(x), y: floor(y), width: 1, height: 1),
                                   format: .RGBA8, colorSpace: readback)
        }
        return bytes
    }

    private func save(_ image: CIImage, name: String, engine: RenderEngine) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let cg = engine.context.createCGImage(image, from: image.extent),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: directory.appendingPathComponent(name))
    }

    private func finish(error: String?) {
        guard !finished else { return }
        finished = true
        let report: [String: Any] = ["passed": error == nil, "checks": checks,
                                     "error": error ?? "", "scope": "This app's own calibration window only",
                                     "metadata": metadata, "samples": samples, "performance": performance]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("capture-test.json"))
        }
        for viewer in viewers { viewer.close() }
        animationTimer?.invalidate(); verificationModel?.shutdown()
        source?.close()
        NSApp.terminate(nil)
    }
}

/// A Capture One–style Live View window: busy toolbar, flat background, noisy 4:3 picture.
private final class ProbePattern: NSView {
    var onMouseEvent: ((NSEvent) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onMouseEvent?(event) }
    override func mouseUp(with event: NSEvent) { onMouseEvent?(event) }
    override func mouseDragged(with event: NSEvent) { onMouseEvent?(event) }
    override func scrollWheel(with event: NSEvent) { onMouseEvent?(event) }
    static let toolbar: CGFloat = 40
    var animate = false
    var tick = 0
    private var noise: (size: CGSize, image: NSImage)?
    override var isFlipped: Bool { true }

    /// The picture's frame in flipped window points: 4:3, fit and centered below the toolbar.
    static func pictureRect(in size: NSSize) -> CGRect {
        let area = CGRect(x: 0, y: toolbar, width: size.width, height: size.height - toolbar)
        let unit = min(area.width / 4, area.height / 3)
        return CGRect(x: area.midX - unit * 2, y: area.midY - unit * 1.5, width: unit * 4, height: unit * 3).integral
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).addClip()
        NSColor(srgbRed: 58 / 255, green: 58 / 255, blue: 58 / 255, alpha: 1).setFill()
        bounds.fill()
        for i in 0...Int(bounds.width / 6) {
            NSColor(white: i % 2 == 0 ? 0.85 : 0.62, alpha: 1).setFill()
            NSRect(x: CGFloat(i) * 6, y: 0, width: 6, height: Self.toolbar).fill()
        }
        let picture = Self.pictureRect(in: bounds.size)
        NSGraphicsContext.current?.imageInterpolation = .none
        pictureImage(points: picture.size).draw(in: picture, from: .zero, operation: .sourceOver,
                                                fraction: 1, respectFlipped: true, hints: nil)
        if animate {
            NSColor.white.setFill()
            let travel = max(1, Int(picture.width - 60))
            NSRect(x: picture.minX + CGFloat(20 + tick % travel), y: picture.minY + 20, width: 20, height: 20).fill()
        }
    }

    /// Quadrant colors with per-pixel noise at the window's backing resolution.
    private func pictureImage(points: CGSize) -> NSImage {
        if let noise, noise.size == points { return noise.image }
        let scale = window?.backingScaleFactor ?? 2
        let width = Int(points.width * scale), height = Int(points.height * scale)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var state: UInt32 = 0x2545F491
        let quadrants: [[Int]] = [[230, 20, 20], [20, 200, 40], [20, 40, 230], [230, 220, 20]]
        for y in 0..<height {
            for x in 0..<width {
                let q = (y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)
                let i = (y * width + x) * 4
                for c in 0..<3 {
                    state = state &* 1_664_525 &+ 1_013_904_223
                    bytes[i + c] = UInt8(clamping: quadrants[q][c] + Int(state >> 24) % 25 - 12)
                }
            }
        }
        let image: NSImage = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let cg = context.makeImage() else { return NSImage(size: points) }
            return NSImage(cgImage: cg, size: points)
        }
        noise = (points, image)
        return image
    }
}
