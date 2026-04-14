import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var launchAtLoginManager: LaunchAtLoginManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image("AppLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text("StackShot")
                    .font(.title2.weight(.semibold))
            }
            Text("使用 Shift + Command + A 激活：自动选中指针下的窗口并高亮，随后可用工具条进行区域选取或打开表情面板。")
                .font(.body)
                .foregroundStyle(.secondary)
            Divider()
            Toggle("开机启动", isOn: Binding(
                get: { launchAtLoginManager.isEnabled },
                set: { launchAtLoginManager.setEnabled($0) }
            ))
            .toggleStyle(.switch)

            if let msg = launchAtLoginManager.lastErrorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("首次截图前需授权：系统设置 → 隐私与安全性 → 屏幕录制，允许 StackShot。", systemImage: "rectangle.dashed.badge.record")
                Label("若权限未生效，请完全退出并重新打开 StackShot。", systemImage: "arrow.clockwise.circle")
                Label("快捷键冲突时可在后续版本支持自定义，目前默认使用 Shift + Command + A。", systemImage: "keyboard")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(minWidth: 420, minHeight: 250, alignment: .topLeading)
        .background(
            WindowAccessor { window in
                MenuBarController.shared.attachMainWindow(window)
            }
        )
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
