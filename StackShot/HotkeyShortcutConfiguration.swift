import Carbon.HIToolbox
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// 与 StackPaste 等应用一致：使用 KeyboardShortcuts 的命名快捷键 + Recorder UI。
    /// 默认值须与 `SettingsStore` / `resetHotkeyToDefault()` 中的 ⌘⇧A 保持一致。
    static let stackShotCapture: KeyboardShortcuts.Name = {
        let defaultMods = Int(shiftKey) | Int(cmdKey)
        let initial = KeyboardShortcuts.Shortcut(
            carbonKeyCode: Int(kVK_ANSI_A),
            carbonModifiers: defaultMods
        )
        return Self("stackShotCaptureHotkey", default: initial)
    }()
}

extension SettingsStore {
    /// 与 `KeyboardShortcuts` 统一使用同一套 Carbon 码。
    var asKeyboardShortcut: KeyboardShortcuts.Shortcut {
        KeyboardShortcuts.Shortcut(carbonKeyCode: hotkeyKeyCode, carbonModifiers: hotkeyModifiers)
    }
}
