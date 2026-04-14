import AppKit
import Carbon.HIToolbox

/// Persistent app preferences. All writes must happen on the main thread.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    // MARK: – Stored properties

    @Published var showInDock: Bool {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: Keys.showInDock)
            applyDockPolicy()
        }
    }

    /// Carbon key code (e.g. kVK_ANSI_A = 0)
    @Published var hotkeyKeyCode: Int {
        didSet { UserDefaults.standard.set(hotkeyKeyCode, forKey: Keys.hotkeyKeyCode) }
    }

    /// Carbon modifier flags (shiftKey | cmdKey …)
    @Published var hotkeyModifiers: Int {
        didSet { UserDefaults.standard.set(hotkeyModifiers, forKey: Keys.hotkeyModifiers) }
    }

    // MARK: – Init

    private init() {
        let d = UserDefaults.standard
        showInDock    = d.bool(forKey: Keys.showInDock)
        hotkeyKeyCode = d.object(forKey: Keys.hotkeyKeyCode) as? Int
                        ?? Int(kVK_ANSI_A)
        hotkeyModifiers = d.object(forKey: Keys.hotkeyModifiers) as? Int
                          ?? (Int(shiftKey) | Int(cmdKey))
    }

    // MARK: – Hotkey update

    func updateHotkey(keyCode: Int, carbonModifiers: Int) {
        hotkeyKeyCode   = keyCode
        hotkeyModifiers = carbonModifiers
        HotkeyManager.shared.restart()
    }

    func resetHotkeyToDefault() {
        updateHotkey(keyCode: Int(kVK_ANSI_A),
                     carbonModifiers: Int(shiftKey) | Int(cmdKey))
    }

    // MARK: – Dock

    func applyDockPolicy() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    // MARK: – Display helpers

    var shortcutDisplayString: String {
        Self.modifierSymbols(from: hotkeyModifiers) + Self.keyName(for: hotkeyKeyCode)
    }

    static func modifierSymbols(from carbonMods: Int) -> String {
        var s = ""
        if carbonMods & Int(controlKey) != 0 { s += "⌃" }
        if carbonMods & Int(optionKey)  != 0 { s += "⌥" }
        if carbonMods & Int(shiftKey)   != 0 { s += "⇧" }
        if carbonMods & Int(cmdKey)     != 0 { s += "⌘" }
        return s
    }

    static func keyName(for keyCode: Int) -> String {
        let map: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_F1: "F1",  kVK_F2: "F2",  kVK_F3: "F3",  kVK_F4: "F4",
            kVK_F5: "F5",  kVK_F6: "F6",  kVK_F7: "F7",  kVK_F8: "F8",
            kVK_F9: "F9",  kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_Space:      "Space",
            kVK_Return:     "Return",
            kVK_Tab:        "Tab",
            kVK_Delete:     "Delete",
            kVK_UpArrow:    "↑",
            kVK_DownArrow:  "↓",
            kVK_LeftArrow:  "←",
            kVK_RightArrow: "→",
        ]
        return map[keyCode] ?? "?"
    }

    /// Convert NSEvent.ModifierFlags → Carbon modifier integer.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var r = 0
        if flags.contains(.shift)   { r |= Int(shiftKey) }
        if flags.contains(.command) { r |= Int(cmdKey) }
        if flags.contains(.option)  { r |= Int(optionKey) }
        if flags.contains(.control) { r |= Int(controlKey) }
        return r
    }

    // MARK: – Keys

    private enum Keys {
        static let showInDock       = "showInDock"
        static let hotkeyKeyCode    = "hotkeyKeyCode"
        static let hotkeyModifiers  = "hotkeyModifiers"
    }
}
