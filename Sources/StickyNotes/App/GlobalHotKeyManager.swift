import AppKit
import Carbon

/// Registers an app-level global hotkey so notes can be toggled while another app is frontmost.
@MainActor
final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()

    var onToggleVisibility: (() -> Void)?

    private let hotKeyIdentifier: UInt32 = 1
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private init() {}

    func registerDefaultHotKey() {
        installEventHandlerIfNeeded()
        unregisterHotKey()

        let identifier = EventHotKeyID(
            signature: fourCharCode("STKY"),
            id: hotKeyIdentifier
        )
        let keyCode = UInt32(kVK_ANSI_1)
        let modifiers = UInt32(cmdKey)

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            print("[GlobalHotKeyManager] Failed to register global hotkey: \(status)")
        }
    }

    func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, _ in
                guard let eventRef else { return noErr }

                var hotKeyID = EventHotKeyID()
                let result = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard result == noErr else { return result }

                Task { @MainActor in
                    GlobalHotKeyManager.shared.handleHotKey(id: hotKeyID.id)
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )

        if status != noErr {
            print("[GlobalHotKeyManager] Failed to install event handler: \(status)")
        }
    }

    private func handleHotKey(id: UInt32) {
        guard id == hotKeyIdentifier else { return }
        onToggleVisibility?()
    }

    private func fourCharCode(_ string: String) -> OSType {
        string.utf16.reduce(0) { partial, scalar in
            (partial << 8) + OSType(scalar)
        }
    }
}
