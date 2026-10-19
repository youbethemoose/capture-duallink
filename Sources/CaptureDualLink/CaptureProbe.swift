import AppKit
import ScreenCaptureKit
import CoreImage
import DualLinkCore
import Darwin

/// Developer integration check. It captures only this app's own calibration window.
/// `currentProcess` is Apple's API for content that needs no screen-recording consent.
@MainActor
final class CaptureProbe {
    let directory: URL
    private var source: NSWindow?
    private var session: CaptureSession?
    private var viewers: [MirrorWindowController] = []
    private var checks: [String] = []
    private var failure: String?
    private var phase = 0
    private var finished = false
    private var engine: RenderEngine?
    private var metadata: [String: String] = [:]
    private var samples: [String: String] = [:]
    private var performance: [String: Any] = [:]
    private var verificationModel: AppModel?
    private var animationTimer: Timer?
    private var waitingForVisibility = false

    init(directory: URL) { self.directory = directory }

    func run() {
        guard #available(macOS 14.4, *) else { finish(error: "Self-test requires macOS 14.4."); return }
        guard let engine = RenderEngine() else { finish(error: "Metal unavailable"); return }
        self.engine = engine
        let source = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 320, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        source.title = "DualLink Calibration Source"
        source.isReleasedWhenClosed = false
        source.isOpaque = false
        source.backgroundColor = .clear
        source.hasShadow = false
        source.contentView = ProbePattern()
        source.makeKeyAndOrderFront(nil)
        self.source = source
        Task { [self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                let content = try await SCShareableContent.currentProcess
                guard let window = content.windows.first(where: { $0.windowID == CGWindowID(source.windowNumber) }) else {
                    finish(error: "Own calibration window was unavailable to ScreenCaptureKit."); return
                }
                let session = CaptureSession(source: WindowSource(window: window), detail: .native, fps: 30)
                self.session = session
                session.onMetadata = { [weak self] in self?.metadata = $0 }
                session.onFrame = { [weak self] frame in self?.receive(frame) }
                session.onStatus = { [weak self] status in
                    if let status { self?.finish(error: status) }
                }
                for sequence in 1...2 {
                    let viewer = MirrorWindowController(sourceID: window.windowID, title: "Calibration Copy",
                                                        sequence: sequence, engine: engine)
                    viewer.options.showInfo = false
                    viewer.window?.level = .floating
                    viewer.onRequestFrame = { [weak session] in session?.latestFrame }
                    viewer.window?.setContentSize(NSSize(width: 640, height: 480))
                    let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                    viewer.window?.setFrameOrigin(NSPoint(x: area.minX + 20 + CGFloat(sequence - 1) * 670,
                                                          y: area.minY + 60))
                    viewer.showWindow(nil)
                    viewers.append(viewer)
                }
                NSApp.activate(ignoringOtherApps: true)
                try await session.start(window: window)
            } catch { finish(error: error.localizedDescription) }
        }
        Task {
            try? await Task.sleep(for: .seconds(CommandLine.arguments.contains("--check-performance") ? 75 : 20))
            if !finished { finish(error: "Timed out waiting for captured calibration frames.") }
        }
    }

    private func receive(_ frame: CapturedFrame) {
        guard !finished, let engine else { return }
        for viewer in viewers { viewer.receive(frame) }
        if phase == 0, viewers.contains(where: { $0.surface.frameImage == nil }) {
            metadata["initialViewerVisibility"] = viewers.map {
                "visible=\($0.window?.isVisible ?? false), occlusion=\($0.window?.occlusionState.rawValue ?? 0), wants=\($0.wantsLiveFrames)"
            }.joined(separator: "; ")
            if !waitingForVisibility {
                waitingForVisibility = true
                Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    waitingForVisibility = false
                    if phase == 0, let latest = session?.latestFrame { receive(latest) }
                }
            }
            return
        }
        switch phase {
        case 0:
            phase = 1
            let size = frame.image.extent.size
            check(size.width >= 320 && size.height >= 240, "Own-window capture delivers native pixels")
            let tl = pixel(frame.image, x: size.width * 0.25, y: size.height * 0.75)
            let bl = pixel(frame.image, x: size.width * 0.25, y: size.height * 0.25)
            samples = ["size": "\(size)", "topLeft": "\(tl)", "bottomLeft": "\(bl)"]
            save(frame.image, name: "captured.png", engine: engine)
            if viewers.count == 2 {
                viewers[1].window?.setContentSize(NSSize(width: 600, height: 450))
                check(viewers[0].surface.bounds.size != viewers[1].surface.bounds.size,
                      "Viewers keep independent window sizes")
            }
            check(tl[0] > 220 && tl[1] < 30 && tl[2] < 30, "Captured top-left stays red")
            check(bl[2] > 220 && bl[0] < 30, "Captured bottom-left stays blue")
            let sourceCorners: [(CGFloat, CGFloat)] = [(1, 1), (size.width - 2, 1),
                                                       (1, size.height - 2), (size.width - 2, size.height - 2)]
            check(sourceCorners.allSatisfy { pixel(frame.image, x: $0.0, y: $0.1)[3] < 16 },
                  "Rounded source corners retain transparency instead of being filled white")
            guard failure == nil else { finish(error: failure); return }
            if let surface = viewers.first?.surface {
                let target = CGSize(width: 1920, height: 1080)
                let fit = surface.renderedImage(size: target)
                check(pixel(fit, x: 10, y: 540).prefix(3).allSatisfy { $0 < 10 }, "Fit letterboxes without stretching")
                let framePlacement = ImageGeometry.placement(source: size, destination: target, mode: .fit)
                let corners: [(CGFloat, CGFloat)] = [
                    (framePlacement.minX + 1, framePlacement.minY + 1),
                    (framePlacement.maxX - 2, framePlacement.minY + 1),
                    (framePlacement.minX + 1, framePlacement.maxY - 2),
                    (framePlacement.maxX - 2, framePlacement.maxY - 2)
                ]
                check(corners.allSatisfy {
                    let value = pixel(fit, x: $0.0, y: $0.1)
                    return value.prefix(3).allSatisfy { $0 < 8 } && value[3] > 247
                }, "All four captured window corners blend into black with no white wedges")
                save(fit, name: "fit-1920x1080.png", engine: engine)
                viewers[0].options.crop.top = 0.5
                let cropped = surface.renderedImage(size: target)
                let placement = ImageGeometry.placement(source: CGSize(width: size.width, height: size.height / 2),
                                                        destination: target, mode: .fit)
                let croppedTopLeft = pixel(cropped, x: placement.minX + placement.width * 0.25,
                                           y: placement.minY + placement.height * 0.75)
                check(croppedTopLeft[2] > 220 && croppedTopLeft[0] < 30, "Top crop removes the top of the source")
                let other = viewers[1].surface.renderedImage(size: target)
                let originalPlacement = ImageGeometry.placement(source: size, destination: target, mode: .fit)
                let otherTopLeft = pixel(other, x: originalPlacement.minX + originalPlacement.width * 0.25,
                                         y: originalPlacement.minY + originalPlacement.height * 0.75)
                check(otherTopLeft[0] > 220 && otherTopLeft[2] < 30, "Cropping one copy leaves the other copy unchanged")
                save(cropped, name: "crop-top-half.png", engine: engine)
                viewers[0].options.crop = .none
                viewers[0].options.mode = .fill
                let filled = surface.renderedImage(size: target)
                check(pixel(filled, x: 10, y: 270).prefix(3).contains { $0 > 220 }, "Fill reaches the viewer edge")
                viewers[0].options.mode = .actualPixels
                let oneToOne = surface.renderedImage(size: target)
                let expected = ImageGeometry.placement(source: size, destination: target, mode: .actualPixels)
                check(pixel(oneToOne, x: expected.minX - 2, y: 540).prefix(3).allSatisfy { $0 < 10 }, "1:1 uses captured pixels")
                viewers[0].options.mode = .fit
                verifyViewerControls(target: target, sourceSize: size, engine: engine)
            }
            Task {
                do {
                    phase = 2
                    source?.setContentSize(NSSize(width: 400, height: 400))
                    try await Task.sleep(for: .milliseconds(200))
                    if #available(macOS 14.4, *) {
                        let content = try await SCShareableContent.currentProcess
                        if let window = content.windows.first(where: { $0.windowID == self.session?.sourceID }) {
                            try await self.session?.refresh(window: window)
                        }
                    }
                    source?.contentView?.needsDisplay = true
                } catch { finish(error: error.localizedDescription) }
            }
        case 2:
            let expectedEdge = 400 * (source?.backingScaleFactor ?? 1)
            if abs(frame.image.extent.width - expectedEdge) < 2 && abs(frame.image.extent.height - expectedEdge) < 2 {
                check(true, "Source resizing updates capture size and aspect ratio")
                check(viewers.count == 2 && viewers.allSatisfy { $0.surface.frameImage != nil },
                      "One capture feeds two independent viewers")
                save(frame.image, name: "resized-source.png", engine: engine)
                phase = 3
                Task {
                    await session?.stop()
                    check(session?.latestFrame == nil, "Stopping releases the retained capture frame")
                    if CommandLine.arguments.contains("--check-performance"), failure == nil {
                        await verifyPipeline()
                    }
                    if CommandLine.arguments.contains("--check-fullscreen"), failure == nil {
                        verifyFullscreen()
                    } else { finish(error: failure) }
                }
            }
        default: break
        }
    }

    /// Production model, real ScreenCaptureKit, same source, five viewers, native-resolution frames.
    private func verifyPipeline() async {
        guard #available(macOS 14.4, *), let source, let pattern = source.contentView as? ProbePattern else { return }
        for viewer in viewers { viewer.window?.orderOut(nil) }
        source.setContentSize(NSSize(width: 1600, height: 900))
        pattern.animate = true
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak pattern] _ in
            MainActor.assumeIsolated { pattern?.tick += 1; pattern?.needsDisplay = true }
        }
        let model = AppModel(persistPreferences: false, activeContent: { try await SCShareableContent.currentProcess })
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
            live.options.showInfo = false
            live.window?.level = .floating
            let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            live.window?.setContentSize(NSSize(width: min(960, area.width * 0.56), height: min(640, area.height * 0.75)))
            live.window?.setFrameOrigin(NSPoint(x: area.minX + 12, y: area.minY + 30))
            await waitUntil { session.active && session.latestFrame != nil }
            let nativeSize = CGSize(width: 1600 * source.backingScaleFactor, height: 900 * source.backingScaleFactor)
            check(session.latestFrame?.image.extent.size == nativeSize, "Stress capture keeps native source pixels")
            var frozen: [MirrorWindowController] = []
            for _ in 0..<4 {
                let ids = Set(model.mirrors.keys)
                await model.duplicate(chosen)
                guard let viewer = model.mirrors.values.first(where: { !ids.contains($0.id) }) else { continue }
                viewer.options.showInfo = false
                viewer.window?.level = .floating
                viewer.window?.setContentSize(NSSize(width: max(300, area.width * 0.3), height: 300))
                viewer.window?.setFrameOrigin(NSPoint(x: area.minX + area.width * 0.62,
                                                      y: area.minY + 30 + CGFloat(frozen.count) * 26))
                let before = session.deliveredFrameCount
                await waitUntil { session.deliveredFrameCount > before && viewer.surface.frameImage != nil }
                guard let original = viewer.surface.frameImage else { check(false, "Freeze viewer receives a frame"); continue }
                let red = pixel(original, x: nativeSize.width / 4, y: nativeSize.height * 3 / 4)
                viewer.perform(.pause)
                check(viewer.options.paused && viewer.hasOwnedFrozenImage, "Frozen viewer owns independent GPU storage")
                if let image = viewer.surface.frameImage {
                    check(image.extent.size == nativeSize, "Freeze preserves full native resolution")
                    let copied = pixel(image, x: nativeSize.width / 4, y: nativeSize.height * 3 / 4)
                    check(zip(red, copied).allSatisfy { abs(Int($0.0) - Int($0.1)) <= 2 },
                          "GPU freeze preserves pixel orientation and color")
                }
                frozen.append(viewer)
            }
            check(frozen.count == 4 && model.sessions.count == 1, "Five viewers share one capture stream")
            let frames = session.deliveredFrameCount, labels = live.infoRefreshCount
            let renders = live.surface.completedFrames, gpu = live.surface.totalGPUTime
            let cpu = cpuSeconds(), uptime = ProcessInfo.processInfo.systemUptime
            try? await Task.sleep(for: .seconds(5))
            let duration = ProcessInfo.processInfo.systemUptime - uptime
            let delivered = session.deliveredFrameCount - frames
            let completed = live.surface.completedFrames - renders
            performance = ["scope": "Own animated calibration window; not a camera or physical Sidecar benchmark",
                "durationSeconds": duration, "nativeSourceWidth": nativeSize.width, "nativeSourceHeight": nativeSize.height,
                "liveViewers": 1, "independentlyFrozenViewers": frozen.count, "captureStreams": model.sessions.count,
                "deliveredFrames": delivered, "deliveredFPS": Double(delivered) / duration,
                "cpuPercentOfOneCore": (cpuSeconds() - cpu) / duration * 100,
                "completedViewerRenders": completed,
                "meanGPUTimeMilliseconds": completed > 0 ? (live.surface.totalGPUTime - gpu) / Double(completed) * 1000 : 0,
                "droppedRenderRequests": live.surface.droppedRenders]
            check(delivered >= 20, "Four independently frozen viewers do not starve the live capture pool")
            check(live.infoRefreshCount == labels, "Ordinary frames do not recalculate pixel-information labels")
            check(session.latestFrame?.image.extent.size == nativeSize, "Stress test never reduces capture resolution")

            let crop = ImageCrop(left: 0.1, top: 0.05), viewport = ImageViewport(zoom: 2, pan: CGPoint(x: 0.2, y: -0.1))
            live.options.crop = crop; live.options.viewport = viewport; live.options.showGrid = true
            model.prepareForSleep()
            await waitUntil { !session.active && !session.starting }
            check(!session.active && session.latestFrame == nil, "Sleep releases the capture stream and live buffers")
            model.resumeAfterSleep()
            await waitUntil { session.active && session.latestFrame != nil }
            check(session.active && session.latestFrame?.image.extent.size == nativeSize,
                  "Wake restarts the same selected source at native resolution")
            check(live.options.crop == crop && live.options.viewport == viewport && live.options.showGrid,
                  "Wake preserves independent crop, grid, zoom, and pan")

            live.perform(.pause)
            await waitUntil { !session.active }
            check(!session.active && session.latestFrame == nil, "All-frozen viewers stop unnecessary capture work")
            live.perform(.pause)
            check(live.surface.frameImage?.extent.size == nativeSize && live.hasOwnedFrozenImage,
                  "Resume keeps the full-resolution snapshot visible while capture restarts")
            await waitUntil { session.active && session.latestFrame != nil }
            check(session.active && session.latestFrame?.image.extent.size == nativeSize,
                  "Resuming a frozen viewer restores full-resolution capture")

            live.window?.miniaturize(nil)
            await waitUntil { !session.active }
            let accepted = live.acceptedFrames
            try? await Task.sleep(for: .milliseconds(250))
            check(!session.active && live.surface.frameImage == nil && live.acceptedFrames == accepted,
                  "Minimized viewers release live frames and stop capture when no live viewer is visible")
            live.window?.deminiaturize(nil)
            await waitUntil { session.active && live.surface.frameImage != nil }
            check(session.active && live.surface.frameImage?.extent.size == nativeSize,
                  "Restoring a viewer resumes native pixels without recreating its settings")
            let lastFrame = session.latestFrame
            model.shutdown(); verificationModel = nil
            animationTimer?.invalidate(); animationTimer = nil
            for viewer in viewers { viewer.showWindow(nil) }
            try? await Task.sleep(for: .milliseconds(150))
            if let lastFrame { for viewer in viewers { viewer.receive(lastFrame) } }
        } catch { check(false, "Pipeline verification: \(error.localizedDescription)") }
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

    private func verifyViewerControls(target: CGSize, sourceSize: CGSize, engine: RenderEngine) {
        guard let viewer = viewers.first else { return }
        let surface = viewer.surface
        let baseline = surface.renderedImage(size: target)
        viewer.perform(.grid)
        let gridded = surface.renderedImage(size: target)
        let placement = ImageGeometry.placement(source: sourceSize, destination: target, mode: .fit)
        let x = placement.minX + placement.width / 3, y = placement.minY + placement.height / 4
        let plainPixel = pixel(baseline, x: x, y: y), gridPixel = pixel(gridded, x: x, y: y)
        check(gridPixel[0] > plainPixel[0] + 50 && gridPixel[1] > plainPixel[1] + 50,
              "Rule of thirds grid renders over the image through the real GPU pipeline")
        check(pixel(gridded, x: 10, y: 540).prefix(3).allSatisfy { $0 < 10 },
              "Grid stays off the letterbox bars")
        check(!viewers[1].options.showGrid && viewers[1].options.viewport == .identity,
              "Grid and zoom controls are independent for each copy")
        save(gridded, name: "grid.png", engine: engine)
        viewer.perform(.grid)
        viewer.perform(.zoomIn)
        check(abs(viewer.options.viewport.zoom - 1.25) < 0.001, "Zoom In changes this viewer's magnification")
        let zoomed = surface.renderedImage(size: target)
        check(pixel(zoomed, x: 100, y: 270).prefix(3).contains { $0 > 220 }, "Zoom magnifies rendered pixels")
        save(zoomed, name: "zoom-125-percent.png", engine: engine)
        viewer.perform(.resetZoom)
        check(viewer.options.viewport == .identity, "Reset Zoom recenters and restores base sizing")
        verifyOverlayResolution(viewer, context: "Windowed")
        if let grid = viewer.floatingControls.button(for: .grid),
           let plus = viewer.floatingControls.button(for: .zoomIn),
           let fit = viewer.floatingControls.button(for: .fit) {
            grid.performClick(nil)
            check(viewer.options.showGrid, "Floating Grid button toggles this copy's overlay")
            samples["floatingControlState"] = "plus=\(plus.isEnabled), visible=\(viewer.window?.isVisible ?? false), occlusion=\(viewer.window?.occlusionState.rawValue ?? 0), frame=\(viewer.surface.frameImage != nil)"
            plus.performClick(nil)
            check(viewer.options.viewport.zoom > 1, "Floating plus button magnifies this copy")
            fit.performClick(nil)
            check(viewer.options.mode == .fit && viewer.options.viewport == .identity,
                  "Floating Fit button restores fit without resizing the viewer")
            grid.performClick(nil)
        } else { check(false, "Floating controls are available") }

        // Exercise the same native AppKit control actions Sidecar presents to the user.
        if let bar = viewer.touchBar,
           let grid = (bar.item(forIdentifier: MirrorWindowController.touchGridID) as? NSCustomTouchBarItem)?.view as? NSButton,
           let zoom = bar.item(forIdentifier: MirrorWindowController.touchZoomID) as? NSGroupTouchBarItem,
           let plus = (zoom.groupTouchBar.item(forIdentifier: MirrorWindowController.touchZoomInID) as? NSCustomTouchBarItem)?.view as? NSButton,
           let minus = (zoom.groupTouchBar.item(forIdentifier: MirrorWindowController.touchZoomOutID) as? NSCustomTouchBarItem)?.view as? NSButton,
           let fit = (zoom.groupTouchBar.item(forIdentifier: MirrorWindowController.touchFitID) as? NSCustomTouchBarItem)?.view as? NSButton,
           let pause = (bar.item(forIdentifier: MirrorWindowController.touchPauseID) as? NSCustomTouchBarItem)?.view as? NSButton {
            grid.performClick(nil)
            check(viewer.options.showGrid, "Native Sidecar Touch Bar Grid button toggles the overlay")
            plus.performClick(nil)
            check(viewer.options.viewport.zoom > 1, "Native Sidecar Touch Bar plus button zooms the viewer")
            // Published options update native enabled states on the next run-loop turn.
            minus.isEnabled = true
            minus.performClick(nil)
            check(abs(viewer.options.viewport.zoom - 1) < 0.001, "Native Sidecar Touch Bar minus button zooms out")
            viewer.perform(.zoomIn)
            fit.performClick(nil)
            check(viewer.options.mode == .fit && viewer.options.viewport == .identity,
                  "Native Sidecar Touch Bar Fit button resets zoom and pan")
            pause.performClick(nil)
            check(viewer.options.paused, "Native Sidecar Touch Bar Freeze button pauses the viewer")
            pause.performClick(nil); grid.performClick(nil)
        } else { check(false, "Native Sidecar Touch Bar controls are available") }
    }

    private func verifyOverlayResolution(_ viewer: MirrorWindowController, context: String) {
        guard let window = viewer.window else { check(false, "Missing viewer for resolution check"); return }
        let surface = viewer.surface
        surface.layoutSubtreeIfNeeded()
        surface.draw()
        let frame = window.frame, bounds = surface.bounds, drawable = surface.drawableSize
        let backing = surface.convertToBacking(bounds), scale = window.backingScaleFactor
        let source = surface.frameImage?.extent
        let mode = viewer.options.mode, crop = viewer.options.crop, viewport = viewer.options.viewport
        let initialVisibility = viewer.options.showQuickControls
        func displayMode() -> [Int]? {
            guard let id = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let mode = CGDisplayCopyDisplayMode(id.uint32Value) else { return nil }
            return [mode.width, mode.height, mode.pixelWidth, mode.pixelHeight]
        }
        let display = displayMode()
        viewer.perform(.quickControls)
        surface.layoutSubtreeIfNeeded()
        surface.draw()
        check(viewer.floatingControls.isHidden == initialVisibility, "\(context) floating controls toggle visibility")
        check(window.frame == frame && surface.bounds == bounds && surface.drawableSize == drawable &&
              surface.convertToBacking(surface.bounds) == backing && window.backingScaleFactor == scale,
              "\(context) controls preserve viewer size, drawable pixels, and backing scale")
        check(displayMode() == display && surface.frameImage?.extent == source,
              "\(context) controls preserve display mode and captured image resolution")
        check(viewer.options.mode == mode && viewer.options.crop == crop && viewer.options.viewport == viewport,
              "\(context) controls preserve fit, crop, zoom, and pan")
        viewer.perform(.quickControls)
        surface.layoutSubtreeIfNeeded()
        surface.draw()
        check(window.frame == frame && surface.drawableSize == drawable && viewer.options.showQuickControls == initialVisibility,
              "\(context) showing controls again preserves the original pixel dimensions")
    }

    private func verifyFullscreen() {
        guard let viewer = viewers.first, let window = viewer.window else {
            finish(error: "Missing viewer for fullscreen check"); return
        }
        let originalFrame = window.frame
        let crop = ImageCrop(left: 0.1, top: 0.05, right: 0.02, bottom: 0.03)
        viewer.options.crop = crop
        viewer.options.mode = .fill
        viewer.options.showGrid = true
        let viewport = ImageViewport(zoom: 2, pan: CGPoint(x: 0.25, y: -0.3))
        viewer.options.viewport = viewport
        window.level = .floating
        viewer.onFullscreenStateChange = { [weak self, weak viewer] entered in
            guard let self, let viewer, let window = viewer.window else { return }
            if entered {
                self.check(window.styleMask.contains(.fullScreen), "Viewer enters a native fullscreen Space")
                self.check(NSApp.activationPolicy() == .regular, "Native app menus are available in fullscreen")
                let presentation = NSApp.currentSystemPresentationOptions
                self.metadata["systemPresentationOptions"] = "\(presentation.rawValue)"
                self.metadata["requestedPresentationOptions"] = "\(viewer.fullscreenPresentationOptions.rawValue)"
                self.check(presentation.contains(.autoHideToolbar), "Native toolbar is configured to reveal on rollover")
                self.check(viewer.fullscreenPresentationOptions.contains(.autoHideMenuBar),
                           "Viewer requests native top-edge menu reveal")
                // macOS can keep the menu bar visible according to the user's setting.
                self.check(!presentation.contains(.hideMenuBar) || presentation.contains(.autoHideMenuBar),
                           "System keeps the native menu bar accessible in fullscreen")
                self.check(viewer.options.crop == crop && viewer.options.mode == .fill,
                           "Fullscreen preserves the copy's crop and fit settings")
                self.check(viewer.options.showGrid && viewer.options.viewport == viewport,
                           "Fullscreen preserves independent grid, zoom, and pan")
                self.verifyOverlayResolution(viewer, context: "Fullscreen")
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    viewer.perform(.fullscreen)
                }
            } else {
                self.check(!window.styleMask.contains(.fullScreen), "Viewer exits native fullscreen")
                self.check(abs(window.frame.width - originalFrame.width) < 2 &&
                           abs(window.frame.height - originalFrame.height) < 2, "Fullscreen restores the original window size")
                self.check(window.level == .floating, "Fullscreen restores Keep on Top")
                self.check(window.toolbar?.isVisible == true, "Windowed controls remain available after fullscreen")
                self.check(NSApp.activationPolicy() == .accessory, "App returns to menu bar utility mode after fullscreen")
                self.finish(error: self.failure)
            }
        }
        viewer.perform(.fullscreen)
    }

    private func check(_ condition: Bool, _ name: String) {
        if condition { checks.append(name) } else if failure == nil { failure = name }
    }

    private func pixel(_ image: CIImage, x: CGFloat, y: CGFloat) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            engine?.context.render(image, toBitmap: buffer.baseAddress!, rowBytes: 4,
                                   bounds: CGRect(x: floor(x), y: floor(y), width: 1, height: 1),
                                   format: .RGBA8, colorSpace: engine?.colorSpace)
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

private final class ProbePattern: NSView {
    var animate = false
    var tick = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(roundedRect: bounds, xRadius: 20, yRadius: 20).addClip()
        let halfW = bounds.width / 2, halfH = bounds.height / 2
        for (color, rect) in [
            (NSColor.red, NSRect(x: 0, y: 0, width: halfW, height: halfH)),
            (.green, NSRect(x: halfW, y: 0, width: halfW, height: halfH)),
            (.blue, NSRect(x: 0, y: halfH, width: halfW, height: halfH)),
            (.yellow, NSRect(x: halfW, y: halfH, width: halfW, height: halfH))
        ] { color.setFill(); rect.fill() }
        if animate {
            NSColor.white.setFill()
            let travel = max(1, Int(bounds.width - 80))
            let x = CGFloat(30 + tick % travel)
            NSRect(x: x, y: bounds.height - 45, width: 20, height: 20).fill()
        }
    }
}
