import AppKit
import CoreLocation
@preconcurrency import CoreWLAN
import ServiceManagement
import SwiftUI
import DualLinkCore

/// An event-driven, local-only watcher. No scans, location updates or capture streams.
@MainActor
final class HomeWiFiController: NSObject, ObservableObject, CLLocationManagerDelegate, CWEventDelegate {
    @Published private(set) var enabled: Bool
    @Published private(set) var homeSSID: String
    @Published private(set) var currentSSID: String?
    @Published private(set) var status = "Auto-start is off."
    @Published private(set) var error: String?
    @Published private(set) var changing = false
    var onAway: (() -> Void)?
    var onChange: (() -> Void)?

    private let location = CLLocationManager()
    private lazy var client = CWWiFiClient.shared()
    private let readQueue = DispatchQueue(label: "com.captureduallink.home-wifi", qos: .utility)
    private var policy = AwayFromHomePolicy()
    private var generation = UUID()
    private var monitoring: [CWEventType] = []
    private var fallback: Timer?
    private var sampleTask: Task<Void, Never>?
    private var confirmationTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var readForSetup = false

    var hasWiFiPermission: Bool {
        // macOS reports its single grant as authorizedAlways, including When In Use requests.
        location.authorizationStatus == .authorizedAlways
    }
    var needsLoginApproval: Bool { enabled && SMAppService.mainApp.status == .requiresApproval }

    override init() {
        enabled = UserDefaults.standard.bool(forKey: "awayAutoStartEnabled")
        homeSSID = UserDefaults.standard.string(forKey: "homeWiFiSSID") ?? ""
        super.init()
        location.delegate = self
        if enabled { start() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.networkChanged() }
        }
    }

    func configure(homeSSID: String, enabled: Bool) async {
        guard !changing else { return }
        guard !enabled || (!homeSSID.isEmpty && homeSSID.utf8.count <= 32) else {
            error = "Enter your home Wi-Fi name exactly as it appears in Wi-Fi settings (up to 32 bytes)."
            return
        }
        changing = true; error = nil
        defer { changing = false; onChange?() }
        do {
            let service = SMAppService.mainApp
            if enabled {
                if service.status == .notRegistered || service.status == .notFound { try service.register() }
            } else if service.status != .notRegistered && service.status != .notFound {
                try await service.unregister()
            }
            stop()
            self.homeSSID = homeSSID
            self.enabled = enabled
            UserDefaults.standard.set(homeSSID, forKey: "homeWiFiSSID")
            UserDefaults.standard.set(enabled, forKey: "awayAutoStartEnabled")
            if enabled {
                start()
                requestWiFiPermission()
            } else { status = "Auto-start is off." }
        } catch { self.error = "Couldn't update automatic startup: \(error.localizedDescription)" }
    }

    func requestWiFiPermission() {
        error = nil
        readForSetup = true
        switch location.authorizationStatus {
        case .notDetermined:
            location.requestWhenInUseAuthorization()
        case .denied, .restricted:
            status = "Allow DualLink in Location Services to read the connected Wi-Fi name."
            openLocationSettings()
        default: sample(allowDisabled: true)
        }
    }

    func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    private func start() {
        guard enabled else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 15
        fallback = timer
        sample()
    }

    private func beginMonitoringIfNeeded() {
        guard enabled, hasWiFiPermission else { return }
        client.delegate = self
        for event in [CWEventType.ssidDidChange, .linkDidChange, .powerDidChange] where !monitoring.contains(event) {
            do { try client.startMonitoringEvent(with: event); monitoring.append(event) }
            catch { /* A one-minute timer also handles missed or unavailable events. */ }
        }
    }

    private func stop() {
        generation = UUID()
        fallback?.invalidate(); fallback = nil
        sampleTask?.cancel(); sampleTask = nil
        confirmationTask?.cancel(); confirmationTask = nil
        for event in monitoring { try? client.stopMonitoringEvent(with: event) }
        monitoring.removeAll()
        client.delegate = nil
        policy = AwayFromHomePolicy()
    }

    func shutdown() {
        stop()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    private func networkChanged() {
        guard enabled else {
            if readForSetup { sample(allowDisabled: true) }
            return
        }
        // Invalidate in-flight reads immediately; the event may precede the new SSID.
        generation = UUID()
        _ = policy.observe(.unknown, at: ProcessInfo.processInfo.systemUptime)
        confirmationTask?.cancel(); confirmationTask = nil
        sampleTask?.cancel()
        sampleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.sample()
        }
    }

    private func sample(allowDisabled: Bool = false) {
        guard enabled || allowDisabled else { return }
        guard hasWiFiPermission else {
            currentSSID = nil
            status = "Waiting for Location Services permission to read Wi-Fi names."
            _ = policy.observe(.unknown, at: ProcessInfo.processInfo.systemUptime)
            onChange?()
            return
        }
        beginMonitoringIfNeeded()
        let token = generation, home = homeSSID, client = client
        readQueue.async { [weak self] in
            let interfaces = (client.interfaces() ?? []).filter { $0.powerOn() }
            let names = interfaces.map { $0.ssid() }
            let network = AwayFromHomePolicy.classify(homeSSID: home, connectedSSIDs: names)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.enabled || allowDisabled, self.generation == token else { return }
                    self.currentSSID = names.compactMap { $0 }.first
                    if self.enabled { self.receive(network) }
                    else { self.status = self.currentSSID == nil ? "Wi-Fi name unavailable." : "Current Wi-Fi is ready to use as home." }
                }
            }
        }
    }

    private func receive(_ network: AwayFromHomePolicy.Network) {
        let shouldOpen = policy.observe(network, at: ProcessInfo.processInfo.systemUptime)
        switch network {
        case .home: status = "At home · DualLink will stay quiet."
        case .away: status = policy.needsConfirmation ? "Confirming another Wi-Fi connection…" : "Away from home · DualLink is ready."
        case .unknown: status = "Wi-Fi is disconnected or its name is unavailable · waiting."
        }
        if policy.needsConfirmation {
            if confirmationTask == nil {
                confirmationTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(10.2))
                    guard !Task.isCancelled, let self else { return }
                    self.confirmationTask = nil
                    self.sample()
                }
            }
        } else { confirmationTask?.cancel(); confirmationTask = nil }
        onChange?()
        if shouldOpen { onAway?() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.networkChanged() }
    }
    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in self?.networkChanged() }
    }
    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in self?.networkChanged() }
    }
    nonisolated func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in self?.networkChanged() }
    }
}

struct AutoStartView: View {
    @ObservedObject var startup: HomeWiFiController
    @State private var home = ""
    @State private var enabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Start away from home").font(.title2.weight(.semibold))
            Text("DualLink opens after another Wi-Fi network stays connected for 10 seconds. At home, only the idle menu-bar watcher runs; capture starts when you choose a window.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Start automatically away from home Wi-Fi", isOn: $enabled)
            TextField("Home Wi-Fi network name", text: $home).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Home Wi-Fi network name")
            HStack {
                Button("Read Current Wi-Fi") { startup.requestWiFiPermission() }
                if let current = startup.currentSSID {
                    Button("Use Current Network") { home = current }
                }
            }
            Text(startup.status).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !startup.hasWiFiPermission {
                Button("Allow Wi-Fi Name Access…") { startup.requestWiFiPermission() }
            }
            if startup.needsLoginApproval {
                Text("Approve Capture DualLink under Login Items to start the watcher after login.")
                    .font(.callout).foregroundStyle(.orange)
                Button("Open Login Items Settings…") { startup.openLoginSettings() }
            }
            if let error = startup.error {
                Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("Your home network name stays on this Mac. No GPS updates or nearby-network scans. Returning home won't close active viewers. Quit stops the watcher until you reopen DualLink or log in again.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(startup.changing ? "Saving…" : "Save") {
                    Task { await startup.configure(homeSSID: home, enabled: enabled) }
                }
                .buttonStyle(.borderedProminent).disabled(startup.changing)
            }
        }
        .padding(24).frame(width: 450)
        .onAppear { home = startup.homeSSID; enabled = startup.enabled }
    }
}
