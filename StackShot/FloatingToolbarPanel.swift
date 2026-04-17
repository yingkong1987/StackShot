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
    private var currentPlacement: ToolbarPlacement

    init(anchorFrame: CGRect, callbacks: FloatingToolbarCallbacks) {
        self.callbacks = callbacks
        let layout = Self.layout(for: anchorFrame)
        let frame = layout.frame
        self.currentPlacement = layout.placement

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

        let host = NSHostingView(
            rootView: ToolbarContent(
                callbacks: callbacks,
                bubbleAboveToolbar: layout.placement == .belowWindow
            )
        )
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    func reposition(anchorFrame: CGRect) {
        let layout = Self.layout(for: anchorFrame)
        let frame = layout.frame
        setFrame(frame, display: true)
        contentView?.frame = NSRect(origin: .zero, size: frame.size)

        if layout.placement != currentPlacement,
           let host = contentView as? NSHostingView<ToolbarContent> {
            currentPlacement = layout.placement
            host.rootView = ToolbarContent(
                callbacks: callbacks,
                bubbleAboveToolbar: layout.placement == .belowWindow
            )
        }
    }

    // Compact toolbar ratio close to native screenshot tools.
    private static let toolbarWidth: CGFloat  = 760
    private static let toolbarHeight: CGFloat = 64
    private static let margin: CGFloat        = 12

    private enum ToolbarPlacement {
        case belowWindow
        case aboveWindow
    }

    private struct ToolbarLayout {
        let frame: CGRect
        let placement: ToolbarPlacement
    }

    private static func layout(for anchor: CGRect) -> ToolbarLayout {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.centerPoint) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let spaceBelow = anchor.minY - visible.minY
        let spaceAbove = visible.maxY - anchor.maxY
        let placeBelow = spaceBelow >= toolbarHeight + margin || spaceBelow >= spaceAbove

        let rawY: CGFloat
        let placement: ToolbarPlacement
        if placeBelow {
            rawY = anchor.minY - toolbarHeight - margin
            placement = .belowWindow
        } else {
            rawY = anchor.maxY + margin
            placement = .aboveWindow
        }

        let minX = visible.minX + margin
        let maxX = visible.maxX - margin - toolbarWidth
        let originX = min(max(anchor.midX - toolbarWidth / 2, minX), maxX)

        let minY = visible.minY + margin
        let maxY = visible.maxY - margin - toolbarHeight
        let originY = min(max(rawY, minY), maxY)

        return ToolbarLayout(
            frame: CGRect(x: originX, y: originY, width: toolbarWidth, height: toolbarHeight),
            placement: placement
        )
    }
}

// MARK: – SwiftUI content

private struct ToolbarContent: View {
    let callbacks: FloatingToolbarCallbacks
    let bubbleAboveToolbar: Bool
    @State private var activeConfigTool: ConfigTool?
    @State private var toolStyles: [ConfigTool: BubbleStyle] = [
        .rectangle: .defaultStyle,
        .circle: .defaultStyle,
        .arrow: .defaultStyle,
        .pen: .defaultStyle
    ]

    private enum ConfigTool {
        case rectangle
        case circle
        case arrow
        case pen

        var title: String {
            switch self {
            case .rectangle: return "矩形选取"
            case .circle: return "圆形选取"
            case .arrow: return "箭头"
            case .pen: return "画笔"
            }
        }
    }

    var body: some View {
        HStack(spacing: 6) {

            // ── Group 1: Capture / Draw ─────────────────────────────────────
            configBtn(.rectangle, "square", "矩形选取")
            configBtn(.circle, "circle", "圆形选取")
            btn("face.smiling", "表情与符号", callbacks.onEmoji)
            configBtn(.arrow, "arrow.up.right", "箭头")
            configBtn(.pen, "pencil", "画笔")
            btn("checkerboard.rectangle", "马赛克", callbacks.onMosaic)
            btn("t.square", "文字", callbacks.onText)

            sep()

            // ── Group 2: Process ────────────────────────────────────────────
            // OCR 翻译依赖 Apple 原生翻译能力（Translation framework），仅 macOS 15+ 提供默认可用体验；
            // 低版本系统隐藏该按钮，避免点击后无可用翻译实现。
            if #available(macOS 15.0, *) {
                btn("translate", "OCR 翻译", callbacks.onOCRTranslate)
            }
            btn("doc.text.magnifyingglass", "识别文字", callbacks.onOCR)
            btn("crop", "裁剪", callbacks.onCrop)

            sep()

            // ── Group 3: Actions ────────────────────────────────────────────
            btn("arrow.uturn.left", "撤销", callbacks.onUndo)
            btn("square.and.arrow.down", "保存", callbacks.onSave)
            btn("pin", "钉图", callbacks.onPin)
            btn("arrowshape.turn.up.right", "分享", callbacks.onShare)

            // Cancel (red) / Confirm (green)
            Button(action: callbacks.onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .background(Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
            .help("取消")

            Button(action: callbacks.onConfirm) {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .background(Color.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
            .help("截图并复制")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LiquidToolbarBackground(cornerRadius: 14)
        )
    }

    @ViewBuilder
    private func btn(_ icon: String, _ tip: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .help(tip)
    }

    @ViewBuilder
    private func configBtn(_ tool: ConfigTool, _ icon: String, _ tip: String) -> some View {
        let isActive = activeConfigTool == tool
        Button {
            activeConfigTool = tool
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .background(
            (isActive ? Color.accentColor.opacity(0.26) : Color.primary.opacity(0.08)),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .help(tip)
        .popover(
            isPresented: Binding(
                get: { activeConfigTool == tool },
                set: { presented in
                    if !presented && activeConfigTool == tool {
                        activeConfigTool = nil
                    }
                }
            ),
            attachmentAnchor: bubbleAboveToolbar ? .rect(.bounds) : .point(.bottom),
            arrowEdge: bubbleAboveToolbar ? .bottom : .top
        ) {
            CaptureStylePopover(
                toolTitle: tool.title,
                style: Binding(
                    get: { toolStyles[tool] ?? .defaultStyle },
                    set: { toolStyles[tool] = $0 }
                ),
                onStart: {
                    triggerConfigTool(tool)
                    activeConfigTool = nil
                }
            )
        }
    }

    private func sep() -> some View {
        Divider()
            .frame(width: 1, height: 24)
            .padding(.horizontal, 3)
    }

    private func triggerConfigTool(_ tool: ConfigTool) {
        switch tool {
        case .rectangle:
            callbacks.onRect()
        case .circle:
            callbacks.onCircle()
        case .arrow:
            callbacks.onArrow()
        case .pen:
            callbacks.onPen()
        }
    }
}

private struct LiquidToolbarBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.26),
                                Color.white.opacity(0.08),
                                Color.black.opacity(0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .blendMode(.softLight)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.24), radius: 14, y: 8)
    }
}

private struct BubbleStyle: Equatable {
    var lineWidth: CGFloat
    var color: NSColor

    static let defaultStyle = BubbleStyle(lineWidth: 3, color: .systemRed)
}

private struct CaptureStylePopover: View {
    let toolTitle: String
    @Binding var style: BubbleStyle
    let onStart: () -> Void

    private let colors: [NSColor] = [
        .systemRed,
        .systemOrange,
        .systemYellow,
        .systemGreen,
        .systemMint,
        .systemTeal,
        .systemBlue,
        .systemIndigo,
        .systemPurple,
        .systemPink,
        .white,
        .black
    ]
    private let widthPresets: [CGFloat] = [2, 4, 6, 8]
    private let columns = Array(repeating: GridItem(.fixed(20), spacing: 8), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(toolTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: "line.diagonal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(style.lineWidth) },
                        set: { style.lineWidth = CGFloat($0) }
                    ),
                    in: 1...12
                )
                .frame(width: 110)
            }

            HStack(spacing: 8) {
                ForEach(widthPresets, id: \.self) { width in
                    Button {
                        style.lineWidth = width
                    } label: {
                        Circle()
                            .fill(Color.primary)
                            .frame(width: width + 3, height: width + 3)
                            .frame(width: 20, height: 20)
                            .opacity(abs(style.lineWidth - width) < 0.5 ? 1 : 0.35)
                    }
                    .buttonStyle(.plain)
                }
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(colors.enumerated()), id: \.offset) { _, nsColor in
                    let selected = sameColor(style.color, nsColor)
                    Button {
                        style.color = nsColor
                    } label: {
                        ZStack {
                            Circle().fill(Color(nsColor: nsColor))
                            Circle()
                                .strokeBorder(
                                    selected ? Color.primary.opacity(0.85) : Color.primary.opacity(0.2),
                                    lineWidth: selected ? 1.8 : 0.8
                                )
                        }
                        .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Spacer()
                Button("开始截图") { onStart() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 210)
    }

    private func sameColor(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard
            let lc = lhs.usingColorSpace(.deviceRGB),
            let rc = rhs.usingColorSpace(.deviceRGB)
        else {
            return false
        }

        return abs(lc.redComponent - rc.redComponent) < 0.01 &&
            abs(lc.greenComponent - rc.greenComponent) < 0.01 &&
            abs(lc.blueComponent - rc.blueComponent) < 0.01 &&
            abs(lc.alphaComponent - rc.alphaComponent) < 0.01
    }
}

private extension CGRect {
    var centerPoint: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
