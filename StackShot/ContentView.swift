import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("StackShot")
                .font(.largeTitle.weight(.semibold))
            Text("使用 Shift + Command + A 激活：自动选中指针下的窗口并高亮，随后可用工具条进行区域选取或打开表情面板。")
                .font(.body)
                .foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label("首次截图前需授权：系统设置 → 隐私与安全性 → 屏幕录制，允许 StackShot。", systemImage: "rectangle.dashed.badge.record")
                Label("快捷键冲突时可在后续版本支持自定义，目前默认使用 Shift + Command + A。", systemImage: "keyboard")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(minWidth: 480, minHeight: 320, alignment: .topLeading)
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
#endif
