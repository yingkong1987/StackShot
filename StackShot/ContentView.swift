import SwiftUI
import Carbon.HIToolbox

struct ContentView: View {
    @EnvironmentObject private var launchAtLoginManager: LaunchAtLoginManager
    @ObservedObject private var settings = SettingsStore.shared
    @State private var isRecordingHotkey = false
    @State private var hotkeyRecordHint: String?
    @State private var localKeyMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image("AppLogo")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("StackShot")
                        .font(.title2.weight(.semibold))
                }
                Text("截图工具设置")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            GroupBox("快捷键") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("当前快捷键") {
                        Text(settings.shortcutDisplayString)
                            .font(.system(.body, design: .monospaced))
                    }
                    HStack(spacing: 10) {
                        Button(isRecordingHotkey ? "按下新组合键..." : "修改快捷键") {
                            beginHotkeyRecording()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("恢复默认") {
                            stopHotkeyRecording()
                            settings.resetHotkeyToDefault()
                            hotkeyRecordHint = nil
                        }
                        .buttonStyle(.bordered)
                        .disabled(isRecordingHotkey)
                    }

                    if let hotkeyRecordHint {
                        Text(hotkeyRecordHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("录制时请至少包含一个修饰键（⌘/⌥/⌃/⇧），按 Esc 取消。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("通用") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("开机启动", isOn: Binding(
                        get: { launchAtLoginManager.isEnabled },
                        set: { launchAtLoginManager.setEnabled($0) }
                    ))
                    .toggleStyle(.switch)

                    Toggle("在 Dock 显示", isOn: $settings.showInDock)
                        .toggleStyle(.switch)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let msg = launchAtLoginManager.lastErrorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            GroupBox("权限与提示") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("首次截图前需授权：系统设置 → 隐私与安全性 → 屏幕录制，允许 StackShot。", systemImage: "rectangle.dashed.badge.record")
                    Label("若权限未生效，请完全退出并重新打开 StackShot。", systemImage: "arrow.clockwise.circle")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .frame(minWidth: 460, minHeight: 340, alignment: .topLeading)
        .onDisappear { stopHotkeyRecording() }
        .background(
            WindowAccessor { window in
                MenuBarController.shared.attachMainWindow(window)
            }
        )
    }

    private func beginHotkeyRecording() {
        guard !isRecordingHotkey else { return }
        isRecordingHotkey = true
        hotkeyRecordHint = "请按下新的快捷键组合..."

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopHotkeyRecording()
                hotkeyRecordHint = "已取消快捷键录制。"
                return nil
            }

            let trimmedFlags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let carbonModifiers = SettingsStore.carbonModifiers(from: trimmedFlags)
            let keyCode = Int(event.keyCode)

            if carbonModifiers == 0 {
                hotkeyRecordHint = "快捷键必须包含修饰键（⌘/⌥/⌃/⇧）。"
                NSSound.beep()
                return nil
            }
            if Self.isModifierKeyCode(keyCode) {
                hotkeyRecordHint = "请配合一个普通按键使用。"
                NSSound.beep()
                return nil
            }

            settings.updateHotkey(keyCode: keyCode, carbonModifiers: carbonModifiers)
            hotkeyRecordHint = "已更新为 \(settings.shortcutDisplayString)"
            stopHotkeyRecording()
            return nil
        }
    }

    private func stopHotkeyRecording() {
        isRecordingHotkey = false
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    private static func isModifierKeyCode(_ keyCode: Int) -> Bool {
        let modifierCodes: Set<Int> = [
            Int(kVK_Command), Int(kVK_RightCommand),
            Int(kVK_Shift), Int(kVK_RightShift),
            Int(kVK_Option), Int(kVK_RightOption),
            Int(kVK_Control), Int(kVK_RightControl),
            Int(kVK_Function), Int(kVK_CapsLock)
        ]
        return modifierCodes.contains(keyCode)
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolve(window)
            }
        }
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
#endif
