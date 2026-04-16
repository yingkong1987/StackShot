import AppKit
import SwiftUI
import Vision
import Combine

private enum AnnotationEditorMetrics {
    static let toolbarButtonSize: CGFloat = 36
    static let toolbarInterItemSpacing: CGFloat = 6
    static let toolbarRowSpacing: CGFloat = 6
    static let toolbarHorizontalPadding: CGFloat = 8
    static let toolbarVerticalPadding: CGFloat = 6
    static let toolbarGapToEditor: CGFloat = 4
    static let toolbarItemCount: Int = 16
    static let toolbarBelowRowCount: Int = 2
    static let toolbarRightColumnCount: Int = 2

    static var toolbarBelowColumnCount: Int {
        Int(ceil(Double(toolbarItemCount) / Double(toolbarBelowRowCount)))
    }

    static var toolbarBelowSize: CGSize {
        let cols = CGFloat(toolbarBelowColumnCount)
        let rows = CGFloat(toolbarBelowRowCount)
        let width = toolbarHorizontalPadding * 2
            + cols * toolbarButtonSize
            + (cols - 1) * toolbarInterItemSpacing
        let height = toolbarVerticalPadding * 2
            + rows * toolbarButtonSize
            + (rows - 1) * toolbarRowSpacing
        return CGSize(width: width, height: height)
    }

    static var toolbarRightSize: CGSize {
        let cols = CGFloat(toolbarRightColumnCount)
        let rows = CGFloat(Int(ceil(Double(toolbarItemCount) / Double(toolbarRightColumnCount))))
        let width = toolbarHorizontalPadding * 2
            + cols * toolbarButtonSize
            + (cols - 1) * toolbarInterItemSpacing
        let height = toolbarVerticalPadding * 2
            + rows * toolbarButtonSize
            + (rows - 1) * toolbarInterItemSpacing
        return CGSize(width: width, height: height)
    }
}

private enum ToolbarDockPosition {
    case belowEditor
    case rightOfEditor
}

// MARK: – Editor state (shared between SwiftUI toolbar and AppKit canvas)

final class AnnotationEditorState: ObservableObject {
    static let colorPalette: [NSColor] = [
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

    @Published var selectedTool: AnnotationTool?
    @Published private var toolStyles: [AnnotationTool: AnnotationToolStyle] = [:]

    private let styleStorage = UserDefaults.standard
    private enum StyleStore {
        static let keyPrefix = "annotation.toolStyle."
    }

    init() {
        let persistedTools: [AnnotationTool] = [.rectangle, .circle, .arrow, .pen]
        for tool in persistedTools {
            toolStyles[tool] = loadStyle(for: tool) ?? .default(for: tool)
        }
    }

    func style(for tool: AnnotationTool) -> AnnotationToolStyle {
        toolStyles[tool] ?? .default(for: tool)
    }

    func updateStyle(for tool: AnnotationTool, _ transform: (inout AnnotationToolStyle) -> Void) {
        var style = style(for: tool)
        transform(&style)
        toolStyles[tool] = style
        saveStyle(style, for: tool)
    }

    private func loadStyle(for tool: AnnotationTool) -> AnnotationToolStyle? {
        guard let stored = styleStorage.dictionary(forKey: storageKey(for: tool)) else {
            return nil
        }

        let defaultStyle = AnnotationToolStyle.default(for: tool)
        let lineWidth = stored["lineWidth"] as? CGFloat
            ?? (stored["lineWidth"] as? Double).map { CGFloat($0) }
            ?? defaultStyle.lineWidth
        let colorIndex = stored["colorIndex"] as? Int ?? 0
        let palette = Self.colorPalette
        let resolvedIndex = max(0, min(colorIndex, palette.count - 1))
        let color = palette[resolvedIndex]

        return AnnotationToolStyle(
            lineWidth: lineWidth,
            isFilled: defaultStyle.isFilled,
            color: color
        )
    }

    private func saveStyle(_ style: AnnotationToolStyle, for tool: AnnotationTool) {
        let nearestColorIndex = Self.colorPalette.enumerated().min {
            colorDistance(style.color, $0.element) < colorDistance(style.color, $1.element)
        }?.offset ?? 0

        styleStorage.set(
            ["lineWidth": Double(style.lineWidth), "colorIndex": nearestColorIndex],
            forKey: storageKey(for: tool)
        )
    }

    private func storageKey(for tool: AnnotationTool) -> String {
        StyleStore.keyPrefix + tool.storageKey
    }

    private func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        guard
            let lc = lhs.usingColorSpace(.deviceRGB),
            let rc = rhs.usingColorSpace(.deviceRGB)
        else {
            return .greatestFiniteMagnitude
        }

        let dr = lc.redComponent - rc.redComponent
        let dg = lc.greenComponent - rc.greenComponent
        let db = lc.blueComponent - rc.blueComponent
        let da = lc.alphaComponent - rc.alphaComponent
        return dr * dr + dg * dg + db * db + da * da
    }
}

private extension AnnotationTool {
    var storageKey: String {
        switch self {
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .arrow: return "arrow"
        case .pen: return "pen"
        case .emoji: return "emoji"
        case .mosaic: return "mosaic"
        case .text: return "text"
        case .ocr: return "ocr"
        case .ocrTranslate: return "ocrTranslate"
        case .crop: return "crop"
        }
    }
}

// MARK: – Annotation editor window

final class AnnotationEditorPanel: NSPanel, NSWindowDelegate {

    private let canvas: AnnotationCanvasView
    private let state  = AnnotationEditorState()
    private var cancellables: Set<AnyCancellable> = []
    private var toolbarPanel: AnnotationToolbarFloatingPanel?
    private var emojiPopover: NSPopover?

    /// Called when the user confirms or shares; passes the final annotated image.
    var onConfirm: ((NSImage) -> Void)?
    /// Called when the user cancels.
    var onCancel: (() -> Void)?

    // MARK: Init

    init(screenshot: NSImage, initialTool: AnnotationTool? = nil) {
        // 按图片比例适配；结合工具栏可能停靠在下方/右侧预留空间，避免被屏幕裁切。
        let activeScreen = NSScreen.screens.first(where: { $0.visibleFrame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        let screen = activeScreen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let rawSize = screenshot.size
        let rw = max(rawSize.width, 1)
        let rh = max(rawSize.height, 1)
        let preferBelowToolbar = rw >= rh

        let bottomToolbarReserve = AnnotationEditorMetrics.toolbarBelowSize.height
            + AnnotationEditorMetrics.toolbarGapToEditor
            + 18
        let sideToolbarReserve: CGFloat = 220
        let maxW = max(
            200,
            screen.width * 0.97 - (preferBelowToolbar ? 0 : sideToolbarReserve)
        )
        let maxH = max(
            200,
            screen.height * 0.94 - (preferBelowToolbar ? bottomToolbarReserve : 0)
        )

        let fitScale = min(maxW / rw, maxH / rh)
        let canvasW = rw * fitScale
        let canvasH = rh * fitScale
        let winW = canvasW
        let winH = canvasH

        // Centre on screen（工具栏单独吸附在窗口下方，不占用内容区高度）
        let origin = CGPoint(
            x: screen.midX - winW / 2,
            y: screen.midY - winH / 2
        )

        self.canvas = AnnotationCanvasView(
            frame: CGRect(x: 0, y: 0, width: canvasW, height: canvasH),
            screenshot: screenshot
        )

        super.init(
            contentRect: CGRect(origin: origin, size: CGSize(width: winW, height: winH)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        // 恢复标准窗口边框与交通灯按钮，同时保持窗口固定在中心位置。
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = true
        backgroundColor = NSColor(white: 0.12, alpha: 1)
        hasShadow = true
        // NSPanel 默认在失焦时可能自动隐藏，这会导致“截图后编辑窗口不见了”的感知。
        hidesOnDeactivate = false
        isFloatingPanel = false
        title = "编辑截图"
        isMovable = true
        isMovableByWindowBackground = false
        minSize = NSSize(width: 80, height: 60)
        delegate = self

        setupContent(canvasW: canvasW, canvasH: canvasH)

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
            self?.resizeAfterCrop(newSize: newSize)
        }

        showFloatingToolbar()
    }

    // MARK: Layout

    private func setupContent(canvasW: CGFloat, canvasH: CGFloat) {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        container.autoresizingMask = [.width, .height]
        contentView = container
        windowController?.window?.acceptsMouseMovedEvents = true
        acceptsMouseMovedEvents = true

        // Canvas
        canvas.autoresizingMask = [.width, .height]
        container.addSubview(canvas)
    }

    private func resizeAfterCrop(newSize: NSSize) {
        let newW = max(newSize.width, 80)
        let newH = max(newSize.height, 60)
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

    override func close() {
        emojiPopover?.performClose(nil)
        emojiPopover = nil
        toolbarPanel?.close()
        toolbarPanel = nil
        super.close()
    }

    private func presentEmojiPicker(anchorView: NSView) {
        guard let toolbarPanel else { return }

        if let emojiPopover, emojiPopover.isShown {
            emojiPopover.performClose(nil)
            self.emojiPopover = nil
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        let picker = EmojiPickerView { [weak self] emoji in
            self?.state.selectedTool = .emoji
            self?.canvas.insertEmojiSticker(emoji)
            self?.emojiPopover?.performClose(nil)
            self?.emojiPopover = nil
        }
        let host = NSHostingController(rootView: picker)
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 304, height: 248)

        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
        toolbarPanel.orderFrontRegardless()
        emojiPopover = popover
    }

    func windowDidMove(_ notification: Notification) {
        toolbarPanel?.refreshAnchorFrame(editorFrame: frame)
    }

    func windowDidResize(_ notification: Notification) {
        toolbarPanel?.refreshAnchorFrame(editorFrame: frame)
    }

    private func showFloatingToolbar() {
        guard toolbarPanel == nil else { return }

        let toolbarView = AnnotationToolbarView(
            state: state,
            onUndo:         { [weak self] in self?.canvas.undo() },
            onSave:         { [weak self] in self?.saveToFile() },
            onPin:          { [weak self] in self?.pinToScreen() },
            onShare:        { [weak self] in self?.shareImage() },
            onCancel:       { [weak self] in self?.cancelEditor() },
            onConfirm:      { [weak self] in self?.confirmEditor() },
            onEmoji:        { [weak self] anchorView in self?.presentEmojiPicker(anchorView: anchorView) },
            onOCR:          { [weak self] in self?.performOCR(translate: false) },
            onOCRTranslate: { [weak self] in self?.performOCR(translate: true) }
        )

        let panel = AnnotationToolbarFloatingPanel(editorFrame: frame, toolbarView: toolbarView)
        panel.orderFrontRegardless()
        toolbarPanel = panel
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

// MARK: – Floating toolbar outside editor

private final class AnnotationToolbarFloatingPanel: NSPanel {
    private static let toolbarMaxWidth: CGFloat = 760
    private static let margin: CGFloat = 6

    private struct ToolbarLayout {
        let frame: CGRect
        let dock: ToolbarDockPosition
    }

    private var currentDock: ToolbarDockPosition = .belowEditor
    private weak var host: DraggableToolbarHostingView<AnnotationToolbarView>?

    init(editorFrame: CGRect, toolbarView: AnnotationToolbarView) {
        let layout = Self.layout(for: editorFrame)
        currentDock = layout.dock
        let initialRoot = toolbarView.withDock(layout.dock)
        super.init(
            contentRect: layout.frame,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false

        let host = DraggableToolbarHostingView(rootView: initialRoot) {}
        host.frame = CGRect(origin: .zero, size: layout.frame.size)
        host.autoresizingMask = [.width, .height]
        contentView = host
        self.host = host
    }

    func refreshAnchorFrame(editorFrame: CGRect) {
        let layout = Self.layout(for: editorFrame)
        setFrame(layout.frame, display: true, animate: false)

        if layout.dock != currentDock, let host {
            currentDock = layout.dock
            host.rootView = host.rootView.withDock(layout.dock)
        }
    }

    private static func layout(for editorFrame: CGRect) -> ToolbarLayout {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: editorFrame.midX, y: editorFrame.midY)) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let preferBelow = editorFrame.width >= editorFrame.height
        let below = belowFrame(editorFrame: editorFrame, visible: visible)
        let right = rightFrame(editorFrame: editorFrame, visible: visible)

        if preferBelow {
            if let below { return ToolbarLayout(frame: below, dock: .belowEditor) }
            if let right { return ToolbarLayout(frame: right, dock: .rightOfEditor) }
        } else {
            if let right { return ToolbarLayout(frame: right, dock: .rightOfEditor) }
            if let below { return ToolbarLayout(frame: below, dock: .belowEditor) }
        }

        return ToolbarLayout(
            frame: CGRect(
                x: visible.midX - 180,
                y: visible.minY + margin,
                width: 360,
                height: AnnotationEditorMetrics.toolbarBelowSize.height
            ),
            dock: .belowEditor
        )
    }

    private static func belowFrame(editorFrame: CGRect, visible: CGRect) -> CGRect? {
        let base = AnnotationEditorMetrics.toolbarBelowSize
        let width = min(base.width, toolbarMaxWidth, editorFrame.width, visible.width - margin * 2)
        let height = min(base.height, editorFrame.height, visible.height - margin * 2)
        guard width >= base.width * 0.92, height >= base.height * 0.95 else { return nil }

        let y = editorFrame.minY - AnnotationEditorMetrics.toolbarGapToEditor - height
        guard y >= visible.minY + margin else { return nil }

        let minX = visible.minX + margin
        let maxX = visible.maxX - margin - width
        guard maxX >= minX else { return nil }
        let x = min(max(editorFrame.midX - width / 2, minX), maxX)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func rightFrame(editorFrame: CGRect, visible: CGRect) -> CGRect? {
        let base = AnnotationEditorMetrics.toolbarRightSize
        let width = min(base.width, editorFrame.width, visible.width - margin * 2)
        let height = min(base.height, editorFrame.height, visible.height - margin * 2)
        guard width >= base.width * 0.95, height >= base.height * 0.82 else { return nil }

        let x = editorFrame.maxX + AnnotationEditorMetrics.toolbarGapToEditor
        guard x + width <= visible.maxX - margin else { return nil }

        let minY = visible.minY + margin
        let maxY = visible.maxY - margin - height
        guard maxY >= minY else { return nil }
        let y = min(max(editorFrame.midY - height / 2, minY), maxY)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private final class DraggableToolbarHostingView<Content: View>: NSHostingView<Content> {
    private let dragRegionHeight: CGFloat = 16
    var onBeginDrag: () -> Void = {}

    init(rootView: Content, onBeginDrag: @escaping () -> Void) {
        self.onBeginDrag = onBeginDrag
        super.init(rootView: rootView)
    }

    @MainActor @preconcurrency required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @MainActor @preconcurrency required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let isInDragRegion = localPoint.y >= (bounds.height - dragRegionHeight)
        guard isInDragRegion || hitTest(localPoint) === self else {
            super.mouseDown(with: event)
            return
        }

        onBeginDrag()
        window?.performDrag(with: event)
    }
}

// MARK: – Style popover (NSPopover：在 NSPanel + NSHostingView 中 SwiftUI .popover 常无法显示)

private enum AnnotationStylePopoverSession {
    static weak var active: NSPopover?

    static func closeActive() {
        active?.performClose(nil)
        active = nil
    }
}

private struct ConfigurableToolToolbarButton: NSViewRepresentable {
    @ObservedObject var state: AnnotationEditorState
    let tool: AnnotationTool
    let systemName: String
    let help: String

    func makeCoordinator() -> Coordinator {
        Coordinator(tool: tool, state: state, systemName: systemName)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.help = help
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        container.wantsLayer = true
        container.layer?.cornerRadius = 10

        let button = NSButton(frame: container.bounds)
        button.autoresizingMask = [.width, .height]
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = context.coordinator
        button.action = #selector(Coordinator.click(_:))
        button.toolTip = help

        context.coordinator.container = container
        context.coordinator.button = button
        context.coordinator.refreshSymbol()

        container.addSubview(button)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.state = state
        context.coordinator.help = help
        context.coordinator.button?.toolTip = help
        context.coordinator.refreshSymbol()
        context.coordinator.updateAppearance(selected: state.selectedTool == tool)
        context.coordinator.syncPopoverContent()
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        let tool: AnnotationTool
        var state: AnnotationEditorState
        let systemName: String
        var help: String = ""

        weak var container: NSView?
        weak var button: NSButton?
        var popover: NSPopover?

        init(tool: AnnotationTool, state: AnnotationEditorState, systemName: String) {
            self.tool = tool
            self.state = state
            self.systemName = systemName
        }

        func refreshSymbol() {
            guard let button else { return }
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            let img = NSImage(systemSymbolName: systemName, accessibilityDescription: help)?
                .withSymbolConfiguration(config)
            button.image = img
            button.contentTintColor = NSColor.labelColor
        }

        func updateAppearance(selected: Bool) {
            guard let container else { return }
            let fill = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.28)
                : NSColor.labelColor.withAlphaComponent(0.08)
            container.layer?.backgroundColor = fill.cgColor
        }

        @objc
        func click(_ sender: NSButton) {
            if let p = popover, p.isShown {
                p.performClose(nil)
                return
            }

            state.selectedTool = tool
            AnnotationStylePopoverSession.closeActive()
            presentPopover(anchoredTo: sender)
        }

        private func presentPopover(anchoredTo sender: NSButton) {
            let pop = NSPopover()
            pop.behavior = .transient
            pop.animates = true
            pop.delegate = self

            let host = NSHostingController(rootView: makePopoverRootView())
            host.view.layoutSubtreeIfNeeded()
            let fitting = host.view.fittingSize
            let w = max(fitting.width, 210)
            let h = max(fitting.height, 120)
            pop.contentSize = NSSize(width: w, height: h)
            pop.contentViewController = host

            let anchor = sender.superview ?? sender
            pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: NSRectEdge.maxY)

            popover = pop
            AnnotationStylePopoverSession.active = pop
        }

        private func makePopoverRootView() -> AnnotationStylePopover {
            AnnotationStylePopover(
                style: Binding(
                    get: { [weak self] in
                        guard let self else { return .default(for: .rectangle) }
                        return self.state.style(for: self.tool)
                    },
                    set: { [weak self] newValue in
                        guard let self else { return }
                        self.state.updateStyle(for: self.tool) { $0 = newValue }
                    }
                ),
                palette: AnnotationEditorState.colorPalette
            )
        }

        func syncPopoverContent() {
            guard let pop = popover, pop.isShown,
                  let host = pop.contentViewController as? NSHostingController<AnnotationStylePopover> else { return }
            host.rootView = makePopoverRootView()
        }

        func popoverDidClose(_ notification: Notification) {
            popover = nil
            if AnnotationStylePopoverSession.active === notification.object as? NSPopover {
                AnnotationStylePopoverSession.active = nil
            }
        }
    }
}

private struct EmojiToolbarButton: NSViewRepresentable {
    @ObservedObject var state: AnnotationEditorState
    let help: String
    let onClick: (NSView) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, onClick: onClick)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: AnnotationEditorMetrics.toolbarButtonSize,
            height: AnnotationEditorMetrics.toolbarButtonSize
        ))
        container.wantsLayer = true
        container.layer?.cornerRadius = 10

        let button = NSButton(frame: container.bounds)
        button.autoresizingMask = [.width, .height]
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = context.coordinator
        button.action = #selector(Coordinator.click(_:))
        button.toolTip = help

        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        button.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: help)?
            .withSymbolConfiguration(config)
        button.contentTintColor = NSColor.labelColor

        context.coordinator.container = container
        context.coordinator.button = button
        context.coordinator.updateAppearance(selected: state.selectedTool == .emoji)

        container.addSubview(button)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.state = state
        context.coordinator.updateAppearance(selected: state.selectedTool == .emoji)
        context.coordinator.button?.toolTip = help
    }

    final class Coordinator: NSObject {
        var state: AnnotationEditorState
        let onClick: (NSView) -> Void
        weak var container: NSView?
        weak var button: NSButton?

        init(state: AnnotationEditorState, onClick: @escaping (NSView) -> Void) {
            self.state = state
            self.onClick = onClick
        }

        func updateAppearance(selected: Bool) {
            guard let container else { return }
            let fill = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.28)
                : NSColor.labelColor.withAlphaComponent(0.08)
            container.layer?.backgroundColor = fill.cgColor
        }

        @objc
        func click(_ sender: NSButton) {
            state.selectedTool = .emoji
            onClick(sender)
        }
    }
}

private struct ToolbarActionButton: NSViewRepresentable {
    let systemName: String
    let help: String
    let tintColor: NSColor?
    let backgroundColor: NSColor?
    let onClick: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onClick: onClick)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: AnnotationEditorMetrics.toolbarButtonSize,
            height: AnnotationEditorMetrics.toolbarButtonSize
        ))
        container.wantsLayer = true
        container.layer?.cornerRadius = 10

        let button = NSButton(frame: container.bounds)
        button.autoresizingMask = [.width, .height]
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = context.coordinator
        button.action = #selector(Coordinator.click(_:))

        context.coordinator.container = container
        context.coordinator.button = button
        context.coordinator.update(
            systemName: systemName,
            help: help,
            tintColor: tintColor,
            backgroundColor: backgroundColor
        )

        container.addSubview(button)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            systemName: systemName,
            help: help,
            tintColor: tintColor,
            backgroundColor: backgroundColor
        )
    }

    final class Coordinator: NSObject {
        let onClick: () -> Void
        weak var container: NSView?
        weak var button: NSButton?

        init(onClick: @escaping () -> Void) {
            self.onClick = onClick
        }

        func update(
            systemName: String,
            help: String,
            tintColor: NSColor?,
            backgroundColor: NSColor?
        ) {
            guard let container, let button else { return }
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            button.image = NSImage(systemSymbolName: systemName, accessibilityDescription: help)?
                .withSymbolConfiguration(config)
            button.contentTintColor = tintColor ?? NSColor.labelColor
            button.toolTip = help
            container.layer?.backgroundColor = (backgroundColor ?? NSColor.labelColor.withAlphaComponent(0.08)).cgColor
        }

        @objc
        func click(_ sender: NSButton) {
            onClick()
        }
    }
}

// MARK: – SwiftUI Annotation Toolbar

private struct AnnotationToolbarView: View {
    @ObservedObject var state: AnnotationEditorState
    var dock: ToolbarDockPosition = .belowEditor
    var onUndo:         () -> Void
    var onSave:         () -> Void
    var onPin:          () -> Void
    var onShare:        () -> Void
    var onCancel:       () -> Void
    var onConfirm:      () -> Void
    var onEmoji:        (NSView) -> Void
    var onOCR:          () -> Void
    var onOCRTranslate: () -> Void

    private let configurableTools: Set<AnnotationTool> = [.rectangle, .circle, .arrow, .pen]
    private let orderedTokens: [ToolbarToken] = [
        .rectangle, .circle, .emoji, .arrow, .pen, .mosaic, .text, .ocrTranslate,
        .ocr, .crop, .undo, .save, .pin, .share, .cancel, .confirm
    ]

    private enum ToolbarToken: String {
        case rectangle, circle, emoji, arrow, pen, mosaic, text, ocrTranslate, ocr, crop
        case undo, save, pin, share
        case cancel, confirm
    }

    var body: some View {
        Group {
            if dock == .belowEditor {
                let split = Int(ceil(Double(orderedTokens.count) / 2))
                let row1 = Array(orderedTokens.prefix(split))
                let row2 = Array(orderedTokens.dropFirst(split))
                VStack(spacing: AnnotationEditorMetrics.toolbarRowSpacing) {
                    HStack(spacing: AnnotationEditorMetrics.toolbarInterItemSpacing) {
                        ForEach(row1, id: \.rawValue) { token in
                            renderToken(token)
                        }
                    }
                    HStack(spacing: AnnotationEditorMetrics.toolbarInterItemSpacing) {
                        ForEach(row2, id: \.rawValue) { token in
                            renderToken(token)
                        }
                    }
                }
            } else {
                let columns = Array(
                    repeating: GridItem(.fixed(AnnotationEditorMetrics.toolbarButtonSize),
                                        spacing: AnnotationEditorMetrics.toolbarInterItemSpacing),
                    count: AnnotationEditorMetrics.toolbarRightColumnCount
                )
                LazyVGrid(columns: columns, spacing: AnnotationEditorMetrics.toolbarInterItemSpacing) {
                    ForEach(orderedTokens, id: \.rawValue) { token in
                        renderToken(token)
                    }
                }
            }
        }
        .padding(.horizontal, AnnotationEditorMetrics.toolbarHorizontalPadding)
        .padding(.vertical, AnnotationEditorMetrics.toolbarVerticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(
            AnnotationLiquidToolbarBackground(cornerRadius: 16)
        )
    }

    // MARK: – Sub-view builders

    @ViewBuilder
    private func renderToken(_ token: ToolbarToken) -> some View {
        switch token {
        case .rectangle:
            drawTool(.rectangle, "square", "矩形标注")
        case .circle:
            drawTool(.circle, "circle", "圆形标注")
        case .emoji:
            EmojiToolbarButton(state: state, help: "表情与符号", onClick: onEmoji)
                .frame(width: AnnotationEditorMetrics.toolbarButtonSize,
                       height: AnnotationEditorMetrics.toolbarButtonSize)
        case .arrow:
            drawTool(.arrow, "arrow.up.right", "箭头")
        case .pen:
            drawTool(.pen, "pencil", "画笔")
        case .mosaic:
            drawTool(.mosaic, "squareshape.split.3x3", "马赛克")
        case .text:
            drawTool(.text, "character.textbox", "文字")
        case .ocrTranslate:
            drawTool(.ocrTranslate, "translate", "OCR 翻译")
        case .ocr:
            drawTool(.ocr, "doc.text.magnifyingglass", "识别文字")
        case .crop:
            drawTool(.crop, "crop", "裁剪")
        case .undo:
            actionButton("arrow.uturn.left", "撤销", action: onUndo)
        case .save:
            actionButton("square.and.arrow.down", "保存", action: onSave)
        case .pin:
            actionButton("pin", "钉图", action: onPin)
        case .share:
            actionButton("arrowshape.turn.up.right", "分享", action: onShare)
        case .cancel:
            cancelButton
        case .confirm:
            confirmButton
        }
    }

    @ViewBuilder
    private func drawTool(_ tool: AnnotationTool, _ icon: String, _ tip: String) -> some View {
        let supportsStyle = configurableTools.contains(tool)

        if supportsStyle {
            ConfigurableToolToolbarButton(state: state, tool: tool, systemName: icon, help: tip)
                .frame(width: AnnotationEditorMetrics.toolbarButtonSize,
                       height: AnnotationEditorMetrics.toolbarButtonSize)
        } else {
            Button {
                if tool == .ocr {
                    state.selectedTool = tool
                    onOCR()
                } else if tool == .ocrTranslate {
                    state.selectedTool = tool
                    onOCRTranslate()
                } else {
                    state.selectedTool = tool
                }
            } label: {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: AnnotationEditorMetrics.toolbarButtonSize,
                           height: AnnotationEditorMetrics.toolbarButtonSize)
            }
            .buttonStyle(.plain)
            .background(
                state.selectedTool == tool ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .help(tip)
        }
    }

    @ViewBuilder
    private func actionButton(_ icon: String, _ tip: String, action: @escaping () -> Void) -> some View {
        ToolbarActionButton(
            systemName: icon,
            help: tip,
            tintColor: nil,
            backgroundColor: nil,
            onClick: action
        )
        .frame(width: AnnotationEditorMetrics.toolbarButtonSize,
               height: AnnotationEditorMetrics.toolbarButtonSize)
    }

    private var cancelButton: some View {
        ToolbarActionButton(
            systemName: "xmark",
            help: "取消",
            tintColor: .systemRed,
            backgroundColor: .systemRed.withAlphaComponent(0.14),
            onClick: onCancel
        )
        .frame(width: AnnotationEditorMetrics.toolbarButtonSize,
               height: AnnotationEditorMetrics.toolbarButtonSize)
    }

    private var confirmButton: some View {
        ToolbarActionButton(
            systemName: "checkmark",
            help: "确认并复制",
            tintColor: .systemGreen,
            backgroundColor: .systemGreen.withAlphaComponent(0.14),
            onClick: onConfirm
        )
        .frame(width: AnnotationEditorMetrics.toolbarButtonSize,
               height: AnnotationEditorMetrics.toolbarButtonSize)
    }

    func withDock(_ dock: ToolbarDockPosition) -> AnnotationToolbarView {
        var copy = self
        copy.dock = dock
        return copy
    }
}

private struct EmojiPickerView: View {
    let onSelect: (String) -> Void

    private let items: [String] = [
        "😀", "😄", "😁", "😂", "🥹", "😎", "🤩", "🥳",
        "👍", "👏", "🙏", "👌", "🔥", "💯", "🎉", "⭐",
        "❤️", "💙", "💚", "🧡", "🖤", "💥", "💡", "📌",
        "✅", "❌", "⚠️", "🚀", "🎯", "📎", "📝", "🔒",
        "🔓", "📷", "🎈", "🧠", "💬", "📍", "🪄", "🧩"
    ]
    private let columns = [
        GridItem(.adaptive(minimum: 34, maximum: 44), spacing: 10)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Emoji")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            ScrollView(.vertical, showsIndicators: true) {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(items, id: \.self) { emoji in
                        Button {
                            onSelect(emoji)
                        } label: {
                            Text(emoji)
                                .font(.system(size: 22))
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.trailing, 2)
            }
        }
        .padding(12)
        .frame(width: 296, height: 240, alignment: .topLeading)
        .background(.ultraThinMaterial)
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
