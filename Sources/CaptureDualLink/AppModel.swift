import AppKit
import SwiftUI
import ScreenCaptureKit
import DualLinkCore

@MainActor
final class AppModel: ObservableObject {
    @Published var sources: [WindowSource] = []
    @Published var selectedID: CGWindowID?
    @Published var search = ""
    @Published var loading = false
    @Published var creating = false
    @Published var hasPermission = CGPreflightScreenCaptureAccess()
    @Published var message: String?
    @Published var mirrorCount = 0
    @Published var detail: CaptureDetail {
        didSet { if persistPreferences { UserDefaults.standard.set(detail.rawValue, forKey: "captureDetail") } }
    }
    @Published var fps: Int {
        didSet { if persistPreferences { UserDefaults.standard.set(fps, forKey: "captureFPS") } }
    }
    var onCountChange: (() -> Void)?
    var onShowPicker: (() -> Void)?
    private(set) var sessions: [CGWindowID: CaptureSession] = [:]
    private(set) var mirrors: [UUID: MirrorWindowController] = [:]
    private var engine: RenderEngine?
    private var pollTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var recovery: [CGWindowID: RecoveryBackoff] = [:]
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var sleeping = false
    private var shuttingDown = false
    private var sequence = 0
    private var displayCheckTimer: Timer?
    private var displayCheckFrame: Int = 0
    private var displayCheckBase: CIImage?
    private let displayCheckID = CGWindowID.max
    private let activeContent: @MainActor () async throws -> SCShareableContent
    private let persistPreferences: Bool

    init(persistPreferences: Bool = true, activeContent: @escaping @MainActor () async throws -> SCShareableContent = {
        try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
    }) {
        self.activeContent = activeContent
        self.persistPreferences = persistPreferences
        detail = CaptureDetail(rawValue: UserDefaults.standard.string(forKey: "captureDetail") ?? "") ?? .native
        let savedFPS = UserDefaults.standard.integer(forKey: "captureFPS")
        fps = [15, 30, 60].contains(savedFPS) ? savedFPS : 30
        engine = RenderEngine()
        observe(NSWorkspace.willSleepNotification, center: NSWorkspace.shared.notificationCenter) { $0.prepareForSleep() }
        observe(NSWorkspace.screensDidSleepNotification, center: NSWorkspace.shared.notificationCenter) { $0.prepareForSleep() }
        observe(NSWorkspace.didWakeNotification, center: NSWorkspace.shared.notificationCenter) { $0.resumeAfterSleep() }
        observe(NSWorkspace.screensDidWakeNotification, center: NSWorkspace.shared.notificationCenter) { $0.resumeAfterSleep() }
        observe(NSApplication.didChangeScreenParametersNotification, center: .default) { $0.scheduleActivityRefresh() }
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter,
                         action: @escaping @MainActor (AppModel) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }

    func prepareForSleep() {
        guard !sleeping, !shuttingDown else { return }
        sleeping = true
        displayCheckTimer?.invalidate(); displayCheckTimer = nil
        activityTask?.cancel(); activityTask = nil
        pollTask?.cancel(); pollTask = nil
        for mirror in mirrors.values { mirror.releaseLiveFrame() }
        Task { [weak self] in
            guard let self else { return }
            for (id, session) in Array(self.sessions) {
                guard self.sleeping, self.sessions[id] === session else { continue }
                await session.stop()
            }
        }
    }

    func resumeAfterSleep() {
        guard !shuttingDown else { return }
        sleeping = false
        updateDisplayCheckActivity()
        recovery.removeAll()
        startPollingIfNeeded()
        scheduleActivityRefresh()
    }

    func shutdown() {
        shuttingDown = true
        activityTask?.cancel(); activityTask = nil
        pollTask?.cancel(); pollTask = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        closeAll()
    }

    var filteredSources: [WindowSource] {
        sources.filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) }
    }

    func requestPermission() {
        if CGRequestScreenCaptureAccess() {
            hasPermission = true
            Task { await refreshSources() }
        } else {
            message = "Enable Capture DualLink in Screen Recording settings, then click Refresh. macOS may ask you to quit and reopen the app."
            openPermissionSettings()
        }
    }

    func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshSources() async {
        hasPermission = CGPreflightScreenCaptureAccess()
        guard hasPermission, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            sources = content.windows.filter {
                $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier &&
                $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 60
            }.map(WindowSource.init).sorted { a, b in
                if a.isCaptureOne != b.isCaptureOne { return a.isCaptureOne }
                let aLive = a.title.localizedCaseInsensitiveContains("live view")
                let bLive = b.title.localizedCaseInsensitiveContains("live view")
                if aLive != bLive { return aLive }
                return a.label.localizedStandardCompare(b.label) == .orderedAscending
            }
            if !sources.contains(where: { $0.id == selectedID }) { selectedID = sources.first?.id }
            message = sources.isEmpty ? "Open Capture One's Live View window, then click Refresh." : nil
        } catch {
            message = "Could not list windows: \(error.localizedDescription)"
        }
    }

    func duplicateSelected() async {
        guard !creating, let id = selectedID, let source = sources.first(where: { $0.id == id }) else { return }
        creating = true
        defer { creating = false }
        await duplicate(source)
    }

    func duplicate(_ source: WindowSource) async {
        guard engine != nil else { message = "A Metal-compatible GPU is required to display copies."; return }
        if let existing = sessions[source.id] {
            let mirror = makeMirror(sourceID: source.id, title: source.label)
            if let frame = existing.latestFrame { mirror?.receive(frame) }
            startPollingIfNeeded(); scheduleActivityRefresh()
            return
        }
        if let previous = sessions.removeValue(forKey: source.id) { await previous.stop() }
        let session = CaptureSession(source: source, detail: detail, fps: fps)
        sessions[source.id] = session
        let mirror = makeMirror(sourceID: source.id, title: source.label)
        session.onFrame = { [weak self, weak session] frame in
            guard let self, let session, self.sessions[source.id] === session else { return }
            self.recovery[source.id]?.reset()
            for mirror in self.mirrors.values where mirror.sourceID == source.id { mirror.receive(frame) }
        }
        session.onStatus = { [weak self, weak session] message in
            guard let self, let session, self.sessions[source.id] === session else { return }
            for mirror in self.mirrors.values where mirror.sourceID == source.id {
                if session.failed { mirror.releaseLiveFrame() }
                mirror.showStatus(message)
            }
            if session.failed { self.scheduleActivityRefresh() }
        }
        do {
            // Obtain a fresh SCWindow; the picker may have been open during a resize.
            let content = try await activeContent()
            guard let window = content.windows.first(where: { $0.windowID == source.id }) else {
                throw NSError(domain: "CaptureDualLink", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The source window closed. Refresh and select its replacement."])
            }
            try await session.start(window: window)
            guard sessions[source.id] === session, !shuttingDown else { await session.stop(); return }
            message = nil
            startPollingIfNeeded()
        } catch {
            sessions.removeValue(forKey: source.id)
            await session.stop()
            mirror?.close()
            message = "Could not duplicate window: \(error.localizedDescription)"
            onShowPicker?()
        }
    }

    private func makeMirror(sourceID: CGWindowID, title: String) -> MirrorWindowController? {
        guard let engine else { return nil }
        sequence += 1
        let mirror = MirrorWindowController(sourceID: sourceID, title: title, sequence: sequence, engine: engine)
        mirror.onRequestFrame = { [weak self] in self?.sessions[sourceID]?.latestFrame }
        mirror.onActivityChange = { [weak self] in
            self?.updateDisplayCheckActivity()
            self?.scheduleActivityRefresh()
        }
        mirror.onClose = { [weak self] id in self?.removeMirror(id) }
        mirror.onDuplicate = { [weak self] in
            guard let self else { return }
            if sourceID == self.displayCheckID { self.openDisplayCheck(); return }
            guard let session = self.sessions[sourceID] else { return }
            let extra = self.makeMirror(sourceID: sourceID, title: session.label)
            if let frame = session.latestFrame { extra?.receive(frame) }
        }
        mirrors[mirror.id] = mirror
        mirror.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateCount()
        return mirror
    }

    private func removeMirror(_ id: UUID) {
        guard let mirror = mirrors.removeValue(forKey: id) else { return }
        let sourceID = mirror.sourceID
        if !mirrors.values.contains(where: { $0.sourceID == sourceID }) {
            if let session = sessions.removeValue(forKey: sourceID) { Task { await session.stop() } }
            recovery.removeValue(forKey: sourceID)
            if sourceID == displayCheckID {
                displayCheckTimer?.invalidate(); displayCheckTimer = nil; displayCheckBase = nil
            }
        }
        if sessions.isEmpty { pollTask?.cancel(); pollTask = nil }
        updateCount()
    }

    private func updateCount() { mirrorCount = mirrors.count; onCountChange?() }

    func closeAll() {
        for mirror in Array(mirrors.values) { mirror.close() }
    }

    func applyCaptureSettings() {
        for session in sessions.values { session.detail = detail; session.fps = fps }
        Task { await refreshActiveSources() }
    }

    private func startPollingIfNeeded() {
        guard pollTask == nil, !sessions.isEmpty, !sleeping, !shuttingDown else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let delay = self?.pollingDelay ?? 2
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { break }
                await self?.refreshActiveSources()
            }
        }
    }

    private var pollingDelay: Double {
        if sessions.contains(where: { $0.value.active && hasDemand(for: $0.key) }) { return 2 }
        let now = ProcessInfo.processInfo.systemUptime
        let waits = sessions.keys.filter { hasDemand(for: $0) }.map { max(0.5, (recovery[$0]?.nextAttempt ?? now) - now) }
        return min(15, waits.min() ?? 15)
    }

    private func hasDemand(for id: CGWindowID) -> Bool {
        mirrors.values.contains { $0.sourceID == id && $0.wantsLiveFrames }
    }

    private func scheduleActivityRefresh() {
        guard !sleeping, !shuttingDown else { return }
        activityTask?.cancel()
        activityTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            await self.refreshActiveSources()
        }
    }

    private var refreshingActive = false
    private func refreshActiveSources() async {
        guard !sessions.isEmpty, !refreshingActive, !sleeping, !shuttingDown else { return }
        refreshingActive = true
        defer { refreshingActive = false }
        do {
            // Stop capture altogether when every copy is frozen or offscreen.
            for (id, session) in Array(sessions) where !hasDemand(for: id) {
                guard sessions[id] === session else { continue }
                if session.active || session.failed { await session.stop() }
            }
            let now = ProcessInfo.processInfo.systemUptime
            let candidates = Array(sessions).filter { id, session in
                hasDemand(for: id) && (session.active || (recovery[id] ?? RecoveryBackoff()).isReady(at: now))
            }
            guard !candidates.isEmpty else { return }
            let content = try await activeContent()
            // Copy the collection before awaiting; windows can close while an update runs.
            for (id, session) in candidates {
                guard sessions[id] === session, !session.starting, hasDemand(for: id), !sleeping,
                      !shuttingDown, !Task.isCancelled else { continue }
                do {
                    if let window = content.windows.first(where: {
                        $0.windowID == id && $0.owningApplication?.processID == session.sourceProcessID
                    }) {
                        if session.active { try await session.refresh(window: window) }
                        else {
                            session.onStatus?("Reconnecting to the selected window…")
                            try await session.start(window: window)
                            recovery[id]?.reset()
                        }
                    } else {
                        await session.stop()
                        for mirror in mirrors.values where mirror.sourceID == id { mirror.releaseLiveFrame() }
                        session.onStatus?("Source window closed. Select its replacement from the menu bar.")
                        recovery[id, default: RecoveryBackoff()].failed(at: now)
                    }
                } catch {
                    guard sessions[id] === session else { continue }
                    await session.stop()
                    for mirror in mirrors.values where mirror.sourceID == id { mirror.releaseLiveFrame() }
                    recovery[id, default: RecoveryBackoff()].failed(at: ProcessInfo.processInfo.systemUptime)
                    session.onStatus?("Capture interrupted. Retrying the selected window…")
                }
            }
        } catch {
            message = "Window update failed: \(error.localizedDescription)"
        }
    }

    /// A moving pixel grid verifies sizing and aspect ratio without screen-recording access.
    func openDisplayCheck() {
        _ = makeMirror(sourceID: displayCheckID, title: "Display Check")
        updateDisplayCheckActivity()
    }

    private func updateDisplayCheckActivity() {
        guard !sleeping, !shuttingDown,
              mirrors.values.contains(where: { $0.sourceID == displayCheckID && $0.wantsLiveFrames }) else {
            displayCheckTimer?.invalidate(); displayCheckTimer = nil
            return
        }
        guard displayCheckTimer == nil else { return }
        renderDisplayCheck()
        displayCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderDisplayCheck() }
        }
    }

    private func renderDisplayCheck() {
        guard !sleeping, mirrors.values.contains(where: { $0.sourceID == displayCheckID && $0.wantsLiveFrames }) else { return }
        displayCheckFrame += 1
        let size = CGSize(width: 1920, height: 1080)
        if let base = displayCheckBase {
            let bar = CIImage(color: CIColor(red: 0.1, green: 0.82, blue: 0.72))
                .cropped(to: CGRect(x: 80 + displayCheckFrame % 1760, y: 190, width: 12, height: 70))
            let frame = CapturedFrame(image: bar.composited(over: base), nativeSize: size)
            for mirror in mirrors.values where mirror.sourceID == displayCheckID { mirror.receive(frame) }
            return
        }
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor(calibratedWhite: 0.055, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            NSColor(calibratedWhite: 0.16, alpha: 1).setStroke()
            let grid = NSBezierPath()
            for x in stride(from: 0, through: 1920, by: 60) {
                grid.move(to: NSPoint(x: x, y: 0)); grid.line(to: NSPoint(x: x, y: 1080))
            }
            for y in stride(from: 0, through: 1080, by: 60) {
                grid.move(to: NSPoint(x: 0, y: y)); grid.line(to: NSPoint(x: 1920, y: y))
            }
            grid.stroke()
            NSColor.systemMint.setStroke()
            let circle = NSBezierPath(ovalIn: NSRect(x: 690, y: 270, width: 540, height: 540))
            circle.lineWidth = 5; circle.stroke()
            let heading: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 54, weight: .semibold), .foregroundColor: NSColor.white]
            ("Capture DualLink" as NSString).draw(at: NSPoint(x: 80, y: 910), withAttributes: heading)
            let note: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 26, weight: .regular), .foregroundColor: NSColor.lightGray]
            ("1920 × 1080  •  The circle should stay round" as NSString).draw(at: NSPoint(x: 80, y: 845), withAttributes: note)
            ("Drag this window to your iPad. Right-click for sizing and crop." as NSString).draw(at: NSPoint(x: 80, y: 90), withAttributes: note)
            return true
        }
        // Rasterize at exactly 1920 × 1080; NSImage otherwise chooses the source
        // display's Retina representation and makes this calibration label misleading.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width),
                                            pixelsHigh: Int(size.height), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = bitmap.cgImage else { return }
        displayCheckBase = CIImage(cgImage: cg)
        let frame = CapturedFrame(image: displayCheckBase!, nativeSize: size)
        for mirror in mirrors.values where mirror.sourceID == displayCheckID { mirror.receive(frame) }
    }
}
