import AppKit
import CoreGraphics

/// Listens for exact modifier-only chords at the macOS session level so the
/// actions work while another application is frontmost.
@MainActor
final class GlobalHotKeyManager: ObservableObject {
    static let shared = GlobalHotKeyManager()

    @Published private(set) var hasInputMonitoringAccess = false
    @Published private(set) var errorMessage: String?

    var onCreateNote: (() -> Void)?
    var onToggleVisibility: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var recognizer = ModifierChordRecognizer()

    private init() {
        refreshPermissionStatus()
    }

    func start(requestPermission: Bool = true) {
        stop()
        refreshPermissionStatus()

        if !hasInputMonitoringAccess, requestPermission {
            hasInputMonitoringAccess = CGRequestListenEventAccess()
        }

        guard hasInputMonitoringAccess else {
            errorMessage = "Input Monitoring is required for global modifier shortcuts. Enable MD Sticky Notes in System Settings, then relaunch the app."
            return
        }

        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue)

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                let flags = event.flags
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                Task { @MainActor in
                    manager.handleEvent(type: type, flags: flags, keyCode: keyCode)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            errorMessage = "macOS did not allow the global shortcut listener. Check Input Monitoring and relaunch MD Sticky Notes."
            return
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        errorMessage = nil
    }

    func stop() {
        recognizer.reset()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    func refreshPermissionStatus() {
        hasInputMonitoringAccess = CGPreflightListenEventAccess()
        if hasInputMonitoringAccess, eventTap != nil {
            errorMessage = nil
        }
    }

    func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func handleEvent(type: CGEventType, flags: CGEventFlags, keyCode: Int64) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                errorMessage = nil
            }
            return
        }

        if type == .keyDown {
            recognizer.handleNonModifierKeyDown()
            return
        }

        guard type == .flagsChanged else { return }
        // Caps Lock is a latched state. Ignore an already-enabled Caps Lock when
        // matching target chords, but pressing it during an armed chord cancels.
        if keyCode == 57 {
            recognizer.handleExtraModifier()
            return
        }
        if let action = recognizer.handleFlagsChanged(Self.normalizedModifiers(flags)) {
            switch action {
            case .createNote:
                onCreateNote?()
            case .toggleVisibility:
                onToggleVisibility?()
            }
        }
    }

    private static func normalizedModifiers(_ flags: CGEventFlags) -> ModifierChordSet {
        var result: ModifierChordSet = []
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskSecondaryFn) { result.insert(.function) }
        return result
    }
}
