import AppKit
import SwiftUI
import Vision
import Combine
import ImageIO
import UniformTypeIdentifiers

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
        let persistedTools: [AnnotationTool] = [.rectangle, .circle, .arrow, .pen, .mosaic, .text]
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
        let textFontSize = stored["textFontSize"] as? CGFloat
            ?? (stored["textFontSize"] as? Double).map { CGFloat($0) }
            ?? defaultStyle.textFontSize
        let mosaicRadius = stored["mosaicRadius"] as? CGFloat
            ?? (stored["mosaicRadius"] as? Double).map { CGFloat($0) }
            ?? defaultStyle.mosaicRadius
        let textFontName = (stored["textFontName"] as? String).flatMap { name in
            NSFont(name: name, size: textFontSize) != nil ? name : nil
        } ?? defaultStyle.textFontName
        let colorIndex = stored["colorIndex"] as? Int ?? 0
        let palette = Self.colorPalette
        let resolvedIndex = max(0, min(colorIndex, palette.count - 1))
        let color = palette[resolvedIndex]

        return AnnotationToolStyle(
            lineWidth: lineWidth,
            isFilled: defaultStyle.isFilled,
            color: color,
            textFontName: textFontName,
            textFontSize: textFontSize,
            mosaicRadius: mosaicRadius
        )
    }

    private func saveStyle(_ style: AnnotationToolStyle, for tool: AnnotationTool) {
        let nearestColorIndex = Self.colorPalette.enumerated().min {
            colorDistance(style.color, $0.element) < colorDistance(style.color, $1.element)
        }?.offset ?? 0

        styleStorage.set(
            [
                "lineWidth": Double(style.lineWidth),
                "colorIndex": nearestColorIndex,
                "textFontName": style.textFontName,
                "textFontSize": Double(style.textFontSize),
                "mosaicRadius": Double(style.mosaicRadius)
            ],
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
        // Keep the editor in the active space with a stable normal-level z-order.
        // It should come to front after capture, but not keep forcing top-most priority.
        level = .normal
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        isOpaque = true
        backgroundColor = NSColor(white: 0.12, alpha: 1)
        hasShadow = true
        // NSPanel 默认在失焦时可能自动隐藏，这会导致“截图后编辑窗口不见了”的感知。
        hidesOnDeactivate = false
        isFloatingPanel = false
        title = EditorL10n.tr(.editorWindowTitle)
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
                DispatchQueue.main.async { [weak self] in
                    self?.canvas.applyCurrentTextStyleIfNeeded()
                    self?.canvas.needsDisplay = true
                }
            }
            .store(in: &cancellables)

        // Crop callback: resize the window
        canvas.onCropCompleted = { [weak self] newSize in
            self?.resizeAfterCrop(newSize: newSize)
        }

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

    override func cancelOperation(_ sender: Any?) {
        if canvas.cancelActiveTextEditingIfNeeded() {
            return
        }

        // Support Esc key to cancel the screenshot editing session,
        // matching the toolbar "X" behavior when not text-editing.
        cancelEditor()
    }

    override func close() {
        hideFloatingToolbar()
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
        if let panel = toolbarPanel {
            panel.refreshAnchorFrame(editorFrame: frame)
            panel.orderFrontRegardless()
            return
        }

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

    private func hideFloatingToolbar() {
        emojiPopover?.performClose(nil)
        emojiPopover = nil
        toolbarPanel?.orderOut(nil)
    }

    private func syncFloatingToolbarVisibility() {
        guard isVisible, !isMiniaturized, occlusionState.contains(.visible) else {
            hideFloatingToolbar()
            return
        }
        showFloatingToolbar()
    }

    override func orderOut(_ sender: Any?) {
        hideFloatingToolbar()
        super.orderOut(sender)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        syncFloatingToolbarVisibility()
    }

    func windowDidResignKey(_ notification: Notification) {
        if !NSApp.isActive {
            hideFloatingToolbar()
        }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        hideFloatingToolbar()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        syncFloatingToolbarVisibility()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        syncFloatingToolbarVisibility()
    }

    func windowDidBecomeMain(_ notification: Notification) {
        syncFloatingToolbarVisibility()
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
        let writableTypes = Self.writableImageTypes()
        let defaultType = writableTypes.contains(.png) ? UTType.png : (writableTypes.first ?? .png)

        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = false
        let resolvedTypes = writableTypes.isEmpty ? [.png] : writableTypes
        panel.allowedContentTypes = resolvedTypes
        panel.nameFieldStringValue = Self.defaultExportFileName(for: defaultType)
        panel.setValue(
            resolvedTypes.compactMap(\.preferredFilenameExtension),
            forKey: "allowedFileTypes"
        )

        panel.begin { [weak self] result in
            guard result == .OK, let self, let rawURL = panel.url else { return }
            do {
                let targetType = self.exportUTType(from: rawURL, fallback: defaultType)
                let finalURL = self.normalizedExportURL(rawURL, for: targetType)
                try self.writeImage(image, to: finalURL, type: targetType)
            } catch {
                self.showAlert(
                    title: EditorL10n.tr(.saveFailedTitle),
                    message: "\(EditorL10n.tr(.saveFailedMessagePrefix))\n\(error.localizedDescription)"
                )
            }
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
            showAlert(title: EditorL10n.tr(.ocrEmptyTitle), message: EditorL10n.tr(.ocrEmptyMessage))
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        NSSound.beep()
        showAlert(
            title: EditorL10n.tr(.ocrDoneTitle),
            message: String(format: EditorL10n.tr(.ocrDoneMessageFormat), text.count)
        )
    }

    private func openTranslation(text: String) {
        guard !text.isEmpty else {
            showAlert(title: EditorL10n.tr(.ocrEmptyTitle), message: EditorL10n.tr(.ocrTranslatableEmptyMessage))
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

    private static func writableImageTypes() -> [UTType] {
        let ids = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        let types = ids.compactMap { UTType($0) }
            .filter { $0.conforms(to: .image) }
        return types.sorted { lhs, rhs in
            (lhs.localizedDescription ?? lhs.identifier) < (rhs.localizedDescription ?? rhs.identifier)
        }
    }

    private static func defaultExportFileName(for type: UTType) -> String {
        let timestamp = exportFileNameFormatter.string(from: Date())
        let baseName = "StackShot_\(timestamp)"
        return exportFileName(baseName: baseName, for: type)
    }

    private static func exportFileName(baseName: String, for type: UTType) -> String {
        let ext = type.preferredFilenameExtension ?? "png"
        return "\(baseName).\(ext)"
    }

    private static let exportFileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return formatter
    }()

    private func exportUTType(from url: URL, fallback: UTType) -> UTType {
        if
            let ext = url.pathExtension.nilIfEmpty,
            let byExtension = UTType(filenameExtension: ext),
            byExtension.conforms(to: .image)
        {
            return byExtension
        }
        return fallback
    }

    private func normalizedExportURL(_ url: URL, for type: UTType) -> URL {
        guard url.pathExtension.isEmpty,
              let ext = type.preferredFilenameExtension else {
            return url
        }
        return url.appendingPathExtension(ext)
    }

    private func writeImage(_ image: NSImage, to url: URL, type: UTType) throws {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "StackShot.Export", code: 1, userInfo: [NSLocalizedDescriptionKey: EditorL10n.tr(.exportReadImageDataFailed)])
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw NSError(domain: "StackShot.Export", code: 2, userInfo: [NSLocalizedDescriptionKey: EditorL10n.tr(.exportUnsupportedType)])
        }

        let options: CFDictionary?
        if type.conforms(to: .jpeg) || type.conforms(to: .heic) || type.conforms(to: .heif) {
            options = [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        } else {
            options = nil
        }

        CGImageDestinationAddImage(destination, cgImage, options)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "StackShot.Export", code: 3, userInfo: [NSLocalizedDescriptionKey: EditorL10n.tr(.exportWriteFailed)])
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText     = title
        alert.informativeText = message
        alert.alertStyle      = .informational
        alert.addButton(withTitle: EditorL10n.tr(.okButton))
        alert.beginSheetModal(for: self)
    }

}

private enum EditorL10nKey {
    case editorWindowTitle
    case saveFailedTitle
    case saveFailedMessagePrefix
    case ocrEmptyTitle
    case ocrEmptyMessage
    case ocrDoneTitle
    case ocrDoneMessageFormat
    case ocrTranslatableEmptyMessage
    case exportReadImageDataFailed
    case exportUnsupportedType
    case exportWriteFailed
    case okButton
    case toolRectangle
    case toolCircle
    case toolEmoji
    case toolArrow
    case toolPen
    case toolMosaic
    case toolText
    case toolOCRTranslate
    case toolOCR
    case toolCrop
    case actionUndo
    case actionSave
    case actionPin
    case actionShare
    case actionCancel
    case actionConfirmCopy
    case emojiPickerTitle
    case textStyleFont
    case textStyleSize
    case mosaicRadius
}

private enum EditorL10n {
    static func tr(_ key: EditorL10nKey) -> String {
        let locale = L10n.currentSelectionCode()
        if locale == "zh-Hant" {
            return zhHant[key] ?? en[key] ?? ""
        }
        if locale == "zh-Hans" {
            return zhHans[key] ?? en[key] ?? ""
        }
        return en[key] ?? ""
    }

    private static let zhHans: [EditorL10nKey: String] = [
        .editorWindowTitle: "编辑截图",
        .saveFailedTitle: "保存失败",
        .saveFailedMessagePrefix: "无法保存图片，请重试。",
        .ocrEmptyTitle: "未识别到文字",
        .ocrEmptyMessage: "图片中没有可识别的文字。",
        .ocrDoneTitle: "文字识别完成",
        .ocrDoneMessageFormat: "已识别 %d 个字符并复制到剪贴板。",
        .ocrTranslatableEmptyMessage: "图片中没有可翻译的文字。",
        .exportReadImageDataFailed: "无法读取图像数据。",
        .exportUnsupportedType: "不支持该文件格式。",
        .exportWriteFailed: "系统写入文件失败。",
        .okButton: "好",
        .toolRectangle: "矩形标注",
        .toolCircle: "圆形标注",
        .toolEmoji: "表情与符号",
        .toolArrow: "箭头",
        .toolPen: "画笔",
        .toolMosaic: "马赛克",
        .toolText: "文字",
        .toolOCRTranslate: "OCR 翻译",
        .toolOCR: "识别文字",
        .toolCrop: "裁剪",
        .actionUndo: "撤销",
        .actionSave: "保存",
        .actionPin: "钉图",
        .actionShare: "分享",
        .actionCancel: "取消",
        .actionConfirmCopy: "确认并复制",
        .emojiPickerTitle: "Emoji",
        .textStyleFont: "字体",
        .textStyleSize: "字号",
        .mosaicRadius: "半径"
    ]

    private static let zhHant: [EditorL10nKey: String] = [
        .editorWindowTitle: "編輯截圖",
        .saveFailedTitle: "儲存失敗",
        .saveFailedMessagePrefix: "無法儲存圖片，請再試一次。",
        .ocrEmptyTitle: "未辨識到文字",
        .ocrEmptyMessage: "圖片中沒有可辨識的文字。",
        .ocrDoneTitle: "文字辨識完成",
        .ocrDoneMessageFormat: "已辨識 %d 個字元並複製到剪貼簿。",
        .ocrTranslatableEmptyMessage: "圖片中沒有可翻譯的文字。",
        .exportReadImageDataFailed: "無法讀取圖像資料。",
        .exportUnsupportedType: "不支援此檔案格式。",
        .exportWriteFailed: "系統寫入檔案失敗。",
        .okButton: "好",
        .toolRectangle: "矩形標註",
        .toolCircle: "圓形標註",
        .toolEmoji: "表情與符號",
        .toolArrow: "箭頭",
        .toolPen: "畫筆",
        .toolMosaic: "馬賽克",
        .toolText: "文字",
        .toolOCRTranslate: "OCR 翻譯",
        .toolOCR: "辨識文字",
        .toolCrop: "裁剪",
        .actionUndo: "復原",
        .actionSave: "儲存",
        .actionPin: "釘圖",
        .actionShare: "分享",
        .actionCancel: "取消",
        .actionConfirmCopy: "確認並複製",
        .emojiPickerTitle: "Emoji",
        .textStyleFont: "字體",
        .textStyleSize: "字號",
        .mosaicRadius: "半徑"
    ]

    private static let en: [EditorL10nKey: String] = [
        .editorWindowTitle: "Edit Screenshot",
        .saveFailedTitle: "Save Failed",
        .saveFailedMessagePrefix: "Unable to save the image. Please try again.",
        .ocrEmptyTitle: "No Text Detected",
        .ocrEmptyMessage: "No recognizable text was found in the image.",
        .ocrDoneTitle: "Text Recognition Complete",
        .ocrDoneMessageFormat: "Recognized %d characters and copied them to the clipboard.",
        .ocrTranslatableEmptyMessage: "No translatable text was found in the image.",
        .exportReadImageDataFailed: "Unable to read image data.",
        .exportUnsupportedType: "This file type is not supported.",
        .exportWriteFailed: "The system failed to write the file.",
        .okButton: "OK",
        .toolRectangle: "Rectangle",
        .toolCircle: "Circle",
        .toolEmoji: "Emoji & Symbols",
        .toolArrow: "Arrow",
        .toolPen: "Pen",
        .toolMosaic: "Mosaic",
        .toolText: "Text",
        .toolOCRTranslate: "OCR Translate",
        .toolOCR: "Recognize Text",
        .toolCrop: "Crop",
        .actionUndo: "Undo",
        .actionSave: "Save",
        .actionPin: "Pin",
        .actionShare: "Share",
        .actionCancel: "Cancel",
        .actionConfirmCopy: "Confirm & Copy",
        .emojiPickerTitle: "Emoji",
        .textStyleFont: "Font",
        .textStyleSize: "Size",
        .mosaicRadius: "Radius"
    ]
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
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
        // Only use the top strip as drag handle; otherwise forward events so
        // SwiftUI/AppKit toolbar buttons (e.g. text tool) can receive clicks.
        guard isInDragRegion else {
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
            if state.selectedTool == tool {
                state.selectedTool = nil
                popover?.performClose(nil)
                return
            }

            if let p = popover, p.isShown {
                p.performClose(nil)
            }

            state.selectedTool = tool
            AnnotationStylePopoverSession.closeActive()
            presentPopover(anchoredTo: sender)
        }

        private func presentPopover(anchoredTo sender: NSButton) {
            let pop = NSPopover()
            pop.behavior = .applicationDefined
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
                tool: tool,
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
            if state.selectedTool != tool {
                pop.performClose(nil)
            }
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

    private let configurableTools: Set<AnnotationTool> = [.rectangle, .circle, .arrow, .pen, .mosaic, .text]
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
            drawTool(.rectangle, "square", EditorL10n.tr(.toolRectangle))
        case .circle:
            drawTool(.circle, "circle", EditorL10n.tr(.toolCircle))
        case .emoji:
            EmojiToolbarButton(state: state, help: EditorL10n.tr(.toolEmoji), onClick: onEmoji)
                .frame(width: AnnotationEditorMetrics.toolbarButtonSize,
                       height: AnnotationEditorMetrics.toolbarButtonSize)
        case .arrow:
            drawTool(.arrow, "arrow.up.right", EditorL10n.tr(.toolArrow))
        case .pen:
            drawTool(.pen, "pencil", EditorL10n.tr(.toolPen))
        case .mosaic:
            drawTool(.mosaic, "checkerboard.rectangle", EditorL10n.tr(.toolMosaic))
        case .text:
            drawTool(.text, "t.square", EditorL10n.tr(.toolText))
        case .ocrTranslate:
            drawTool(.ocrTranslate, "translate", EditorL10n.tr(.toolOCRTranslate))
        case .ocr:
            drawTool(.ocr, "doc.text.magnifyingglass", EditorL10n.tr(.toolOCR))
        case .crop:
            drawTool(.crop, "crop", EditorL10n.tr(.toolCrop))
        case .undo:
            actionButton("arrow.uturn.left", EditorL10n.tr(.actionUndo), action: onUndo)
        case .save:
            actionButton("square.and.arrow.down", EditorL10n.tr(.actionSave), action: onSave)
        case .pin:
            actionButton("pin", EditorL10n.tr(.actionPin), action: onPin)
        case .share:
            actionButton("arrowshape.turn.up.right", EditorL10n.tr(.actionShare), action: onShare)
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
            help: EditorL10n.tr(.actionCancel),
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
            help: EditorL10n.tr(.actionConfirmCopy),
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
            Text(EditorL10n.tr(.emojiPickerTitle))
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
    let tool: AnnotationTool
    @Binding var style: AnnotationToolStyle
    let palette: [NSColor]

    private let minLineWidth: CGFloat = 1
    private let maxLineWidth: CGFloat = 14
    private let presetLineWidths: [CGFloat] = [2, 3, 4, 6, 8]
    private let minTextSize: CGFloat = 12
    private let maxTextSize: CGFloat = 96
    private let presetTextSizes: [CGFloat] = [14, 18, 20, 24, 32, 48]
    private let minMosaicRadius: CGFloat = 6
    private let maxMosaicRadius: CGFloat = 80
    private let presetMosaicRadii: [CGFloat] = [10, 18, 28, 40, 56]
    private let columns = Array(repeating: GridItem(.fixed(22), spacing: 8), count: 6)
    private let textFontCandidates: [String] = [
        "SFProDisplay-Semibold",
        "HelveticaNeue-Medium",
        "Arial-BoldMT",
        "PingFangSC-Semibold",
        "HiraginoSansGB-W6",
        "HiraginoSans-W6",
        "NotoSansCJKsc-Bold",
        "NotoSansCJKtc-Bold",
        "Songti SC",
        "KohinoorDevanagari-Semibold"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if tool == .text {
                VStack(alignment: .leading, spacing: 8) {
                    Text(EditorL10n.tr(.textStyleFont))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { currentTextFontName },
                        set: { style.textFontName = $0 }
                    )) {
                        ForEach(availableTextFonts, id: \.self) { fontName in
                            Text(displayFontName(fontName)).tag(fontName)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .pickerStyle(.menu)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("\(EditorL10n.tr(.textStyleSize)) \(Int(style.textFontSize.rounded()))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(style.textFontSize) },
                            set: { style.textFontSize = CGFloat($0) }
                        ),
                        in: Double(minTextSize)...Double(maxTextSize)
                    )
                    .frame(width: 180)
                    let textSizeColumns = Array(repeating: GridItem(.fixed(42), spacing: 8), count: 3)
                    LazyVGrid(columns: textSizeColumns, spacing: 8) {
                        ForEach(presetTextSizes, id: \.self) { size in
                            Button {
                                style.textFontSize = size
                            } label: {
                                Text("\(Int(size))")
                                    .font(.system(size: 10, weight: .semibold))
                                    .frame(width: 42, height: 22)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(Color.primary.opacity(abs(style.textFontSize - size) < 0.6 ? 0.16 : 0.06))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if tool == .mosaic {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(EditorL10n.tr(.mosaicRadius)) \(Int(style.mosaicRadius.rounded()))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(style.mosaicRadius) },
                            set: { style.mosaicRadius = CGFloat($0) }
                        ),
                        in: Double(minMosaicRadius)...Double(maxMosaicRadius)
                    )
                    .frame(width: 180)

                    let mosaicColumns = Array(repeating: GridItem(.fixed(42), spacing: 8), count: 3)
                    LazyVGrid(columns: mosaicColumns, spacing: 8) {
                        ForEach(presetMosaicRadii, id: \.self) { radius in
                            Button {
                                style.mosaicRadius = radius
                            } label: {
                                Text("\(Int(radius))")
                                    .font(.system(size: 10, weight: .semibold))
                                    .frame(width: 42, height: 22)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(Color.primary.opacity(abs(style.mosaicRadius - radius) < 0.8 ? 0.16 : 0.06))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
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
            }

            if tool != .mosaic {
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
        }
        .padding(12)
        .frame(width: (tool == .text || tool == .mosaic) ? 228 : 210)
    }

    private var availableTextFonts: [String] {
        let supported = textFontCandidates.filter { NSFont(name: $0, size: style.textFontSize) != nil }
        if supported.isEmpty {
            return [NSFont.systemFont(ofSize: style.textFontSize, weight: .semibold).fontName]
        }
        return supported
    }

    private var currentTextFontName: String {
        let options = availableTextFonts
        if options.contains(style.textFontName) {
            return style.textFontName
        }
        return options[0]
    }

    private func displayFontName(_ fontName: String) -> String {
        if let font = NSFont(name: fontName, size: 13) {
            return font.displayName ?? fontName
        }
        return fontName
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
