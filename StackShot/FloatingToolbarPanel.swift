import AppKit
import SwiftUI

// MARK: – Callbacks

/// All 16 actions the floating toolbar can emit.
struct FloatingToolbarCallbacks {
    // Group 1 – capture / draw
    var onRect:          () -> Void = {}
    var onCircle:        () -> Void = {}
    var onEmoji:         () -> Void = {}
    var onArrow:         () -> Void = {}
    var onPen:           () -> Void = {}
    var onMosaic:        () -> Void = {}
    var onText:          () -> Void = {}
    // Group 2 – process
    var onOCRTranslate:  () -> Void = {}
    var onOCR:           () -> Void = {}
    var onCrop:          () -> Void = {}
    // Group 3 – actions
    var onUndo:          () -> Void = {}
    var onSave:          () -> Void = {}
    var onPin:           () -> Void = {}
    var onShare:         () -> Void = {}
    var onCancel:        () -> Void = {}
    var onConfirm:       () -> Void = {}
}

// MARK: – Panel

/// 悬浮工具条：激活后完整展示所有 18 个功能按钮。
final class FloatingToolbarPanel: NSPanel {
    private var callbacks: FloatingToolbarCallbacks

    init(anchorFrame: CGRect, callbacks: FloatingToolbarCallbacks) {
        self.callbacks = callbacks
        let frame = Self.frame(for: anchorFrame)

        super.init(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel    = true
        worksWhenModal     = true
        level              = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque           = false
        backgroundColor    = .clear
        hasShadow          = true
        titleVisibility    = .hidden
        titlebarAppearsTransparent = true

        let host = NSHostingView(rootView: ToolbarContent(callbacks: callbacks))
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    func reposition(anchorFrame: CGRect) {
        let frame = Self.frame(for: anchorFrame)
        setFrame(frame, display: true)
        contentView?.frame = NSRect(origin: .zero, size: frame.size)
    }

    // Toolbar is ~720 px wide, 52 px tall.
    private static let toolbarWidth: CGFloat  = 720
    private static let toolbarHeight: CGFloat = 52
    private static let margin: CGFloat        = 12

    private static func frame(for anchor: CGRect) -> CGRect {
        let minScreenY = NSScreen.screens.map(\.frame.minY).min() ?? 0
        let originX = anchor.midX - toolbarWidth / 2
        let originY = max(minScreenY + margin, anchor.minY + margin)
        return CGRect(x: originX, y: originY, width: toolbarWidth, height: toolbarHeight)
    }
}

// MARK: – SwiftUI content

private struct ToolbarContent: View {
    let callbacks: FloatingToolbarCallbacks

    var body: some View {
        HStack(spacing: 5) {

            // ── Group 1: Capture / Draw ─────────────────────────────────────
            btn("square",                    "矩形选取",   callbacks.onRect)
            btn("circle",                    "圆形选取",   callbacks.onCircle)
            btn("face.smiling",              "表情与符号", callbacks.onEmoji)
            btn("arrow.up.right",            "箭头",       callbacks.onArrow)
            btn("pencil",                    "画笔",       callbacks.onPen)
            btn("squareshape.split.3x3",     "马赛克",     callbacks.onMosaic)
            btn("character.textbox",         "文字",       callbacks.onText)

            sep()

            // ── Group 2: Process ────────────────────────────────────────────
            btn("translate",                 "OCR 翻译",   callbacks.onOCRTranslate)
            btn("doc.text.magnifyingglass",  "识别文字",   callbacks.onOCR)
            btn("crop",                      "裁剪",       callbacks.onCrop)

            sep()

            // ── Group 3: Actions ────────────────────────────────────────────
            btn("arrow.uturn.left",          "撤销",       callbacks.onUndo)
            btn("square.and.arrow.down",     "保存",       callbacks.onSave)
            btn("pin",                       "钉图",       callbacks.onPin)
            btn("arrowshape.turn.up.right",  "分享",       callbacks.onShare)

            // Cancel (red) / Confirm (green)
            Button(action: callbacks.onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .help("取消")

            Button(action: callbacks.onConfirm) {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .help("截图并复制")
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func btn(_ icon: String, _ tip: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        .help(tip)
    }

    private func sep() -> some View {
        Divider()
            .frame(width: 1, height: 22)
            .padding(.horizontal, 2)
    }
}
