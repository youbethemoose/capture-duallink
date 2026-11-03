import AppKit
import ApplicationServices

/// Targets only the selected window; never warps the desktop cursor or installs an event tap.
@MainActor
final class SourceMouseControl {
    let windowID: CGWindowID
    let processID: pid_t?
    private var pressed: [Int: CGEvent] = [:]
    private var lastPoint: CGPoint?
    var isDragging: Bool { !pressed.isEmpty }

    // shortcut: macOS needs this window-local SPI for accurate PID clicks; replace when Apple publishes an equivalent.
    private static let setWindowLocation: (@convention(c) (CGEvent, CGPoint) -> Void)? = {
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let symbol = dlsym(library, "SLEventSetWindowLocation") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (CGEvent, CGPoint) -> Void).self)
    }()

    static var isSupported: Bool { setWindowLocation != nil }
    static var hasPermission: Bool { AXIsProcessTrusted() && CGPreflightPostEventAccess() }

    init(windowID: CGWindowID, processID: pid_t?) {
        self.windowID = windowID; self.processID = processID
    }

    static func explainPermission() {
        let alert = NSAlert()
        alert.messageText = "Allow Control Source"
        alert.informativeText = "Enable Capture DualLink in Accessibility settings, then return here. This lets your clicks, drags and scrolling control the original window."
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func bounds() -> CGRect? {
        guard let processID,
              let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]])?.first,
              (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
              let value = info[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: value as CFDictionary),
              rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    @discardableResult
    func send(_ event: NSEvent, point: CGPoint, sourceSize: CGSize) -> Bool {
        guard let processID, let setLocation = Self.setWindowLocation,
              processID == ProcessInfo.processInfo.processIdentifier || Self.hasPermission,
              point.x.isFinite, point.y.isFinite,
              let bounds = bounds(), abs(bounds.width - sourceSize.width) <= 2,
              abs(bounds.height - sourceSize.height) <= 2 else { cancel(); return false }
        let point = CGPoint(x: min(bounds.width - 0.001, max(0, point.x)),
                            y: min(bounds.height - 0.001, max(0, point.y)))
        let down = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
        let up = [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(event.type)
        let drag = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(event.type)
        if (up || drag) && pressed[event.buttonNumber] == nil { return false }
        let seedType: NSEvent.EventType = event.type == .scrollWheel ? .mouseMoved : event.type
        guard let seed = NSEvent.mouseEvent(with: seedType,
                                            location: CGPoint(x: point.x, y: bounds.height - point.y),
                                            modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                            windowNumber: Int(windowID), context: nil,
                                            eventNumber: Int(event.cgEvent?.getIntegerValueField(.mouseEventNumber) ?? 0),
                                            clickCount: event.type == .scrollWheel ? 0 : event.clickCount,
                                            pressure: up ? 0 : 1)?.cgEvent else { return false }
        if event.type == .scrollWheel, let original = event.cgEvent {
            seed.type = .scrollWheel
            for field: CGEventField in [.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
                .scrollWheelEventDeltaAxis3, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2,
                .scrollWheelEventFixedPtDeltaAxis3, .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2,
                .scrollWheelEventPointDeltaAxis3, .scrollWheelEventIsContinuous, .scrollWheelEventScrollPhase,
                .scrollWheelEventMomentumPhase, .scrollWheelEventScrollCount] {
                seed.setIntegerValueField(field, value: original.getIntegerValueField(field))
            }
        } else {
            seed.setIntegerValueField(.mouseEventButtonNumber, value: Int64(event.buttonNumber))
            if let lastPoint, drag || event.type == .mouseMoved {
                seed.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - lastPoint.x).rounded()))
                seed.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - lastPoint.y).rounded()))
            }
        }
        seed.location = CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y)
        seed.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(processID))
        seed.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        seed.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
        setLocation(seed, point)
        if down {
            if processID != ProcessInfo.processInfo.processIdentifier { NSRunningApplication(processIdentifier: processID)?.activate() }
            pressed[event.buttonNumber] = seed
        }
        if drag { pressed[event.buttonNumber] = seed }
        if up { pressed.removeValue(forKey: event.buttonNumber) }
        lastPoint = point
        seed.postToPid(processID)
        return true
    }

    func cancel() {
        defer { pressed.removeAll(); lastPoint = nil }
        guard let processID, let setLocation = Self.setWindowLocation, let bounds = bounds() else { return }
        for (button, event) in pressed {
            guard let release = event.copy() else { continue }
            release.type = button == 0 ? .leftMouseUp : button == 1 ? .rightMouseUp : .otherMouseUp
            release.flags = []
            release.setDoubleValueField(.mouseEventPressure, value: 0)
            release.location = CGPoint(x: bounds.minX - 1, y: bounds.minY - 1)
            setLocation(release, CGPoint(x: -1, y: -1))
            release.postToPid(processID)
        }
    }
}
