import AppKit
import ScreenCaptureKit
import CoreImage
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
                if CommandLine.arguments.contains("--check-performance"), failure == nil { await verifyPipeline() }
                if CommandLine.arguments.contains("--check-fullscreen"), failure == nil {
                    verifyFullscreen()
                } else { finish(error: failure) }
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
        session.onStatus = { [weak self] status in if let status { self?.finish(error: status) } }
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
            await waitUntil { copies.allSatisfy { $0.surface.completedFrames > 0 } }
            let frames = session.deliveredFrameCount
            let renders = copies.map { $0.surface.completedFrames }
            let gpu = copies.reduce(0) { $0 + $1.surface.totalGPUTime }
            let dropped = copies.reduce(0) { $0 + $1.surface.droppedRenders }
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
            model.shutdown(); verificationModel = nil
            animationTimer?.invalidate(); animationTimer = nil
            for viewer in viewers { viewer.showWindow(nil) }
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

    // MARK: Native fullscreen

    private func verifyFullscreen() {
        guard let viewer = viewers.first, let window = viewer.window else {
            finish(error: "Missing viewer for fullscreen check"); return
        }
        let originalFrame = window.frame
        viewer.options.mode = .fill
        viewer.options.showGrid = true
        window.level = .floating
        viewer.onFullscreenStateChange = { [weak self, weak viewer] entered in
            guard let self, let viewer, let window = viewer.window else { return }
            if entered {
                self.check(window.styleMask.contains(.fullScreen), "Viewer enters a native fullscreen Space")
                self.check(NSApp.activationPolicy() == .regular, "Native app menus are available in fullscreen")
                let presentation = NSApp.currentSystemPresentationOptions
                self.metadata["systemPresentationOptions"] = "\(presentation.rawValue)"
                self.check(presentation.contains(.autoHideToolbar), "Native toolbar is configured to reveal on rollover")
                self.check(viewer.fullscreenPresentationOptions.contains(.autoHideMenuBar),
                           "Viewer requests native top-edge menu reveal")
                self.check(viewer.options.mode == .fill && viewer.options.showGrid,
                           "Fullscreen preserves the copy's fit and grid")
                let backing = viewer.surface.convertToBacking(viewer.surface.bounds).size
                self.check(viewer.surface.drawableSize == backing, "Fullscreen renders at the display's backing pixels")
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
