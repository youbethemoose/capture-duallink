import AppKit
import Combine
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
    /// A copy is ready; the delegate hides the picker and returns focus to the source app.
    var onDuplicated: ((pid_t?) -> Void)?
    private(set) var sessions: [CGWindowID: CaptureSession] = [:]
    private(set) var mirrors: [UUID: MirrorWindowController] = [:]
    private var trims: [CGWindowID: TrimModel] = [:]
    private var trimObservers: [CGWindowID: AnyCancellable] = [:]
    private var engine: RenderEngine?
    private var pollTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var recovery: [CGWindowID: RecoveryBackoff] = [:]
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var sleeping = false
    private var shuttingDown = false
    private var sequence = 0
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
            onDuplicated?(existing.sourceProcessID)
            return
        }
        let trimModel = TrimModel(appName: source.app, trim: savedTrim(for: source.settingsKey))
        trims[source.id] = trimModel
        let session = CaptureSession(source: source, detail: detail, fps: fps, trim: trimModel.trim)
        sessions[source.id] = session
        trimObservers[source.id] = trimModel.$trim.dropFirst().sink { [weak self, weak session] trim in
            session?.trim = trim
            self?.saveTrim(trim, for: source.settingsKey)
        }
        let mirror = makeMirror(sourceID: source.id, title: source.label)
        session.onFrame = { [weak self, weak session] frame in
            guard let self, let session, self.sessions[source.id] === session else { return }
            // Only a delivered frame proves recovery; a stream can start and die before one arrives.
            self.recovery[source.id]?.reset()
            for mirror in self.mirrors.values where mirror.sourceID == source.id { mirror.receive(frame) }
        }
        session.onStatus = { [weak self, weak session] message in
            guard let self, let session, self.sessions[source.id] === session else { return }
            for mirror in self.mirrors.values where mirror.sourceID == source.id {
                if session.failed { mirror.releaseLiveFrame() }
                mirror.showStatus(message)
            }
        }
        session.onFailure = { [weak self, weak session] in
            guard let self, let session, self.sessions[source.id] === session else { return }
            // Back off before reconnecting so a stream that keeps dying can't restart in a tight loop.
            self.recovery[source.id, default: RecoveryBackoff()].failed(at: ProcessInfo.processInfo.systemUptime)
            self.scheduleActivityRefresh()
        }
        session.onGeometryChange = { [weak self] in self?.scheduleActivityRefresh() }
        do {
            // Obtain a fresh SCWindow; the picker may have been open during a resize.
            let content = try await activeContent()
            guard let window = content.windows.first(where: { $0.windowID == source.id }) else {
                throw NSError(domain: "CaptureDualLink", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The source window closed. Refresh and select its replacement."])
            }
            guard sessions[source.id] === session, !shuttingDown else { await session.stop(); return }
            try await session.start(window: window)
            guard sessions[source.id] === session, !shuttingDown else { await session.stop(); return }
            message = nil
            startPollingIfNeeded()
            onDuplicated?(session.sourceProcessID)
        } catch {
            guard sessions[source.id] === session else { await session.stop(); return }
            sessions.removeValue(forKey: source.id)
            await session.stop()
            mirror?.close()
            message = "Could not duplicate window: \(error.localizedDescription)"
            onShowPicker?()
        }
    }

    private func savedTrim(for key: String) -> SourceTrim {
        guard persistPreferences, let data = UserDefaults.standard.data(forKey: "trim." + key),
              let trim = try? JSONDecoder().decode(SourceTrim.self, from: data) else { return .none }
        return trim
    }

    private func saveTrim(_ trim: SourceTrim, for key: String) {
        guard persistPreferences, let data = try? JSONEncoder().encode(trim) else { return }
        UserDefaults.standard.set(data, forKey: "trim." + key)
    }

    private func makeMirror(sourceID: CGWindowID, title: String) -> MirrorWindowController? {
        guard let engine, let trimModel = trims[sourceID] else { return nil }
        sequence += 1
        let mirror = MirrorWindowController(sourceID: sourceID, title: title, sequence: sequence,
                                            engine: engine, trimModel: trimModel,
                                            sourceProcessID: sessions[sourceID]?.sourceProcessID)
        mirror.onRequestFrame = { [weak self] in self?.sessions[sourceID]?.latestFrame }
        mirror.onActivityChange = { [weak self] in self?.scheduleActivityRefresh() }
        mirror.onClose = { [weak self] id in self?.removeMirror(id) }
        mirror.onTrimFinished = { [weak self] in
            AppModel.returnFocus(to: self?.sessions[sourceID]?.sourceProcessID)
        }
        mirror.onDuplicate = { [weak self] in
            guard let self, let session = self.sessions[sourceID] else { return }
            let extra = self.makeMirror(sourceID: sourceID, title: session.label)
            if let frame = session.latestFrame { extra?.receive(frame) }
        }
        mirrors[mirror.id] = mirror
        // Show without activating: copies never take focus from the source app.
        mirror.window?.orderFrontRegardless()
        updateCount()
        return mirror
    }

    /// Gives keyboard focus back to the source app (Capture One) so its shortcuts keep working.
    static func returnFocus(to pid: pid_t?) {
        guard let pid, let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate()
    }

    private func removeMirror(_ id: UUID) {
        guard let mirror = mirrors.removeValue(forKey: id) else { return }
        let sourceID = mirror.sourceID
        if !mirrors.values.contains(where: { $0.sourceID == sourceID }) {
            if let session = sessions.removeValue(forKey: sourceID) { Task { await session.stop() } }
            recovery.removeValue(forKey: sourceID)
            trims.removeValue(forKey: sourceID)
            trimObservers.removeValue(forKey: sourceID)
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
                let delay = self?.pollingDelay ?? 5
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { break }
                await self?.refreshActiveSources()
            }
        }
    }

    /// Frames report resizes and density changes directly; the poll is a liveness backstop.
    private var pollingDelay: Double {
        if sessions.contains(where: { $0.value.active && hasDemand(for: $0.key) }) { return 5 }
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
    private var refreshRequested = false
    private func refreshActiveSources() async {
        guard !sessions.isEmpty, !sleeping, !shuttingDown else { return }
        // A request that arrives mid-refresh runs another pass instead of being dropped.
        guard !refreshingActive else { refreshRequested = true; return }
        refreshingActive = true
        defer { refreshingActive = false }
        repeat {
            refreshRequested = false
            await refreshActiveSourcesOnce()
        } while refreshRequested && !sleeping && !shuttingDown
    }

    private func refreshActiveSourcesOnce() async {
        // Stop capture altogether when every copy is offscreen or minimized.
        for (id, session) in Array(sessions) where !hasDemand(for: id) {
            guard sessions[id] === session else { continue }
            if session.active || session.failed { await session.stop() }
        }
        let now = ProcessInfo.processInfo.systemUptime
        let candidates = Array(sessions).filter { id, session in
            hasDemand(for: id) && (session.active || (recovery[id] ?? RecoveryBackoff()).isReady(at: now))
        }
        guard !candidates.isEmpty else { return }
        do {
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
            for (id, session) in candidates where sessions[id] === session && !session.active &&
                hasDemand(for: id) && !sleeping && !shuttingDown {
                recovery[id, default: RecoveryBackoff()].failed(at: ProcessInfo.processInfo.systemUptime)
                session.onStatus?("Could not reconnect. Check Screen Recording permission; DualLink will retry.")
            }
        }
    }
}
