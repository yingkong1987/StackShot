import AppKit
import Carbon.HIToolbox

/// 默认 Shift + Command + A
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let hotKeyID: UInt32 = 1

    func start() {
        if hotKeyRef != nil { return }
        installHandlerIfNeeded()
        registerDefaultHotKey()
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
    }

    private func registerDefaultHotKey() {
        var id = EventHotKeyID(
            signature: Self.fourCharCode(from: "SSHK"),
            id: hotKeyID
        )
        let modifiers = UInt32(shiftKey) | UInt32(cmdKey)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_A),
            modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            NSLog("RegisterEventHotKey failed with status: \(status)")
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let eventRef, let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.handleHotKeyEvent(eventRef)
            return noErr
        }
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )
        if status != noErr {
            NSLog("InstallEventHandler failed with status: \(status)")
        }
    }

    private func handleHotKeyEvent(_ eventRef: EventRef) {
        var incoming = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &incoming
        )
        guard status == noErr, incoming.id == hotKeyID else { return }

        DispatchQueue.main.async {
            CaptureSessionController.shared.activateFromHotkey()
        }
    }

    private static func fourCharCode(from string: String) -> OSType {
        let chars = Array(string.utf8).prefix(4)
        return chars.reduce(0) { ($0 << 8) + OSType($1) }
    }
}
