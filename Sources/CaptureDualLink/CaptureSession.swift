import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage
import DualLinkCore

enum CaptureDetail: String, CaseIterable, Identifiable {
    case native = "Native / Retina"
    case balanced = "Balanced · 2560 px maximum"
    case light = "Light · 1920 px maximum"
    var id: String { rawValue }
    var maximumEdge: Int? {
        switch self { case .native: return nil; case .balanced: return 2560; case .light: return 1920 }
    }
}

struct WindowSource: Identifiable {
    let window: SCWindow
    var id: CGWindowID { window.windowID }
    var app: String { window.owningApplication?.applicationName ?? "Application" }
    var title: String { window.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled window" }
    var label: String { "\(app) — \(title)" }
    var isCaptureOne: Bool { app.localizedCaseInsensitiveContains("capture one") }
    /// Trim is remembered per source application on this Mac.
    var settingsKey: String { window.owningApplication?.bundleIdentifier ?? app }
}

struct CapturedFrame {
    /// The trimmed source, with its origin at zero.
    let image: CIImage
    let nativeSize: CGSize
    /// The camera picture within `image` in Core Image coordinates, once detected.
    let pictureArea: CGRect?
}

private struct CapturePacket {
    let frame: CapturedFrame
    let metadata: [String: String]
    let geometryChanged: Bool
}

@MainActor
final class CaptureSession: NSObject, SCStreamDelegate {
    let sourceID: CGWindowID
    let label: String
    let sourceProcessID: pid_t?
    var detail: CaptureDetail
    var fps: Int
    var trim: SourceTrim { didSet { output?.setTrim(trim) } }
    var onFrame: ((CapturedFrame) -> Void)?
    var onStatus: ((String?) -> Void)?
    var onMetadata: (([String: String]) -> Void)?
    /// The source no longer fills the configured capture size (resize or display change).
    var onGeometryChange: (() -> Void)?
    /// ScreenCaptureKit stopped a running stream; called once per failure.
    var onFailure: (() -> Void)?
    private(set) var latestFrame: CapturedFrame?
    private(set) var failed = false
    private(set) var active = false
    private(set) var starting = false
    private(set) var deliveredFrameCount = 0
    private var stream: SCStream?
    private var stopped = false
    private var configurationKey = ""
    /// The content scale the current configuration produces: 1 at native size, below 1
    /// for Balanced/Light. Frames that depart from it mean the source window changed.
    private var expectedContentScale: CGFloat = 1
    private var generation = UUID()
    private var output: CaptureOutput?
    private let queue = DispatchQueue(label: "com.captureduallink.frames", qos: .userInteractive)

    init(source: WindowSource, detail: CaptureDetail, fps: Int, trim: SourceTrim = .none) {
        sourceID = source.id; label = source.label; self.detail = detail; self.fps = fps; self.trim = trim
        sourceProcessID = source.window.owningApplication?.processID
    }

    func start(window: SCWindow) async throws {
        guard !starting else { return }
        starting = true
        defer { starting = false }
        if stream != nil { await stop() }
        try Task.checkCancellation()
        stopped = false
        failed = false
        let token = UUID()
        generation = token
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = configuration(filter: filter)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        let output = CaptureOutput(trim: trim, expectedScale: expectedContentScale, includeMetadata: onMetadata != nil, onFrame: { [weak self] packet in
            guard let self, !self.stopped, self.generation == token else { return }
            self.latestFrame = packet.frame
            self.deliveredFrameCount += 1
            self.onMetadata?(packet.metadata)
            self.onFrame?(packet.frame)
            if packet.geometryChanged { self.onGeometryChange?() }
        }, onStatus: { [weak self] message in
            guard let self, !self.stopped, self.generation == token else { return }
            self.onStatus?(message)
        })
        self.output = output
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            if generation == token { failed = true; await stop() }
            throw error
        }
        guard !stopped, generation == token else {
            output.invalidate()
            try? await stream.stopCapture()
            throw CancellationError()
        }
        active = true
    }

    func refresh(window: SCWindow) async throws {
        guard active, let stream else { return }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        // Refresh when the source is resized or moves to a display with another pixel density.
        guard key(filter: filter) != configurationKey else { return }
        let previousKey = configurationKey, previousScale = expectedContentScale
        let config = configuration(filter: filter)
        do {
            try await stream.updateConfiguration(config)
            output?.setExpectedScale(expectedContentScale)
        } catch { configurationKey = previousKey; expectedContentScale = previousScale; throw error }
    }

    private func key(filter: SCContentFilter) -> String {
        "\(filter.contentRect.width):\(filter.contentRect.height):\(filter.pointPixelScale):\(detail.rawValue):\(fps)"
    }

    private func configuration(filter: SCContentFilter) -> SCStreamConfiguration {
        let size = ImageGeometry.captureSize(points: filter.contentRect.size,
                                             pixelScale: CGFloat(filter.pointPixelScale),
                                             maximumEdge: detail.maximumEdge)
        configurationKey = key(filter: filter)
        let nativeWidth = filter.contentRect.width * CGFloat(filter.pointPixelScale)
        expectedContentScale = nativeWidth > 0 ? min(1, size.width / nativeWidth) : 1
        let config = SCStreamConfiguration()
        config.width = Int(size.width); config.height = Int(size.height)
        config.captureResolution = .best
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // Capture One color-manages Live View for wide-gamut displays; sRGB would clip it.
        config.colorSpaceName = CGColorSpace.displayP3
        config.showsCursor = false
        config.capturesAudio = false
        config.scalesToFit = false
        config.preservesAspectRatio = true
        config.ignoreShadowsSingleWindow = true
        // ScreenCaptureKit's opaque mode fills transparent window corners with
        // white. Preserve alpha so the viewer can blend them into its background.
        config.shouldBeOpaque = false
        config.streamName = "Capture DualLink"
        return config
    }

    func stop() async {
        stopped = true; active = false; failed = false
        generation = UUID()
        output?.invalidate(); output = nil
        latestFrame = nil
        let old = stream; stream = nil
        try? await old?.stopCapture()
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, !self.stopped, self.stream === stream else { return }
            self.active = false
            self.failed = true
            self.output?.invalidate()
            self.latestFrame = nil
            self.onStatus?("Capture interrupted. Reconnecting to the selected window…")
            self.onFailure?()
        }
    }
}

/// Capture parsing and picture detection stay on the capture queue;
/// all session state and callbacks stay on MainActor.
private final class CaptureOutput: NSObject, SCStreamOutput {
    private let mailbox = LatestValueMailbox<CapturePacket>()
    private let includeMetadata: Bool
    private let onFrame: @MainActor (CapturePacket) -> Void
    private let onStatus: @MainActor (String?) -> Void
    private let trimLock = NSLock()
    private var trimValue: SourceTrim
    private var expectedScaleValue: CGFloat
    // Capture-queue state.
    private var suspended: Bool?
    private var tracker = ImageAreaTracker()
    private var lastDetection: TimeInterval = 0
    private var lastRegion: CGSize = .zero
    private var lastGeometryReport: TimeInterval = 0

    init(trim: SourceTrim, expectedScale: CGFloat, includeMetadata: Bool, onFrame: @escaping @MainActor (CapturePacket) -> Void,
         onStatus: @escaping @MainActor (String?) -> Void) {
        trimValue = trim; expectedScaleValue = expectedScale
        self.includeMetadata = includeMetadata; self.onFrame = onFrame; self.onStatus = onStatus
    }

    func invalidate() { mailbox.invalidate() }

    func setTrim(_ trim: SourceTrim) {
        trimLock.lock(); trimValue = trim; trimLock.unlock()
    }

    func setExpectedScale(_ scale: CGFloat) {
        trimLock.lock(); expectedScaleValue = scale; trimLock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]], let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return }
        if status == .suspended || status == .blank || status == .stopped {
            if suspended != true {
                suspended = true
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.onStatus("Source paused. Restore the original window to resume.") }
                }
            }
            return
        }
        guard status == .complete || status == .started,
              let buffer = sampleBuffer.imageBuffer else { return }
        if suspended != false {
            suspended = false
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onStatus(nil) } }
        }
        let bufferSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let scale = (info[.scaleFactor] as? NSNumber)?.doubleValue ?? 1
        // Metadata uses logical points. Apply scaleFactor before cropping buffer pixels.
        let rectValue: CGRect?
        if let value = info[.contentRect] as? CGRect {
            rectValue = value
        } else if let value = info[.contentRect] as? [String: Any] {
            rectValue = CGRect(dictionaryRepresentation: value as CFDictionary)
        } else { rectValue = nil }
        var content = CGRect(origin: .zero, size: bufferSize)
        if let rectValue, rectValue.width > 0, rectValue.height > 0 {
            content = ImageGeometry.captureContentRect(points: rectValue, pixelScale: scale, bufferSize: bufferSize)
        }
        trimLock.lock(); let trim = trimValue, expectedScale = expectedScaleValue; trimLock.unlock()
        // When the window outgrows the configured size, ScreenCaptureKit scales it down to fit
        // until the configuration catches up; the trim must scale with it.
        let contentScale = (info[.contentScale] as? NSNumber)?.doubleValue ?? 1
        let contentTopLeft = ImageGeometry.flipped(content, height: bufferSize.height)
        let region = trim.apply(to: contentTopLeft, pixelScale: scale * contentScale)
        let regionCI = ImageGeometry.flipped(region, height: bufferSize.height)
        let image = CIImage(cvPixelBuffer: buffer).cropped(to: regionCI)
            .transformed(by: CGAffineTransform(translationX: -regionCI.minX, y: -regionCI.minY))

        let now = ProcessInfo.processInfo.systemUptime
        if region.size != lastRegion || now - lastDetection >= 1 {
            lastRegion = region.size; lastDetection = now
            let detected = detectPicture(in: buffer, region: region)
            _ = tracker.update(regionSize: region.size, detected: detected,
                               tolerance: max(4, max(region.width, region.height) / 200))
        }
        let picture = tracker.area.map { ImageGeometry.flipped($0, height: region.height) }

        // Report a resize or pixel-density change now rather than waiting for the next poll:
        // a larger window arrives scaled down; a smaller one leaves the buffer padded.
        let rescaled = abs(contentScale - expectedScale) > 0.01
        let padded = abs(content.width - bufferSize.width) > 2 || abs(content.height - bufferSize.height) > 2
        var geometryChanged = false
        if rescaled || padded, now - lastGeometryReport >= 0.5 {
            lastGeometryReport = now; geometryChanged = true
        }

        let frame = CapturedFrame(image: image, nativeSize: image.extent.size, pictureArea: picture)
        let metadata = !includeMetadata ? [:] : ["contentRect": "\(info[.contentRect] ?? "nil")",
                        "scaleFactor": "\(info[.scaleFactor] ?? "nil")",
                        "contentScale": "\(info[.contentScale] ?? "nil")",
                        "buffer": "\(CVPixelBufferGetWidth(buffer)) × \(CVPixelBufferGetHeight(buffer))",
                        "picture": picture.map { "\($0)" } ?? "nil"]
        mailbox.offer(CapturePacket(frame: frame, metadata: metadata, geometryChanged: geometryChanged)) { [weak self] packet in
            MainActor.assumeIsolated { self?.onFrame(packet) }
        }
    }

    /// Reads the BGRA buffer directly; sampling is strided inside the detector.
    private func detectPicture(in buffer: CVPixelBuffer, region: CGRect) -> CGRect? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let x0 = Int(region.minX), y0 = Int(region.minY)
        return ImageAreaDetector.detect(width: Int(region.width), height: Int(region.height)) { x, y in
            let pixel = base + (y0 + y) * rowBytes + (x0 + x) * 4
            return RGB(pixel[2], pixel[1], pixel[0])
        }
    }
}
