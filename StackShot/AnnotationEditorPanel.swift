import AppKit
import SwiftUI
import Vision
import Combine

// MARK: – Editor state (shared between SwiftUI toolbar and AppKit canvas)

final class AnnotationEditorState: ObservableObject {
    @Published var selectedTool: AnnotationTool = .rectangle
    @Published private var toolStyles: [AnnotationTool: AnnotationToolStyle] = [
        .rectangle: .default(for: .rectangle),
        .circle: .default(for: .circle),
        .arrow: .default(for: .arrow),
        .pen: .default(for: .pen)
    ]

    func style(for tool: AnnotationTool) -> AnnotationToolStyle {
        toolStyles[tool] ?? .default(for: tool)
    }

    func updateStyle(for tool: AnnotationTool, _ transform: (inout AnnotationToolStyle) -> Void) {
        var style = style(for: tool)
        transform(&style)
        toolStyles[tool] = style
    }
}

// MARK: – Annotation editor window

final class AnnotationEditorPanel: NSPanel {

    private let canvas: AnnotationCanvasView
    private let state  = AnnotationEditorState()
    private var cancellables: Set<AnyCancellable> = []

    /// Called when the user confirms or shares; passes the final annotated image.
    var onConfirm: ((NSImage) -> Void)?
    /// Called when the user cancels.
    var onCancel: (() -> Void)?

    // MARK: Init

    init(screenshot: NSImage, initialTool: AnnotationTool = .rectangle) {
        let toolbarH: CGFloat = 126
        let minWidth: CGFloat = 700          // enough for all toolbar buttons

        // Fit inside 85 % of the main display's visible frame
        let screen   = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let maxW     = screen.width  * 0.85
        let maxH     = (screen.height - toolbarH) * 0.85
        let rawSize  = screenshot.size
        let fitScale = min(1, maxW / rawSize.width, maxH / rawSize.height)

        let canvasW  = max(rawSize.width  * fitScale, minWidth)
        let canvasH  = rawSize.height * fitScale
        let winW     = canvasW
        let winH     = canvasH + toolbarH

        // Centre on screen
        let origin = CGPoint(
            x: screen.midX - winW / 2,
            y: screen.midY - winH / 2
        )

        self.canvas = AnnotationCanvasView(
            frame: CGRect(x: 0, y: toolbarH, width: canvasW, height: canvasH),
            screenshot: screenshot
        )

        super.init(
            contentRect: CGRect(origin: origin, size: CGSize(width: winW, height: winH)),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        // Use .floating so the editor stays above other app windows, but keep it
        // as a normal interactive window (NOT nonactivatingPanel / modalPanel) so that
        // keyboard events work and CoreAnimation animations don't conflict.
        level              = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque           = true
        backgroundColor    = NSColor(white: 0.12, alpha: 1)
        hasShadow          = true
        title              = "编辑截图"
        minSize            = NSSize(width: minWidth, height: 200)

        setupContent(toolbarH: toolbarH, canvasW: canvasW, canvasH: canvasH)

        // Apply initial tool (e.g. pre-selected from the hover toolbar)
        state.selectedTool = initialTool
        canvas.styleProvider = { [weak state] tool in
            state?.style(for: tool) ?? .default(for: tool)
        }

        // For OCR tools triggered from the hover toolbar, fire OCR automatically
        // after the window has appeared (short delay lets the window settle).
        if initialTool == .ocr || initialTool == .ocrTranslate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.performOCR(translate: initialTool == .ocrTranslate)
            }
        }

        // Observe tool selection: keep canvas in sync
        state.$selectedTool
            .sink { [weak self] tool in
                self?.canvas.currentTool = tool
            }
            .store(in: &cancellables)

        state.objectWillChange
            .sink { [weak self] _ in
                self?.canvas.needsDisplay = true
            }
            .store(in: &cancellables)

        // Crop callback: resize the window
        canvas.onCropCompleted = { [weak self] newSize in
            self?.resizeAfterCrop(newSize: newSize, toolbarH: toolbarH)
        }
    }

    // MARK: Layout

    private func setupContent(toolbarH: CGFloat, canvasW: CGFloat, canvasH: CGFloat) {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: canvasW, height: canvasH + toolbarH))
        container.autoresizingMask = [.width, .height]
        contentView = container

        // Canvas
        canvas.autoresizingMask = [.width, .height]
        container.addSubview(canvas)

        // Toolbar (SwiftUI)
        let toolbarView = AnnotationToolbarView(
            state: state,
            onUndo:         { [weak self] in self?.canvas.undo() },
            onSave:         { [weak self] in self?.saveToFile() },
            onPin:          { [weak self] in self?.pinToScreen() },
            onShare:        { [weak self] in self?.shareImage() },
            onCancel:       { [weak self] in self?.cancelEditor() },
            onConfirm:      { [weak self] in self?.confirmEditor() },
            onOCR:          { [weak self] in self?.performOCR(translate: false) },
            onOCRTranslate: { [weak self] in self?.performOCR(translate: true) }
        )
        let host = NSHostingView(rootView: toolbarView)
        host.frame = CGRect(x: 0, y: 0, width: canvasW, height: toolbarH)
        host.autoresizingMask = [.width]
        container.addSubview(host)
    }

    private func resizeAfterCrop(newSize: NSSize, toolbarH: CGFloat) {
        let minWidth: CGFloat = 700
        let newW = max(newSize.width, minWidth)
        let newH = newSize.height + toolbarH
        let current = frame
        let newFrame = CGRect(
            x: current.midX - newW / 2,
            y: current.midY - newH / 2,
            width: newW, height: newH
        )
        setFrame(newFrame, display: true, animate: true)
    }

    // MARK: Actions

    private func confirmEditor() {
        let image = canvas.renderToImage()
        writeToPasteboard(image)
        onConfirm?(image)
        close()
    }

    private func cancelEditor() {
        onCancel?()
        close()
    }

    private func shareImage() {
        let image = canvas.renderToImage()
        guard let cv = contentView else {
            writeToPasteboard(image)
            return
        }
        let picker = NSSharingServicePicker(items: [image])
        // Anchor the picker near the bottom-right of the window
        let anchor = CGRect(x: cv.bounds.maxX - 60, y: 0, width: 40, height: 40)
        picker.show(relativeTo: anchor, of: cv, preferredEdge: .minY)
    }

    private func saveToFile() {
        let image = canvas.renderToImage()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "StackShot_\(Int(Date().timeIntervalSince1970))"
        panel.beginSheetModal(for: self) { result in
            guard result == .OK, let url = panel.url else { return }
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: url)
        }
    }

    private func pinToScreen() {
        let image = canvas.renderToImage()
        PinWindowStore.shared.pin(image)
        close()
    }

    // MARK: OCR

    private func performOCR(translate: Bool) {
        let image = canvas.renderToImage()
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest { [weak self] req, _ in
            let lines = (req.results as? [VNRecognizedTextObservation])?
                .compactMap { $0.topCandidates(1).first?.string } ?? []
            let text = lines.joined(separator: "\n")
            DispatchQueue.main.async {
                if translate {
                    self?.openTranslation(text: text)
                } else {
                    self?.copyOCRText(text)
                }
            }
        }
        request.recognitionLevel    = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP"]
        request.usesLanguageCorrection = true

        DispatchQueue.global(qos: .userInitiated).async {
            try? handler.perform([request])
        }
    }

    private func copyOCRText(_ text: String) {
        guard !text.isEmpty else {
            showAlert(title: "未识别到文字", message: "图片中没有可识别的文字。")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        NSSound.beep()
        showAlert(title: "文字识别完成", message: "已识别 \(text.count) 个字符并复制到剪贴板。")
    }

    private func openTranslation(text: String) {
        guard !text.isEmpty else {
            showAlert(title: "未识别到文字", message: "图片中没有可翻译的文字。")
            return
        }
        // Copy text and open the system Translate app
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if let url = URL(string: "translate://") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Helpers

    private func writeToPasteboard(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        NSSound.beep()
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText     = title
        alert.informativeText = message
        alert.alertStyle      = .informational
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: self)
    }

}

// MARK: – Pin window store (keeps floating screenshots alive)

final class PinWindowStore {
    static let shared = PinWindowStore()
    private var windows: [NSWindow] = []

    func pin(_ image: NSImage) {
        // Constrain displayed size to 60 % of main screen
        let screen  = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let maxW    = screen.width  * 0.6
        let maxH    = screen.height * 0.6
        let scale   = min(1, maxW / image.size.width, maxH / image.size.height)
        let dispSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let win = NSPanel(
            contentRect: CGRect(
                x: screen.midX - dispSize.width  / 2,
                y: screen.midY - dispSize.height / 2,
                width:  dispSize.width,
                height: dispSize.height
            ),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.title              = "StackShot"
        win.level              = .floating
        win.isReleasedWhenClosed = false
        win.collectionBehavior   = [.canJoinAllSpaces]
        win.hasShadow            = true

        let iv = NSImageView(frame: CGRect(origin: .zero, size: dispSize))
        iv.image         = image
        iv.imageScaling  = .scaleProportionallyUpOrDown
        iv.autoresizingMask = [.width, .height]
        win.contentView  = iv
        win.makeKeyAndOrderFront(nil)

        // Remove closed windows to avoid unbounded growth
        windows = windows.filter { $0.isVisible }
        windows.append(win)
    }
}

// MARK: – SwiftUI Annotation Toolbar

private struct AnnotationToolbarView: View {
    @ObservedObject var state: AnnotationEditorState
    var onUndo:         () -> Void
    var onSave:         () -> Void
    var onPin:          () -> Void
    var onShare:        () -> Void
    var onCancel:       () -> Void
    var onConfirm:      () -> Void
    var onOCR:          () -> Void
    var onOCRTranslate: () -> Void
    @State private var styleBubbleTool: AnnotationTool?

    private let configurableTools: Set<AnnotationTool> = [.rectangle, .circle, .arrow, .pen]
    private let commonColors: [NSColor] = [
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

    var body: some View {
        VStack(spacing: 8) {
            if let tool = styleBubbleTool, configurableTools.contains(tool) {
                AnnotationStylePopover(
                    style: Binding(
                        get: { state.style(for: tool) },
                        set: { newStyle in
                            state.updateStyle(for: tool) { style in
                                style = newStyle
                            }
                        }
                    ),
                    palette: commonColors
                )
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.8)
                )
            }

            HStack(spacing: 7) {
                // ── Group 1: Drawing tools ──────────────────────────────────────
                drawTool(.rectangle,   "square",                    "矩形标注")
                drawTool(.circle,      "circle",                    "圆形标注")
                drawTool(.emoji,       "face.smiling",              "表情与符号")
                drawTool(.arrow,       "arrow.up.right",            "箭头")
                drawTool(.pen,         "pencil",                    "画笔")
                drawTool(.mosaic,      "squareshape.split.3x3",     "马赛克")
                drawTool(.text,        "character.textbox",         "文字")

                toolSeparator()

                // ── Group 2: Processing tools ───────────────────────────────────
                drawTool(.ocrTranslate, "translate",                "OCR 翻译")
                drawTool(.ocr,          "doc.text.magnifyingglass", "识别文字")
                drawTool(.crop,         "crop",                     "裁剪")

                toolSeparator()

                // ── Group 3: Action buttons ─────────────────────────────────────
                actionButton("arrow.uturn.left",           "撤销",    action: onUndo)
                actionButton("square.and.arrow.down",      "保存",    action: onSave)
                actionButton("pin",                        "钉图",    action: onPin)
                actionButton("arrowshape.turn.up.right",   "分享",    action: onShare)

                // Cancel (red) and Confirm (green) with explicit colours
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .background(Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .help("取消")

                Button(action: onConfirm) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.green)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .background(Color.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .help("确认并复制")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(
            AnnotationLiquidToolbarBackground(cornerRadius: 16)
        )
        .overlay(alignment: .top) {
            Divider().opacity(0.25)
        }
    }

    // MARK: – Sub-view builders

    @ViewBuilder
    private func drawTool(_ tool: AnnotationTool, _ icon: String, _ tip: String) -> some View {
        let selected = state.selectedTool == tool
        let supportsStyle = configurableTools.contains(tool)
        Button {
            if tool == .ocr {
                state.selectedTool = tool
                styleBubbleTool = nil
                onOCR()
            } else if tool == .ocrTranslate {
                state.selectedTool = tool
                styleBubbleTool = nil
                onOCRTranslate()
            } else {
                state.selectedTool = tool
                styleBubbleTool = supportsStyle ? tool : nil
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .background(selected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(tip)
    }

    @ViewBuilder
    private func actionButton(_ icon: String, _ tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(tip)
    }

    private func toolSeparator() -> some View {
        Divider()
            .frame(width: 1, height: 28)
            .padding(.horizontal, 3)
    }
}

private struct AnnotationLiquidToolbarBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.24),
                                Color.white.opacity(0.08),
                                Color.black.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .blendMode(.softLight)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.26), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.20), radius: 12, y: 6)
    }
}

private struct AnnotationStylePopover: View {
    @Binding var style: AnnotationToolStyle
    let palette: [NSColor]

    private let minLineWidth: CGFloat = 1
    private let maxLineWidth: CGFloat = 14
    private let presetLineWidths: [CGFloat] = [2, 4, 6, 8]
    private let columns = Array(repeating: GridItem(.fixed(22), spacing: 8), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "line.diagonal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(style.lineWidth) },
                        set: { style.lineWidth = CGFloat($0) }
                    ),
                    in: Double(minLineWidth)...Double(maxLineWidth)
                )
                .frame(width: 120)
            }

            HStack(spacing: 8) {
                ForEach(presetLineWidths, id: \.self) { width in
                    Button {
                        style.lineWidth = width
                    } label: {
                        Circle()
                            .fill(Color.primary)
                            .frame(width: width + 4, height: width + 4)
                            .frame(width: 24, height: 24)
                            .opacity(abs(style.lineWidth - width) < 0.6 ? 1 : 0.35)
                    }
                    .buttonStyle(.plain)
                }
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(palette.enumerated()), id: \.offset) { _, nsColor in
                    let selected = sameColor(style.color, nsColor)
                    Button {
                        style.color = nsColor
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color(nsColor: nsColor))
                            if selected {
                                Circle()
                                    .strokeBorder(Color.primary.opacity(0.85), lineWidth: 2)
                            } else {
                                Circle()
                                    .strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.8)
                            }
                        }
                        .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                }
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
