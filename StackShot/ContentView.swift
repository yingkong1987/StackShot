import SwiftUI
import KeyboardShortcuts

struct ContentView: View {
    @EnvironmentObject private var launchAtLoginManager: LaunchAtLoginManager
    @ObservedObject private var settings = SettingsStore.shared
    @State private var selectedLanguageCode = L10n.currentSelectionCode()
    @State private var languageRenderCode = L10n.currentSelectionCode()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image("AppLogo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .center, spacing: 12) {
                                Text(L10n.tr("hotkey.current"))
                                    .font(.system(size: 13))
                                Spacer(minLength: 8)
                                KeyboardShortcuts.Recorder(for: .stackShotCapture, onChange: applyHotkeyRecorderChange)
                                    .frame(width: 230, alignment: .trailing)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }

                            HStack(spacing: 10) {
                                Button(L10n.tr("hotkey.reset_button")) {
                                    settings.resetHotkeyToDefault()
                                    KeyboardShortcuts.setShortcut(settings.asKeyboardShortcut, for: .stackShotCapture)
                                }
                                .buttonStyle(.bordered)
                            }

                            Text(L10n.tr("hotkey.recording_hint"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
            syncHotkeyRecorderFromSettings()
        }
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

    private func syncHotkeyRecorderFromSettings() {
        let fromSettings = settings.asKeyboardShortcut
        if KeyboardShortcuts.getShortcut(for: .stackShotCapture) != fromSettings {
            KeyboardShortcuts.setShortcut(fromSettings, for: .stackShotCapture)
        }
    }

    private func applyHotkeyRecorderChange(_ shortcut: KeyboardShortcuts.Shortcut?) {
        if let shortcut {
            settings.updateHotkey(keyCode: shortcut.carbonKeyCode, carbonModifiers: shortcut.carbonModifiers)
        } else {
            settings.resetHotkeyToDefault()
            KeyboardShortcuts.setShortcut(settings.asKeyboardShortcut, for: .stackShotCapture)
        }
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
    private let pickerWidth = max(160, L10n.languagePickerWidth() - 10)

    var body: some View {
        HStack(spacing: 12) {
            Text(L10n.languageSettingTitle())
                .font(.system(size: 13))
            Spacer(minLength: 8)
            Picker("", selection: $selectedLanguageCode) {
                ForEach(L10n.pickerOrderedLocaleCodes(), id: \.self) { code in
                    HStack {
                        Spacer(minLength: 0)
                        Text(L10n.displayLanguageName(for: code))
                            .multilineTextAlignment(.center)
                        Spacer(minLength: 0)
                    }
                    .tag(code)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.regular)
            .multilineTextAlignment(.center)
            .frame(width: pickerWidth, height: 28, alignment: .center)
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
