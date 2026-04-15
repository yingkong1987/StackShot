import SwiftUI
import Carbon.HIToolbox

struct ContentView: View {
    @EnvironmentObject private var launchAtLoginManager: LaunchAtLoginManager
    @ObservedObject private var settings = SettingsStore.shared
    @State private var isRecordingHotkey = false
    @State private var hotkeyRecordHint: String?
    @State private var localKeyMonitor: Any?
    @State private var selectedLanguageCode = L10n.currentSelectionCode()
    @State private var languageRenderCode = L10n.currentSelectionCode()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image("AppLogo")
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text(L10n.tr("app.name"))
                            .font(.system(size: 24, weight: .semibold))
                    }
                    Text(L10n.tr("settings.subtitle"))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SettingsSectionHeader(text: L10n.tr("section.hotkey"))
                    SettingsCard {
                        HStack(spacing: 12) {
                            Text(L10n.tr("hotkey.current"))
                                .font(.system(size: 13))
                            Spacer(minLength: 8)
                            Text(settings.shortcutDisplayString)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 44)

                        SettingsCardSeparator()

                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Button(isRecordingHotkey ? L10n.tr("hotkey.recording_button") : L10n.tr("hotkey.change_button")) {
                                    beginHotkeyRecording()
                                }
                                .buttonStyle(.borderedProminent)

                                Button(L10n.tr("hotkey.reset_button")) {
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
                                Text(L10n.tr("hotkey.recording_hint"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SettingsSectionHeader(text: L10n.tr("section.general"))
                    SettingsCard {
                        ToggleRow(title: L10n.tr("general.launch_at_login"), isOn: Binding(
                            get: { launchAtLoginManager.isEnabled },
                            set: { launchAtLoginManager.setEnabled($0) }
                        ))

                        SettingsCardSeparator()

                        ToggleRow(title: L10n.tr("general.show_in_dock"), isOn: $settings.showInDock)

                        SettingsCardSeparator()

                        LanguageQuickSwitchRow(selectedLanguageCode: $selectedLanguageCode)
                    }
                }

                if let msg = launchAtLoginManager.lastErrorMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SettingsSectionHeader(text: L10n.tr("section.permissions"))
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(L10n.tr("permissions.screen_recording"), systemImage: "rectangle.dashed.badge.record")
                            Label(L10n.tr("permissions.restart_hint"), systemImage: "arrow.clockwise.circle")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(languageRenderCode)
        .frame(minWidth: 460, minHeight: 340, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            let applied = L10n.currentSelectionCode()
            selectedLanguageCode = applied
            languageRenderCode = applied
        }
        .onDisappear { stopHotkeyRecording() }
        .onChange(of: selectedLanguageCode) { newValue in
            L10n.updateSelectionCode(newValue)
            let applied = L10n.currentSelectionCode()
            selectedLanguageCode = applied
            languageRenderCode = applied
            MenuBarController.shared.refreshLocalizedUI()
        }
        .background(
            WindowAccessor { window in
                MenuBarController.shared.attachMainWindow(window)
            }
        )
    }

    private func beginHotkeyRecording() {
        guard !isRecordingHotkey else { return }
        isRecordingHotkey = true
        hotkeyRecordHint = L10n.tr("hotkey.recording_prompt")

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopHotkeyRecording()
                hotkeyRecordHint = L10n.tr("hotkey.recording_cancelled")
                return nil
            }

            let trimmedFlags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let carbonModifiers = SettingsStore.carbonModifiers(from: trimmedFlags)
            let keyCode = Int(event.keyCode)

            if carbonModifiers == 0 {
                hotkeyRecordHint = L10n.tr("hotkey.require_modifier")
                NSSound.beep()
                return nil
            }
            if Self.isModifierKeyCode(keyCode) {
                hotkeyRecordHint = L10n.tr("hotkey.require_normal_key")
                NSSound.beep()
                return nil
            }

            settings.updateHotkey(keyCode: keyCode, carbonModifiers: carbonModifiers)
            hotkeyRecordHint = String(format: L10n.tr("hotkey.updated_format"), settings.shortcutDisplayString)
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

private struct SettingsSectionHeader: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.secondary)
    }
}

private struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color(nsColor: NSColor(white: 1.0, alpha: 0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SettingsCardSeparator: View {
    var body: some View {
        Divider()
            .padding(.leading, 16)
    }
}

private struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13))

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }
}

private struct LanguageQuickSwitchRow: View {
    @Binding var selectedLanguageCode: String

    var body: some View {
        HStack(spacing: 12) {
            Text(L10n.languageSettingTitle())
                .font(.system(size: 13))
            Spacer(minLength: 8)
            Picker("", selection: $selectedLanguageCode) {
                ForEach(L10n.pickerOrderedLocaleCodes(), id: \.self) { code in
                    Text(L10n.displayLanguageName(for: code)).tag(code)
                }
            }
            .labelsHidden()
            .frame(width: 280)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
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
