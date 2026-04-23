import AppKit
import SwiftUI
@preconcurrency import Vision
import Combine
import ImageIO
import UniformTypeIdentifiers
import QuartzCore
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

private enum AnnotationEditorFeatureAvailability {
    static var supportsOCRTranslationUI: Bool {
        guard AppStoreComplianceFeatures.isOCRTranslationOverlayEnabled else {
            return false
        }
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            return true
        }
        #endif
        return false
    }
}

private enum AnnotationEditorMetrics {
    static let toolbarButtonSize: CGFloat = 36
    static let toolbarInterItemSpacing: CGFloat = 6
    static let toolbarRowSpacing: CGFloat = 6
    static let toolbarHorizontalPadding: CGFloat = 8
    static let toolbarVerticalPadding: CGFloat = 6
    static let toolbarGapToEditor: CGFloat = 4
    static let toolbarBelowRowCount: Int = 2
    static let toolbarRightColumnCount: Int = 2
    static let ocrSidebarPreferredWidth: CGFloat = 290
    static let ocrSidebarMinWidth: CGFloat = 200
    static let ocrSidebarInset: CGFloat = 12
    static let ocrMinimumScanDuration: TimeInterval = 1.5

    static var toolbarItemCount: Int {
        AnnotationEditorFeatureAvailability.supportsOCRTranslationUI ? 18 : 17
    }

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
    case leftOfEditor

    var popoverPreferredEdge: NSRectEdge {
        switch self {
        case .belowEditor:
            return .minY
        case .rightOfEditor:
            return .maxX
        case .leftOfEditor:
            return .minX
        }
    }
}

private enum AnnotationEditorOverlayLevels {
    static let backdrop = NSWindow.Level.screenSaver
    static let editor = NSWindow.Level(rawValue: backdrop.rawValue + 1)
    static let toolbar = NSWindow.Level(rawValue: editor.rawValue + 1)
}

private struct OCRUIRestoreState {
    var sidebarVisible: Bool
    var attributedText: NSAttributedString
    var selectedRange: NSRange
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
    @Published var selectedCropRect: CGRect = .zero
    @Published var isSelectionAdjustmentMode = false
    @Published var isOCRRunning = false
    @Published var isOCRTranslationApplied = false
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
        case .scrollCapture: return "scrollCapture"
        case .crop: return "crop"
        }
    }
}

// MARK: – Annotation editor window

protocol ConsoleTraceLogging {}

extension ConsoleTraceLogging {
    func debugLog(_ message: String, function: String = #function, line: Int = #line) {
        ConsoleTraceLogWriter.log(
            message,
            owner: String(describing: type(of: self)),
            function: function,
            line: line
        )
    }

    static func debugLog(_ message: String, function: String = #function, line: Int = #line) {
        ConsoleTraceLogWriter.log(
            message,
            owner: String(describing: Self.self),
            function: function,
            line: line
        )
    }
}

private enum ConsoleTraceLogWriter {
    static func log(_ message: String, owner: String, function: String, line: Int) {
        print("【调试】[\(owner)] [\(function):\(line)] \(message)")
    }
}

final class AnnotationEditorPanel: NSPanel, NSWindowDelegate, ConsoleTraceLogging {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private let canvas: AnnotationCanvasView
    private let state  = AnnotationEditorState()
    private let contentContainer = NSView()
    private let selectionInteractionOverlay = AnnotationSelectionInteractionOverlayView(frame: .zero)
    private let ocrScanOverlay = OCRScanOverlayView()
    private let ocrResultSidebar = NSVisualEffectView()
    private let ocrResultScrollView = NSScrollView()
    private let ocrResultTextView = NSTextView(frame: .zero)
    private let ocrResultLoadingIndicator = NSProgressIndicator()
    private var cancellables: Set<AnyCancellable> = []
    private var toolbarPanel: AnnotationToolbarFloatingPanel?
    private var emojiPopover: NSPopover?
    private var ocrSidebarWidthConstraint: NSLayoutConstraint?
    private var ocrSidebarContentConstraints: [NSLayoutConstraint] = []
    private var ocrLoadingStartTime: CFTimeInterval?
    private var ocrSessionToken = UUID()
    private var ocrCompletionWorkItem: DispatchWorkItem?
    private var ocrRestoreState: OCRUIRestoreState?
    // OCR 翻译流水线运行期间保留的隐藏 SwiftUI 宿主，用于承载 .translationTask。
    private var translationHostView: NSView?
    // OCR 翻译期间显示的进度 HUD。
    private var translateHUD: NSView?
    private var ocrTranslateTask: Task<Void, Never>?
    private var ocrTranslateSessionToken = UUID()
    private var isOCRTranslating = false
    private var preTranslationScreenshot: NSImage?
    private var editingBackdrop: AnnotationEditingBackdropPanel?
    private let sourceScreenSnapshot: CGImage?
    private let sourceDesktopBounds: CGRect?
    private var isOCRTranslationApplied: Bool {
        get { state.isOCRTranslationApplied }
        set { state.isOCRTranslationApplied = newValue }
    }
    /// Original screen-space capture rect (AppKit coords), used by scroll capture.
    private var originalCaptureRect: CGRect?

    /// Called when the user confirms or shares; passes the final annotated image.
    var onConfirm: ((NSImage) -> Void)?
    /// Called when the user cancels.
    var onCancel: (() -> Void)?
    /// Called whenever the editor window closes, regardless of reason.
    var onClose: (() -> Void)?

    // MARK: Init

    init(
        screenshot: NSImage,
        initialTool: AnnotationTool? = nil,
        captureRect: CGRect? = nil,
        sourceScreenSnapshot: CGImage? = nil,
        sourceDesktopBounds: CGRect? = nil
    ) {
        let resolvedInitialTool: AnnotationTool? = {
            guard initialTool == .ocrTranslate,
                  !AnnotationEditorFeatureAvailability.supportsOCRTranslationUI else {
                return initialTool
            }
            return nil
        }()
        let initialFrame = Self.initialEditorFrame(for: screenshot, captureRect: captureRect)
        self.sourceScreenSnapshot = sourceScreenSnapshot
        self.sourceDesktopBounds = sourceDesktopBounds

        self.canvas = AnnotationCanvasView(
            frame: CGRect(origin: .zero, size: initialFrame.size),
            screenshot: screenshot
        )

        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        level = AnnotationEditorOverlayLevels.editor
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        title = EditorL10n.tr(.editorWindowTitle)
        isMovable = false
        isMovableByWindowBackground = false
        minSize = NSSize(width: 80, height: 60)
        delegate = self

        self.updateSelectedCropRect(captureRect)
        state.isSelectionAdjustmentMode = false
        setupContent(canvasW: initialFrame.width, canvasH: initialFrame.height)
        editingBackdrop = AnnotationEditingBackdropPanel(level: AnnotationEditorOverlayLevels.backdrop)
        editingBackdrop?.onSelectionFrameChange = { [weak self] newFrame in
            self?.applyAdjustedSelectionFrame(newFrame)
        }
        editingBackdrop?.onCancelRequested = { [weak self] in
            self?.cancelEditor()
        }
        editingBackdrop?.onConfirmRequested = { [weak self] in
            self?.confirmEditorFromBackdrop()
        }

        // Apply initial tool (e.g. pre-selected from the hover toolbar)
        state.selectedTool = resolvedInitialTool
        canvas.styleProvider = { [weak state] tool in
            state?.style(for: tool) ?? .default(for: tool)
        }

        // For OCR tools triggered from the hover toolbar, fire OCR automatically
        // after the window has appeared (short delay lets the window settle).
        if resolvedInitialTool == .ocr || resolvedInitialTool == .ocrTranslate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.performOCR(translate: resolvedInitialTool == .ocrTranslate)
            }
        }

        // Observe tool selection: keep canvas in sync
        state.$selectedTool
            .sink { [weak self] tool in
                if tool != nil, self?.state.isSelectionAdjustmentMode == true {
                    self?.state.isSelectionAdjustmentMode = false
                }
                self?.canvas.currentTool = tool
                self?.updateSelectionAdjustmentAvailability()
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

    private func updateSelectedCropRect(_ rect: CGRect?) {
        originalCaptureRect = rect
        state.selectedCropRect = rect ?? .zero
    }

    private func setupContent(canvasW: CGFloat, canvasH: CGFloat) {
        contentContainer.frame = CGRect(x: 0, y: 0, width: canvasW, height: canvasH)
        contentContainer.autoresizingMask = [.width, .height]
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = NSColor.clear.cgColor
        contentContainer.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.92).cgColor
        contentContainer.layer?.borderWidth = 2
        contentContainer.layer?.masksToBounds = true
        contentView = contentContainer
        windowController?.window?.acceptsMouseMovedEvents = true
        acceptsMouseMovedEvents = true

        selectionInteractionOverlay.translatesAutoresizingMaskIntoConstraints = false
        selectionInteractionOverlay.onFrameChange = { [weak self] newFrame in
            self?.applyAdjustedSelectionFrame(newFrame)
        }

        // Canvas
        canvas.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(canvas)

        setupOCRScanOverlay()
        contentContainer.addSubview(ocrScanOverlay)

        setupOCRResultSidebar()
        contentContainer.addSubview(ocrResultSidebar)
        contentContainer.addSubview(selectionInteractionOverlay)

        let sidebarWidthConstraint = ocrResultSidebar.widthAnchor.constraint(equalToConstant: 0)
        ocrSidebarWidthConstraint = sidebarWidthConstraint

        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            canvas.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            canvas.trailingAnchor.constraint(equalTo: ocrResultSidebar.leadingAnchor),

            ocrScanOverlay.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            ocrScanOverlay.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            ocrScanOverlay.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ocrScanOverlay.trailingAnchor.constraint(equalTo: ocrResultSidebar.leadingAnchor),

            ocrResultSidebar.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            ocrResultSidebar.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ocrResultSidebar.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            sidebarWidthConstraint,

            selectionInteractionOverlay.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            selectionInteractionOverlay.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            selectionInteractionOverlay.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            selectionInteractionOverlay.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])

        updateSelectionAdjustmentAvailability()
    }

    private func resizeAfterCrop(newSize: NSSize) {
        let newW = max(newSize.width, 80)
        let newH = max(newSize.height, 60)
        let current = frame
        let sidebarWidth = currentOCRSidebarWidth
        let newFrame = CGRect(
            x: current.midX - (newW + sidebarWidth) / 2,
            y: current.midY - newH / 2,
            width: newW + sidebarWidth, height: newH
        )
        let updatedCaptureRect = CGRect(
            x: newFrame.minX,
            y: newFrame.minY,
            width: newW,
            height: newH
        )
        setFrame(newFrame, display: true, animate: true)
        updateSelectedCropRect(updatedCaptureRect)
        syncBackdropSelectionFrame()
    }

    private var canAdjustSelectionInline: Bool {
        sourceScreenSnapshot != nil && sourceDesktopBounds != nil && state.isSelectionAdjustmentMode
    }

    private func updateSelectionAdjustmentAvailability() {
        selectionInteractionOverlay.isInteractionEnabled = canAdjustSelectionInline
        editingBackdrop?.allowsSelectionCreation = canAdjustSelectionInline
    }

    private func applyAdjustedSelectionFrame(_ newFrame: CGRect) {
        let normalized = CGRect(
            x: round(newFrame.origin.x),
            y: round(newFrame.origin.y),
            width: round(newFrame.width),
            height: round(newFrame.height)
        )
        guard normalized.width >= 2, normalized.height >= 2 else { return }
        guard frame != normalized else { return }

        setFrame(normalized, display: true, animate: false)
        updateSelectedCropRect(normalized)
        syncBackdropSelectionFrame()

        guard let snapshot = sourceScreenSnapshot,
              let desktopBounds = sourceDesktopBounds,
              let image = Self.cropSnapshot(snapshot, desktopBounds: desktopBounds, captureRect: normalized) else {
            return
        }

        canvas.screenshot = image
    }

    private static func cropSnapshot(
        _ snapshot: CGImage,
        desktopBounds: CGRect,
        captureRect: CGRect
    ) -> NSImage? {
        guard desktopBounds.width > 0, desktopBounds.height > 0 else { return nil }

        let scaleX = CGFloat(snapshot.width) / desktopBounds.width
        let scaleY = CGFloat(snapshot.height) / desktopBounds.height
        let pixelRect = CGRect(
            x: (captureRect.minX - desktopBounds.minX) * scaleX,
            y: (desktopBounds.maxY - captureRect.maxY) * scaleY,
            width: captureRect.width * scaleX,
            height: captureRect.height * scaleY
        ).integral.intersection(CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height))

        guard pixelRect.width >= 1,
              pixelRect.height >= 1,
              let cropped = snapshot.cropping(to: pixelRect) else {
            return nil
        }

        return NSImage(cgImage: cropped, size: captureRect.size)
    }

    private static func initialEditorFrame(for screenshot: NSImage, captureRect: CGRect?) -> CGRect {
        if let captureRect,
           captureRect.width > 1,
           captureRect.height > 1 {
            return captureRect
        }

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

        return CGRect(
            x: screen.midX - canvasW / 2,
            y: screen.midY - canvasH / 2,
            width: canvasW,
            height: canvasH
        )
    }

    private func showEditingBackdrop() {
        syncBackdropSelectionFrame()
        editingBackdrop?.orderFrontRegardless()
    }

    private func hideEditingBackdrop() {
        editingBackdrop?.orderOut(nil)
    }

    private func syncBackdropSelectionFrame() {
        editingBackdrop?.setSelectionFrame(frame)
    }

    private var currentOCRSidebarWidth: CGFloat {
        ocrSidebarWidthConstraint?.constant ?? 0
    }

    private var isOCRSidebarPresented: Bool {
        currentOCRSidebarWidth > 0.5 && !ocrResultSidebar.isHidden
    }

    private var preferredOCRTextWidth: CGFloat {
        let targetSidebarWidth = max(currentOCRSidebarWidth, preferredOCRSidebarWidth(for: frame))
        return max(160, targetSidebarWidth - AnnotationEditorMetrics.ocrSidebarInset * 2 - 8)
    }

    private func setupOCRScanOverlay() {
        ocrScanOverlay.translatesAutoresizingMaskIntoConstraints = false
        ocrScanOverlay.isHidden = true
    }

    private func setupOCRResultSidebar() {
        ocrResultSidebar.translatesAutoresizingMaskIntoConstraints = false
        ocrResultSidebar.material = .sidebar
        ocrResultSidebar.blendingMode = .withinWindow
        ocrResultSidebar.state = .active
        ocrResultSidebar.isHidden = true
        ocrResultSidebar.wantsLayer = true
        ocrResultSidebar.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.28).cgColor
        ocrResultSidebar.layer?.borderWidth = 0.8

        ocrResultTextView.isEditable = true
        ocrResultTextView.isSelectable = true
        ocrResultTextView.isRichText = true
        ocrResultTextView.usesFindBar = true
        ocrResultTextView.allowsUndo = true
        ocrResultTextView.drawsBackground = false
        ocrResultTextView.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        ocrResultTextView.textContainerInset = NSSize(width: 4, height: 8)
        ocrResultTextView.importsGraphics = false
        ocrResultTextView.isAutomaticQuoteSubstitutionEnabled = false
        ocrResultTextView.isAutomaticDashSubstitutionEnabled = false
        ocrResultTextView.isAutomaticTextReplacementEnabled = false
        ocrResultTextView.isAutomaticTextCompletionEnabled = false
        ocrResultTextView.isContinuousSpellCheckingEnabled = false
        ocrResultTextView.minSize = .zero
        ocrResultTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        ocrResultTextView.isHorizontallyResizable = false
        ocrResultTextView.isVerticallyResizable = true
        ocrResultTextView.autoresizingMask = [.width]
        ocrResultTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        ocrResultTextView.textContainer?.widthTracksTextView = true

        ocrResultScrollView.translatesAutoresizingMaskIntoConstraints = false
        ocrResultScrollView.borderType = .noBorder
        ocrResultScrollView.drawsBackground = false
        ocrResultScrollView.hasVerticalScroller = true
        ocrResultScrollView.autohidesScrollers = true
        ocrResultScrollView.documentView = ocrResultTextView
        ocrResultScrollView.isHidden = true

        ocrResultLoadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        ocrResultLoadingIndicator.style = .spinning
        ocrResultLoadingIndicator.controlSize = .regular
        ocrResultLoadingIndicator.isDisplayedWhenStopped = false
        ocrResultLoadingIndicator.isHidden = true

        ocrResultSidebar.addSubview(ocrResultScrollView)
        ocrResultSidebar.addSubview(ocrResultLoadingIndicator)

        ocrSidebarContentConstraints = [
            ocrResultScrollView.leadingAnchor.constraint(equalTo: ocrResultSidebar.leadingAnchor, constant: AnnotationEditorMetrics.ocrSidebarInset),
            ocrResultScrollView.trailingAnchor.constraint(equalTo: ocrResultSidebar.trailingAnchor, constant: -AnnotationEditorMetrics.ocrSidebarInset),
            ocrResultScrollView.topAnchor.constraint(equalTo: ocrResultSidebar.topAnchor, constant: AnnotationEditorMetrics.ocrSidebarInset),
            ocrResultScrollView.bottomAnchor.constraint(equalTo: ocrResultSidebar.bottomAnchor, constant: -AnnotationEditorMetrics.ocrSidebarInset),
        ]

        NSLayoutConstraint.activate([
            ocrResultLoadingIndicator.centerXAnchor.constraint(equalTo: ocrResultSidebar.centerXAnchor),
            ocrResultLoadingIndicator.centerYAnchor.constraint(equalTo: ocrResultSidebar.centerYAnchor),
        ])
    }

    private func setOCRSidebarVisible(_ visible: Bool, animated: Bool) {
        guard let widthConstraint = ocrSidebarWidthConstraint else { return }

        let currentSidebarWidth = widthConstraint.constant
        let targetSidebarWidth = visible ? preferredOCRSidebarWidth(for: frame) : 0
        guard abs(currentSidebarWidth - targetSidebarWidth) > 0.5 || ocrResultSidebar.isHidden == visible else {
            return
        }

        let baseEditorWidth = frame.width - currentSidebarWidth
        let totalWidth = min(baseEditorWidth + targetSidebarWidth, visibleFrameForEditor(frame).width)
        let actualSidebarWidth = max(0, totalWidth - baseEditorWidth)

        var newFrame = frame
        newFrame.size.width = totalWidth
        let visibleFrame = visibleFrameForEditor(newFrame)
        newFrame.origin.x = min(newFrame.origin.x, visibleFrame.maxX - newFrame.width)
        newFrame.origin.x = max(visibleFrame.minX, newFrame.origin.x)

        if actualSidebarWidth == 0 {
            setOCRSidebarContentConstraintsActive(false)
        }

        ocrResultSidebar.isHidden = false
        widthConstraint.constant = actualSidebarWidth

        if actualSidebarWidth > 0 {
            setOCRSidebarContentConstraintsActive(true)
        }

        // Note: avoid an explicit layoutSubtreeIfNeeded() here. The
        // following setFrame(display: true, animate:) drives the
        // layout pass on its own, and forcing it eagerly can trigger
        // "-layoutSubtreeIfNeeded on a view which is already being
        // laid out" warnings when this method is reached from inside a
        // SwiftUI hosting view's layout cycle.
        setFrame(newFrame, display: true, animate: animated)
        if actualSidebarWidth == 0 {
            ocrResultSidebar.isHidden = true
        }
    }

    private func setOCRSidebarContentConstraintsActive(_ active: Bool) {
        if active {
            NSLayoutConstraint.activate(ocrSidebarContentConstraints)
        } else {
            NSLayoutConstraint.deactivate(ocrSidebarContentConstraints)
        }
    }

    private func preferredOCRSidebarWidth(for windowFrame: CGRect) -> CGFloat {
        let visibleFrame = visibleFrameForEditor(windowFrame)
        let baseEditorWidth = windowFrame.width - currentOCRSidebarWidth
        let maxSidebarWidth = max(0, visibleFrame.width - baseEditorWidth)
        guard maxSidebarWidth > 0 else { return 0 }
        if maxSidebarWidth >= AnnotationEditorMetrics.ocrSidebarMinWidth {
            return min(AnnotationEditorMetrics.ocrSidebarPreferredWidth, maxSidebarWidth)
        }
        return maxSidebarWidth
    }

    private func visibleFrameForEditor(_ windowFrame: CGRect) -> CGRect {
        let probePoint = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(probePoint) }) ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func beginOCRLoadingUI() {
        debugLog("开始准备 OCR 界面状态。")
        cancelPendingOCRCompletion()
        captureOCRRestoreState()
        state.isOCRRunning = true
        ocrSessionToken = UUID()
        ocrLoadingStartTime = CACurrentMediaTime()
        ocrResultTextView.textStorage?.setAttributedString(NSAttributedString())
        ocrResultTextView.setSelectedRange(NSRange(location: 0, length: 0))
        ocrResultScrollView.isHidden = true
        let preserveSidebar = ocrRestoreState?.sidebarVisible == true
        ocrResultLoadingIndicator.isHidden = !preserveSidebar
        if preserveSidebar {
            ocrResultSidebar.isHidden = false
            setOCRSidebarContentConstraintsActive(true)
            ocrResultLoadingIndicator.startAnimation(nil)
        } else {
            ocrResultLoadingIndicator.stopAnimation(nil)
            setOCRSidebarVisible(false, animated: false)
        }
        ocrScanOverlay.startAnimating()
        debugLog("OCR 加载态已启动，保留侧边栏=\(preserveSidebar)。")
    }

    private func showOCRResultsUI(with attributedText: NSAttributedString) {
        debugLog("准备展示 OCR 结果，字符数=\(attributedText.string.count)。")
        ocrResultLoadingIndicator.stopAnimation(nil)
        ocrResultLoadingIndicator.isHidden = true
        ocrResultTextView.textStorage?.setAttributedString(attributedText)
        if attributedText.length > 0 {
            ocrResultTextView.typingAttributes = attributedText.attributes(at: 0, effectiveRange: nil)
        } else {
            ocrResultTextView.typingAttributes = [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
        }
        ocrResultTextView.setSelectedRange(NSRange(location: 0, length: 0))
        ocrResultScrollView.isHidden = false
        setOCRSidebarVisible(true, animated: true)
        ocrRestoreState = nil
        debugLog("OCR 结果已展示，侧边栏已展开。")
    }

    private func finishOCRLoadingUI() {
        debugLog("结束 OCR 加载态。")
        state.isOCRRunning = false
        ocrLoadingStartTime = nil
        ocrScanOverlay.stopAnimating()
        ocrResultLoadingIndicator.stopAnimation(nil)
        ocrResultLoadingIndicator.isHidden = true
    }

    private func resetOCRUI(hideSidebar: Bool) {
        debugLog("重置 OCR 界面，hideSidebar=\(hideSidebar)。")
        cancelPendingOCRCompletion()
        state.isOCRRunning = false
        ocrLoadingStartTime = nil
        ocrScanOverlay.stopAnimating()
        ocrResultLoadingIndicator.stopAnimation(nil)
        ocrResultLoadingIndicator.isHidden = true
        ocrResultScrollView.isHidden = true
        ocrResultTextView.textStorage?.setAttributedString(NSAttributedString())
        ocrRestoreState = nil
        if hideSidebar {
            setOCRSidebarVisible(false, animated: true)
        }
    }

    private func captureOCRRestoreState() {
        let attributedText = NSAttributedString(
            attributedString: ocrResultTextView.textStorage ?? NSTextStorage()
        )
        ocrRestoreState = OCRUIRestoreState(
            sidebarVisible: isOCRSidebarPresented,
            attributedText: attributedText,
            selectedRange: ocrResultTextView.selectedRange()
        )
    }

    private func restoreOCRUIAfterFailure(postRestore: ((AnnotationEditorPanel) -> Void)? = nil) {
        debugLog("OCR 失败后准备恢复界面状态。")
        finishOCRLoadingUI()

        guard let snapshot = ocrRestoreState else {
            resetOCRUI(hideSidebar: true)
            postRestore?(self)
            return
        }

        if snapshot.sidebarVisible {
            ocrResultSidebar.isHidden = false
            setOCRSidebarContentConstraintsActive(true)
            ocrResultTextView.textStorage?.setAttributedString(snapshot.attributedText)
            if snapshot.attributedText.length > 0 {
                ocrResultTextView.typingAttributes = snapshot.attributedText.attributes(at: 0, effectiveRange: nil)
            } else {
                ocrResultTextView.typingAttributes = [
                    .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: NSColor.labelColor
                ]
            }
            ocrResultTextView.setSelectedRange(snapshot.selectedRange)
            ocrResultScrollView.isHidden = false
            setOCRSidebarVisible(true, animated: false)
        } else {
            ocrResultTextView.textStorage?.setAttributedString(NSAttributedString())
            ocrResultScrollView.isHidden = true
            setOCRSidebarVisible(false, animated: false)
        }

        ocrRestoreState = nil
        debugLog("OCR 界面恢复完成，sidebarVisible=\(snapshot.sidebarVisible)。")
        postRestore?(self)
    }

    // MARK: Actions

    private func confirmEditor() {
        debugLog("用户确认当前编辑结果，准备复制到剪贴板并结束编辑。")
        _ = canvas.commitActiveTextEditingIfNeeded()
        let image = canvas.renderToImage()
        writeToPasteboard(image)
        onConfirm?(image)
        close()
    }

    private func cancelEditor() {
        debugLog("用户取消当前编辑会话。")
        onCancel?()
        close()
    }

    private func confirmEditorFromBackdrop() {
        guard !isOCRTranslating else { return }
        confirmEditor()
    }

    private func deactivateActiveTool() {
        _ = canvas.commitActiveTextEditingIfNeeded()
        state.isSelectionAdjustmentMode = false
        state.selectedTool = nil
        AnnotationStylePopoverSession.closeActive()
        emojiPopover?.performClose(nil)
        emojiPopover = nil
        updateSelectionAdjustmentAvailability()
        makeKeyAndOrderFront(nil)
    }

    private func enterSelectionAdjustmentMode() {
        _ = canvas.commitActiveTextEditingIfNeeded()
        state.isSelectionAdjustmentMode = true
        state.selectedTool = nil
        AnnotationStylePopoverSession.closeActive()
        emojiPopover?.performClose(nil)
        emojiPopover = nil
        updateSelectionAdjustmentAvailability()
        makeKeyAndOrderFront(nil)
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        showEditingBackdrop()
        super.makeKeyAndOrderFront(sender)
        orderFrontRegardless()
        syncFloatingToolbarVisibility()
    }

    override func cancelOperation(_ sender: Any?) {
        if canvas.cancelActiveTextEditingIfNeeded() {
            return
        }

#if canImport(Translation)
        if #available(macOS 15.0, *), isOCRTranslating {
            cancelOCRTranslationProcess()
            return
        }
#endif

        if state.selectedTool != nil {
            deactivateActiveTool()
            return
        }

        // Support Esc key to cancel the screenshot editing session,
        // matching the toolbar "X" behavior when not text-editing.
        cancelEditor()
    }

    override func close() {
        cancelPendingOCRCompletion()
#if canImport(Translation)
        if #available(macOS 15.0, *), isOCRTranslating || translateHUD != nil || translationHostView != nil {
            cancelOCRTranslationProcess(restoreToolbar: false)
        }
#endif
        hideFloatingToolbar()
        hideEditingBackdrop()
        editingBackdrop?.close()
        editingBackdrop = nil
        emojiPopover?.performClose(nil)
        emojiPopover = nil
        toolbarPanel?.close()
        toolbarPanel = nil
        ocrScanOverlay.stopAnimating()
        super.close()
        onClose?()
    }

    private func presentEmojiPicker(anchorView: NSView, dock: ToolbarDockPosition) {
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

        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: dock.popoverPreferredEdge)
        toolbarPanel.orderFrontRegardless()
        emojiPopover = popover
    }

    func windowDidMove(_ notification: Notification) {
        syncBackdropSelectionFrame()
        toolbarPanel?.refreshAnchorFrame(editorFrame: frame)
    }

    func windowDidResize(_ notification: Notification) {
        syncBackdropSelectionFrame()
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
            onAdjustSelection: { [weak self] in self?.enterSelectionAdjustmentMode() },
            onUndo:         { [weak self] in self?.canvas.undo() },
            onSave:         { [weak self] in self?.saveToFile() },
            onPin:          { [weak self] in self?.pinToScreen() },
            onShare:        { [weak self] in self?.shareImage() },
            onCancel:       { [weak self] in self?.cancelEditor() },
            onConfirm:      { [weak self] in self?.confirmEditor() },
            onEmoji:        { [weak self] anchorView, dock in self?.presentEmojiPicker(anchorView: anchorView, dock: dock) },
            onOCR:          { [weak self] in self?.performOCR(translate: false) },
            onOCRTranslate: { [weak self] in self?.performOCRTranslation() },
            onScrollCapture:{ [weak self] rect in self?.performScrollCapture(selectedCropRect: rect) }
        )

        let panel = AnnotationToolbarFloatingPanel(
            editorFrame: frame,
            toolbarView: toolbarView,
            windowLevel: AnnotationEditorOverlayLevels.toolbar
        )
        panel.orderFrontRegardless()
        toolbarPanel = panel
    }

    private func hideFloatingToolbar() {
        emojiPopover?.performClose(nil)
        emojiPopover = nil
        toolbarPanel?.orderOut(nil)
    }

    private func syncFloatingToolbarVisibility() {
        guard isVisible, !isMiniaturized, occlusionState.contains(.visible), !isOCRTranslating else {
            hideFloatingToolbar()
            return
        }
        showFloatingToolbar()
    }

    override func orderOut(_ sender: Any?) {
        hideFloatingToolbar()
        hideEditingBackdrop()
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
        debugLog("收到分享请求，开始渲染当前画布。")
        let image = canvas.renderToImage()
        guard let cv = contentView else {
            debugLog("当前没有 contentView，回退为直接复制到剪贴板。")
            writeToPasteboard(image)
            return
        }
        let picker = NSSharingServicePicker(items: [image])
        // Anchor the picker near the bottom-right of the window
        let anchor = CGRect(x: cv.bounds.maxX - 60, y: 0, width: 40, height: 40)
        debugLog("准备展示系统分享面板，锚点=\(anchor)。")
        picker.show(relativeTo: anchor, of: cv, preferredEdge: .minY)
    }

    private func saveToFile() {
        debugLog("收到保存请求，开始渲染当前画布。")
        let image = canvas.renderToImage()
        let panel = NSSavePanel()
        let resolvedTypes = Self.writableImageTypes()
        let defaultType = resolvedTypes.contains(.png) ? UTType.png : (resolvedTypes.first ?? .png)
        let defaultFileName = Self.defaultExportFileName(for: defaultType)
        debugLog("已生成保存面板配置，默认格式=\(Self.displayName(for: defaultType))，默认文件名=\(defaultFileName)。")

        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = false
        panel.allowedContentTypes = [defaultType]
        panel.nameFieldStringValue = defaultFileName
        let formatAccessory = ExportFormatAccessoryController(
            panel: panel,
            writableTypes: resolvedTypes,
            defaultType: defaultType,
            defaultFileName: defaultFileName
        )
        panel.accessoryView = formatAccessory.view

        hideFloatingToolbar()
        debugLog("已隐藏浮动工具栏，并以 Sheet 形式展示保存面板。")

        panel.beginSheetModal(for: self) { [weak self, formatAccessory] result in
            defer { self?.syncFloatingToolbarVisibility() }
            guard let self else { return }
            guard result == .OK, let rawURL = panel.url else {
                self.debugLog("用户取消了保存操作。")
                return
            }
            do {
                let targetType = formatAccessory.selectedType
                let finalURL = self.normalizedExportURL(rawURL, for: targetType)
                self.debugLog("用户确认保存，目标格式=\(Self.displayName(for: targetType))，原始路径=\(rawURL.path)，最终路径=\(finalURL.path)。")
                try self.writeImage(image, to: finalURL, type: targetType)
                self.debugLog("图片保存完成。")
                self.close()
            } catch {
                self.debugLog("图片保存失败：\(error.localizedDescription)")
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

    // MARK: Scroll Capture

    private func performScrollCapture(selectedCropRect: CGRect) {
        let fallbackRect = originalCaptureRect ?? .zero
        let resolvedRect = (selectedCropRect.width >= 8 && selectedCropRect.height >= 8
                            ? selectedCropRect
                            : fallbackRect)
            .standardized
            .integral

        debugLog("触发滚动截图，当前裁剪区域=\(selectedCropRect)。")

        guard resolvedRect.width >= 8, resolvedRect.height >= 8 else {
            debugLog("滚动截图已中止：当前裁剪区域无效，state=\(selectedCropRect)，fallback=\(fallbackRect)。")
            return
        }
        updateSelectedCropRect(resolvedRect)
        debugLog("即将进入滚动截图流程，captureRect=\(resolvedRect)。")

        // Hide the annotation editor & toolbar so they don't appear in captures.
        hideFloatingToolbar()
        orderOut(nil)

        // Defer to the next main-loop turn so AppKit has already hidden the
        // editor before ScreenCaptureKit / HUD setup begins.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            ScrollStitchingCoordinator.shared.start(
                selectedCropRect: resolvedRect,
                presentResultWindow: false
            ) { [weak self] image in
                guard let self else { return }
                if let image {
                    self.debugLog("滚动截图完成，准备用结果图重新打开编辑器，尺寸=\(Int(image.size.width))x\(Int(image.size.height))。")
                    let editor = AnnotationEditorPanel(screenshot: image)
                    editor.onConfirm = self.onConfirm
                    editor.onCancel  = self.onCancel
                    NSApp.activate(ignoringOtherApps: true)
                    editor.orderFrontRegardless()
                    editor.makeKeyAndOrderFront(nil)
                    CaptureSessionController.shared.replaceEditor(editor)
                } else {
                    self.debugLog("滚动截图未生成结果，恢复原编辑器。")
                    NSApp.activate(ignoringOtherApps: true)
                    self.orderFrontRegardless()
                    self.makeKeyAndOrderFront(nil)
                    self.showFloatingToolbar()
                }
            }
        }
    }

    // MARK: OCR

    private func performOCR(translate: Bool) {
        guard !translate else {
            performOCRTranslation()
            return
        }
        guard !state.isOCRRunning else {
            debugLog("OCR 请求被忽略：已有 OCR 任务正在执行。")
            return
        }
        debugLog("开始执行 OCR，translate=\(translate)。")
        let sourceImage = canvas.renderToImage()
        beginOCRLoadingUI()

        OCRRecognitionPipeline.recognize(in: sourceImage) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                let sessionToken = self.ocrSessionToken
                switch result {
                case let .success(snapshot):
                    self.debugLog("OCR 识别成功，识别区域数=\(snapshot.regions.count)，translate=false。")
                    let attributed = OCRStructuredTextComposer.makeAttributedString(
                        from: snapshot.regions,
                        imageSize: snapshot.imageSize,
                        preferredTextWidth: self.preferredOCRTextWidth
                    )
                    self.handleOCRRecognizedText(attributed, sessionToken: sessionToken)
                case let .failure(error):
                    self.debugLog("OCR 识别失败：\(error.localizedDescription)，translate=false。")
                    self.completeOCRAfterMinimumDuration(for: sessionToken) { panel in
                        panel.restoreOCRUIAfterFailure()
                    }
                }
            }
        }
    }

    private func performOCRTranslation() {
#if canImport(Translation)
        if #available(macOS 15.0, *) {
            debugLog("开始执行 OCR 内置翻译。")
            toggleOCRTranslateOverlay()
            return
        }
#endif
        debugLog("OCR 内置翻译不可用：当前系统版本不支持 Apple Translation 框架。")
        if state.selectedTool == .ocrTranslate {
            state.selectedTool = nil
        }
        showAlert(
            title: EditorL10n.tr(.ocrTranslateFailedTitle),
            message: EditorL10n.tr(.ocrTranslateUnavailableMessage)
        )
    }

    private func handleOCRRecognizedText(_ attributedText: NSAttributedString, sessionToken: UUID) {
        let plainText = attributedText.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plainText.isEmpty else {
            debugLog("OCR 识别完成，但未提取到可展示文字。")
            completeOCRAfterMinimumDuration(for: sessionToken) { panel in
                panel.restoreOCRUIAfterFailure { restoredPanel in
                    restoredPanel.showAlert(title: EditorL10n.tr(.ocrEmptyTitle), message: EditorL10n.tr(.ocrEmptyMessage))
                }
            }
            return
        }
        debugLog("OCR 识别完成，准备展示结果，字符数=\(plainText.count)。")
        showOCRResultsUI(with: attributedText)
        completeOCRAfterMinimumDuration(for: sessionToken) { panel in
            panel.finishOCRLoadingUI()
        }
    }

    private func completeOCRAfterMinimumDuration(
        for sessionToken: UUID,
        action: @escaping (AnnotationEditorPanel) -> Void
    ) {
        let remainingDelay = remainingOCRScanDelay
        debugLog("安排 OCR 收尾动作，remainingDelay=\(String(format: "%.3f", remainingDelay)) 秒。")
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.ocrSessionToken == sessionToken else { return }
            self.ocrCompletionWorkItem = nil
            action(self)
        }

        ocrCompletionWorkItem?.cancel()
        ocrCompletionWorkItem = workItem

        if remainingDelay <= 0 {
            workItem.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + remainingDelay, execute: workItem)
        }
    }

    private var remainingOCRScanDelay: TimeInterval {
        guard let ocrLoadingStartTime else { return 0 }
        let elapsed = CACurrentMediaTime() - ocrLoadingStartTime
        return max(0, AnnotationEditorMetrics.ocrMinimumScanDuration - elapsed)
    }

    private func cancelPendingOCRCompletion() {
        debugLog("取消待执行的 OCR 收尾任务。")
        ocrCompletionWorkItem?.cancel()
        ocrCompletionWorkItem = nil
    }

    // MARK: Helpers

    private func writeToPasteboard(_ image: NSImage) {
        debugLog("准备写入图像到剪贴板，尺寸=\(Int(image.size.width))x\(Int(image.size.height))。")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        NSSound.beep()
        debugLog("图像已写入剪贴板，并播放提示音。")
    }

    private static func writableImageTypes() -> [UTType] {
        let ids = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        let preferredIDs = [
            UTType.png.identifier,
            UTType.jpeg.identifier,
            "public.heic",
            UTType.tiff.identifier,
            UTType.gif.identifier,
            UTType.bmp.identifier
        ]
        let preferredTypes = preferredIDs.compactMap { ids.contains($0) ? UTType($0) : nil }
        if !preferredTypes.isEmpty {
            Self.debugLog("已解析可写图片格式：\(preferredTypes.map(Self.displayName(for:)).joined(separator: "、"))。")
            return preferredTypes
        }

        let types = ids.compactMap { UTType($0) }
            .filter { $0.conforms(to: .image) }
            .sorted { lhs, rhs in
            (lhs.localizedDescription ?? lhs.identifier) < (rhs.localizedDescription ?? rhs.identifier)
        }
        let resolvedTypes = types.isEmpty ? [.png] : types
        Self.debugLog("已回退到系统可写图片格式列表：\(resolvedTypes.map(Self.displayName(for:)).joined(separator: "、"))。")
        return resolvedTypes
    }

    fileprivate static func defaultExportFileName(for type: UTType) -> String {
        let timestamp = exportFileNameFormatter.string(from: Date())
        let baseName = "StackShot_\(timestamp)"
        return exportFileName(baseName: baseName, for: type)
    }

    fileprivate static func exportFileName(baseName: String, for type: UTType) -> String {
        let ext = type.preferredFilenameExtension ?? "png"
        return "\(baseName).\(ext)"
    }

    fileprivate static func displayName(for type: UTType) -> String {
        let ext = type.preferredFilenameExtension?.uppercased() ?? type.identifier.uppercased()
        guard let description = type.localizedDescription?.nilIfEmpty else {
            return ext
        }
        return "\(ext) (\(description))"
    }

    private static let exportFileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return formatter
    }()

    private func normalizedExportURL(_ url: URL, for type: UTType) -> URL {
        guard let ext = type.preferredFilenameExtension else {
            return url
        }
        guard url.pathExtension.caseInsensitiveCompare(ext) != .orderedSame else {
            return url
        }
        return url.deletingPathExtension().appendingPathExtension(ext)
    }

    private func writeImage(_ image: NSImage, to url: URL, type: UTType) throws {
        debugLog("开始写入图片，格式=\(Self.displayName(for: type))，路径=\(url.path)，图像尺寸=\(Int(image.size.width))x\(Int(image.size.height))。")
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
        debugLog("系统图片写入已完成。")
    }

    private func showAlert(title: String, message: String) {
        debugLog("准备弹出提示框，标题=\(title)，内容=\(message.replacingOccurrences(of: "\n", with: " "))")
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
    case exportFormatLabel
    case ocrEmptyTitle
    case ocrEmptyMessage
    case ocrDoneTitle
    case ocrDoneMessageFormat
    case ocrTranslatableEmptyMessage
    case ocrTranslateInProgress
    case ocrTranslateProgressDetail
    case ocrTranslateFailedTitle
    case ocrTranslateFailedMessagePrefix
    case ocrTranslateUnavailableMessage
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
    case toolScrollCapture
    case actionAdjustSelection
    case actionUndo
    case actionSave
    case actionPin
    case actionShare
    case actionCancel
    case actionCancelTranslation
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
        if locale == "ja" {
            return ja[key] ?? en[key] ?? ""
        }
        return en[key] ?? ""
    }

    private static let zhHans: [EditorL10nKey: String] = [
        .editorWindowTitle: "编辑截图",
        .saveFailedTitle: "保存失败",
        .saveFailedMessagePrefix: "无法保存图片，请重试。",
        .exportFormatLabel: "格式：",
        .ocrEmptyTitle: "未识别到文字",
        .ocrEmptyMessage: "图片中没有可识别的文字。",
        .ocrDoneTitle: "文字识别完成",
        .ocrDoneMessageFormat: "已识别 %d 个字符并复制到剪贴板。",
        .ocrTranslatableEmptyMessage: "图片中没有可翻译的文字。",
        .ocrTranslateInProgress: "正在翻译…",
        .ocrTranslateProgressDetail: "工具栏已暂时隐藏。正在匹配语言并生成译文，你可以随时点击底部按钮取消。",
        .ocrTranslateFailedTitle: "翻译失败",
        .ocrTranslateFailedMessagePrefix: "无法发起翻译：",
        .ocrTranslateUnavailableMessage: "内置翻译需要 macOS 15 或更高版本，并使用 Apple 官方 Translation 框架。当前系统不支持时，可先使用“识别文字”。",
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
        .toolOCRTranslate: "识别并翻译",
        .toolOCR: "识别文字",
        .toolCrop: "裁剪",
        .toolScrollCapture: "滚动截图",
        .actionAdjustSelection: "调整选区",
        .actionUndo: "撤销",
        .actionSave: "保存",
        .actionPin: "钉图",
        .actionShare: "分享",
        .actionCancel: "取消",
        .actionCancelTranslation: "取消翻译",
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
        .exportFormatLabel: "格式：",
        .ocrEmptyTitle: "未辨識到文字",
        .ocrEmptyMessage: "圖片中沒有可辨識的文字。",
        .ocrDoneTitle: "文字辨識完成",
        .ocrDoneMessageFormat: "已辨識 %d 個字元並複製到剪貼簿。",
        .ocrTranslatableEmptyMessage: "圖片中沒有可翻譯的文字。",
        .ocrTranslateInProgress: "翻譯中…",
        .ocrTranslateProgressDetail: "工具列已暫時隱藏。正在配對語言並產生譯文，你可以隨時點擊底部按鈕取消。",
        .ocrTranslateFailedTitle: "翻譯失敗",
        .ocrTranslateFailedMessagePrefix: "無法啟動翻譯：",
        .ocrTranslateUnavailableMessage: "內建翻譯需要 macOS 15 或以上版本，並使用 Apple 官方 Translation 框架。若目前系統不支援，可先使用「辨識文字」。",
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
        .toolOCRTranslate: "辨識並翻譯",
        .toolOCR: "辨識文字",
        .toolCrop: "裁剪",
        .toolScrollCapture: "捲動截圖",
        .actionAdjustSelection: "調整選區",
        .actionUndo: "復原",
        .actionSave: "儲存",
        .actionPin: "釘圖",
        .actionShare: "分享",
        .actionCancel: "取消",
        .actionCancelTranslation: "取消翻譯",
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
        .exportFormatLabel: "Format:",
        .ocrEmptyTitle: "No Text Detected",
        .ocrEmptyMessage: "No recognizable text was found in the image.",
        .ocrDoneTitle: "Text Recognition Complete",
        .ocrDoneMessageFormat: "Recognized %d characters and copied them to the clipboard.",
        .ocrTranslatableEmptyMessage: "No translatable text was found in the image.",
        .ocrTranslateInProgress: "Translating…",
        .ocrTranslateProgressDetail: "The toolbar is temporarily hidden while StackShot prepares recognition and translation. Use the button below to cancel at any time.",
        .ocrTranslateFailedTitle: "Translation Failed",
        .ocrTranslateFailedMessagePrefix: "Could not start translation: ",
        .ocrTranslateUnavailableMessage: "Built-in translation requires macOS 15 or later and uses Apple's public Translation framework. If it isn't available on this system, use Recognize Text instead.",
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
        .toolOCRTranslate: "Recognize & Translate",
        .toolOCR: "Recognize Text",
        .toolCrop: "Crop",
        .toolScrollCapture: "Scroll Capture",
        .actionAdjustSelection: "Adjust Selection",
        .actionUndo: "Undo",
        .actionSave: "Save",
        .actionPin: "Pin",
        .actionShare: "Share",
        .actionCancel: "Cancel",
        .actionCancelTranslation: "Cancel Translation",
        .actionConfirmCopy: "Confirm & Copy",
        .emojiPickerTitle: "Emoji",
        .textStyleFont: "Font",
        .textStyleSize: "Size",
        .mosaicRadius: "Radius"
    ]

    private static let ja: [EditorL10nKey: String] = [
        .editorWindowTitle: "スクリーンショットを編集",
        .saveFailedTitle: "保存に失敗しました",
        .saveFailedMessagePrefix: "画像を保存できませんでした。もう一度お試しください。",
        .exportFormatLabel: "形式:",
        .ocrEmptyTitle: "テキストが検出されませんでした",
        .ocrEmptyMessage: "画像に認識可能なテキストが見つかりませんでした。",
        .ocrDoneTitle: "テキスト認識完了",
        .ocrDoneMessageFormat: "%d 文字を認識しクリップボードにコピーしました。",
        .ocrTranslatableEmptyMessage: "画像に翻訳可能なテキストが見つかりませんでした。",
        .ocrTranslateInProgress: "翻訳中…",
        .ocrTranslateProgressDetail: "翻訳中はツールバーが一時的に非表示になります。認識と言語変換を準備している間、下のボタンからいつでもキャンセルできます。",
        .ocrTranslateFailedTitle: "翻訳に失敗しました",
        .ocrTranslateFailedMessagePrefix: "翻訳を開始できませんでした：",
        .ocrTranslateUnavailableMessage: "内蔵翻訳は macOS 15 以降で利用でき、Apple の公開 Translation フレームワークを使用します。現在のシステムで利用できない場合は、先に「テキスト認識」を使ってください。",
        .exportReadImageDataFailed: "画像データを読み取れませんでした。",
        .exportUnsupportedType: "このファイル形式はサポートされていません。",
        .exportWriteFailed: "ファイルの書き込みに失敗しました。",
        .okButton: "OK",
        .toolRectangle: "四角形",
        .toolCircle: "円形",
        .toolEmoji: "絵文字と記号",
        .toolArrow: "矢印",
        .toolPen: "ペン",
        .toolMosaic: "モザイク",
        .toolText: "テキスト",
        .toolOCRTranslate: "認識して翻訳",
        .toolOCR: "テキスト認識",
        .toolCrop: "切り取り",
        .toolScrollCapture: "スクロールキャプチャ",
        .actionAdjustSelection: "選択範囲を調整",
        .actionUndo: "元に戻す",
        .actionSave: "保存",
        .actionPin: "ピン留め",
        .actionShare: "共有",
        .actionCancel: "キャンセル",
        .actionCancelTranslation: "翻訳をキャンセル",
        .actionConfirmCopy: "確認してコピー",
        .emojiPickerTitle: "Emoji",
        .textStyleFont: "フォント",
        .textStyleSize: "サイズ",
        .mosaicRadius: "半径"
    ]
}

private final class ExportFormatAccessoryController: NSObject, ConsoleTraceLogging {
    let view: NSView

    private enum Layout {
        static let contentHeight: CGFloat = 32
        static let horizontalInset: CGFloat = 20
        static let labelWidth: CGFloat = 76
        static let fieldSpacing: CGFloat = 12
        static let trailingReservedWidth: CGFloat = 92
        static let minimumPopupWidth: CGFloat = 160
    }

    private weak var panel: NSSavePanel?
    private let writableTypes: [UTType]
    private let fallbackBaseName: String
    private let popupButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let containerWidthConstraint: NSLayoutConstraint
    private let popupWidthConstraint: NSLayoutConstraint

    var selectedType: UTType {
        guard let type = selectedTypeFromPopup else { return writableTypes.first ?? .png }
        return type
    }

    init(panel: NSSavePanel, writableTypes: [UTType], defaultType: UTType, defaultFileName: String) {
        self.panel = panel
        self.writableTypes = writableTypes.isEmpty ? [.png] : writableTypes
        self.fallbackBaseName = Self.baseName(from: defaultFileName).nilIfEmpty ?? "StackShot"

        let contentWidth = max(panel.contentView?.bounds.width ?? 420, 420)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: Layout.contentHeight))
        container.translatesAutoresizingMaskIntoConstraints = false
        self.containerWidthConstraint = container.widthAnchor.constraint(equalToConstant: contentWidth)

        let label = NSTextField(labelWithString: EditorL10n.tr(.exportFormatLabel))
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)

        popupButton.translatesAutoresizingMaskIntoConstraints = false
        popupButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popupButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        for type in self.writableTypes {
            popupButton.addItem(withTitle: Self.displayName(for: type))
            popupButton.lastItem?.representedObject = type.identifier
        }
        if let defaultIndex = self.writableTypes.firstIndex(of: defaultType) {
            popupButton.selectItem(at: defaultIndex)
        } else {
            popupButton.selectItem(at: 0)
        }
        let initialPopupWidth = Self.popupWidth(for: contentWidth)
        self.popupWidthConstraint = popupButton.widthAnchor.constraint(equalToConstant: initialPopupWidth)

        container.addSubview(label)
        container.addSubview(popupButton)
        NSLayoutConstraint.activate([
            containerWidthConstraint,
            container.heightAnchor.constraint(equalToConstant: Layout.contentHeight),

            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.horizontalInset),
            label.widthAnchor.constraint(equalToConstant: Layout.labelWidth),
            label.centerYAnchor.constraint(equalTo: popupButton.centerYAnchor),

            popupButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: Layout.fieldSpacing),
            popupButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            popupWidthConstraint
        ])

        self.view = container

        super.init()

        popupButton.target = self
        popupButton.action = #selector(handleSelectionChange)
        debugLog("已创建保存格式下拉框，默认格式=\(AnnotationEditorPanel.displayName(for: defaultType))，候选格式=\(self.writableTypes.map(AnnotationEditorPanel.displayName(for:)).joined(separator: "、"))。")
        applyInitialLayout()
        syncPanelSelection(usingBaseName: Self.baseName(from: defaultFileName).nilIfEmpty ?? fallbackBaseName)
    }

    @objc
    private func handleSelectionChange() {
        debugLog("用户切换保存格式为 \(AnnotationEditorPanel.displayName(for: selectedType))。")
        syncPanelSelection(usingBaseName: currentBaseName())
    }

    private var selectedTypeFromPopup: UTType? {
        guard
            let identifier = popupButton.selectedItem?.representedObject as? String,
            let type = UTType(identifier)
        else {
            return nil
        }
        return type
    }

    private func currentBaseName() -> String {
        let current = panel?.nameFieldStringValue ?? ""
        return Self.baseName(from: current).nilIfEmpty ?? fallbackBaseName
    }

    private func syncPanelSelection(usingBaseName baseName: String) {
        guard let panel else { return }
        let type = selectedType
        panel.allowedContentTypes = [type]
        if let ext = type.preferredFilenameExtension {
            panel.setValue([ext], forKey: "allowedFileTypes")
        }
        panel.nameFieldStringValue = AnnotationEditorPanel.exportFileName(baseName: baseName, for: type)
        debugLog("已同步保存面板格式，格式=\(AnnotationEditorPanel.displayName(for: type))，文件名=\(panel.nameFieldStringValue)。")
    }

    private static func baseName(from fileName: String) -> String {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return (trimmed as NSString).deletingPathExtension
    }

    private static func displayName(for type: UTType) -> String {
        AnnotationEditorPanel.displayName(for: type)
    }

    private func applyInitialLayout() {
        guard let panel else { return }
        let contentWidth = max(panel.contentView?.bounds.width ?? panel.contentLayoutRect.width, 420)
        let popupWidth = Self.popupWidth(for: contentWidth)
        containerWidthConstraint.constant = contentWidth
        popupWidthConstraint.constant = popupWidth
        debugLog("已锁定保存格式下拉框初始宽度，contentWidth=\(Int(contentWidth))，popupWidth=\(Int(popupWidth))。")
    }

    private static func popupWidth(for contentWidth: CGFloat) -> CGFloat {
        let calculatedWidth = contentWidth
            - Layout.horizontalInset
            - Layout.labelWidth
            - Layout.fieldSpacing
            - Layout.trailingReservedWidth
        return max(Layout.minimumPopupWidth, calculatedWidth)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private final class AnnotationSelectionInteractionOverlayView: NSView {
    private enum DragMode {
        case moving
        case resizing(SelectionEdge)
    }

    private enum SelectionEdge {
        case left
        case right
        case top
        case bottom
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight

        var cursor: NSCursor {
            switch self {
            case .left, .right:
                return .resizeLeftRight
            case .top, .bottom:
                return .resizeUpDown
            case .topLeft, .bottomRight:
                return .crosshair
            case .topRight, .bottomLeft:
                return .crosshair
            }
        }
    }

    var onFrameChange: ((CGRect) -> Void)?
    var isInteractionEnabled = false {
        didSet {
            if !isInteractionEnabled {
                dragMode = nil
                initialMouseLocation = nil
                initialWindowFrame = nil
            }
            isHidden = !isInteractionEnabled
            needsDisplay = true
        }
    }

    private var dragMode: DragMode?
    private var initialMouseLocation: CGPoint?
    private var initialWindowFrame: CGRect?
    private var trackingAreaRef: NSTrackingArea?

    private let edgeHitInset: CGFloat = 8
    private let handleSize: CGFloat = 8
    private let minimumWidth: CGFloat = 80
    private let minimumHeight: CGFloat = 60
    private let snapThreshold: CGFloat = 10

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
        super.updateTrackingAreas()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractionEnabled, !isHidden, alphaValue > 0.01, bounds.contains(point) else { return nil }
        return self
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isInteractionEnabled else { return }

        for handle in handleRects() {
            let path = NSBezierPath(roundedRect: handle, xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            path.fill()
            NSColor.systemBlue.withAlphaComponent(0.95).setStroke()
            path.lineWidth = 1.2
            path.stroke()
        }

        drawSelectionInfoLabel()
    }

    override func mouseMoved(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractionEnabled, let window else {
            super.mouseDown(with: event)
            return
        }

        window.makeFirstResponder(self)
        let localPoint = convert(event.locationInWindow, from: nil)
        if let edge = resizeEdge(at: localPoint) {
            dragMode = .resizing(edge)
        } else {
            dragMode = .moving
        }
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowFrame = window.frame
        updateCursor(at: localPoint)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInteractionEnabled,
              let dragMode,
              let initialMouseLocation,
              let initialWindowFrame else {
            super.mouseDragged(with: event)
            return
        }

        let currentMouseLocation = NSEvent.mouseLocation
        let deltaX = currentMouseLocation.x - initialMouseLocation.x
        let deltaY = currentMouseLocation.y - initialMouseLocation.y

        let updatedFrame: CGRect
        switch dragMode {
        case .moving:
            updatedFrame = moveFrame(initialWindowFrame, deltaX: deltaX, deltaY: deltaY)
        case .resizing(let edge):
            updatedFrame = resizeFrame(initialWindowFrame, edge: edge, deltaX: deltaX, deltaY: deltaY)
        }

        onFrameChange?(updatedFrame)
    }

    override func mouseUp(with event: NSEvent) {
        guard isInteractionEnabled else {
            super.mouseUp(with: event)
            return
        }

        dragMode = nil
        initialMouseLocation = nil
        initialWindowFrame = nil
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func handleRects() -> [CGRect] {
        let half = handleSize / 2
        return [
            CGRect(x: bounds.minX - half, y: bounds.maxY - half, width: handleSize, height: handleSize),
            CGRect(x: bounds.midX - half, y: bounds.maxY - half, width: handleSize, height: handleSize),
            CGRect(x: bounds.maxX - half, y: bounds.maxY - half, width: handleSize, height: handleSize),
            CGRect(x: bounds.minX - half, y: bounds.midY - half, width: handleSize, height: handleSize),
            CGRect(x: bounds.maxX - half, y: bounds.midY - half, width: handleSize, height: handleSize),
            CGRect(x: bounds.minX - half, y: bounds.minY - half, width: handleSize, height: handleSize),
            CGRect(x: bounds.midX - half, y: bounds.minY - half, width: handleSize, height: handleSize),
            CGRect(x: bounds.maxX - half, y: bounds.minY - half, width: handleSize, height: handleSize)
        ]
    }

    private func resizeEdge(at point: CGPoint) -> SelectionEdge? {
        let isNearLeft = abs(point.x - bounds.minX) <= edgeHitInset
        let isNearRight = abs(point.x - bounds.maxX) <= edgeHitInset
        let isNearBottom = abs(point.y - bounds.minY) <= edgeHitInset
        let isNearTop = abs(point.y - bounds.maxY) <= edgeHitInset

        if isNearLeft && isNearTop {
            return .topLeft
        }
        if isNearRight && isNearTop {
            return .topRight
        }
        if isNearLeft && isNearBottom {
            return .bottomLeft
        }
        if isNearRight && isNearBottom {
            return .bottomRight
        }

        var candidates: [(SelectionEdge, CGFloat)] = []

        if point.y >= bounds.minY - edgeHitInset, point.y <= bounds.maxY + edgeHitInset {
            let leftDistance = abs(point.x - bounds.minX)
            if leftDistance <= edgeHitInset {
                candidates.append((.left, leftDistance))
            }

            let rightDistance = abs(point.x - bounds.maxX)
            if rightDistance <= edgeHitInset {
                candidates.append((.right, rightDistance))
            }
        }

        if point.x >= bounds.minX - edgeHitInset, point.x <= bounds.maxX + edgeHitInset {
            let bottomDistance = abs(point.y - bounds.minY)
            if bottomDistance <= edgeHitInset {
                candidates.append((.bottom, bottomDistance))
            }

            let topDistance = abs(point.y - bounds.maxY)
            if topDistance <= edgeHitInset {
                candidates.append((.top, topDistance))
            }
        }

        return candidates.min(by: { $0.1 < $1.1 })?.0
    }

    private func moveFrame(_ frame: CGRect, deltaX: CGFloat, deltaY: CGFloat) -> CGRect {
        var moved = frame.offsetBy(dx: deltaX, dy: deltaY)
        let desktopBounds = NSScreen.screens.reduce(CGRect.null) { partial, screen in
            partial.union(screen.frame)
        }

        if moved.minX < desktopBounds.minX {
            moved.origin.x = desktopBounds.minX
        }
        if moved.maxX > desktopBounds.maxX {
            moved.origin.x = desktopBounds.maxX - moved.width
        }
        if moved.minY < desktopBounds.minY {
            moved.origin.y = desktopBounds.minY
        }
        if moved.maxY > desktopBounds.maxY {
            moved.origin.y = desktopBounds.maxY - moved.height
        }

        return snappedMovedFrame(moved, within: desktopBounds)
    }

    private func resizeFrame(_ frame: CGRect, edge: SelectionEdge, deltaX: CGFloat, deltaY: CGFloat) -> CGRect {
        let desktopBounds = NSScreen.screens.reduce(CGRect.null) { partial, screen in
            partial.union(screen.frame)
        }
        var resized = frame

        switch edge {
        case .left:
            let proposedMinX = min(max(frame.minX + deltaX, desktopBounds.minX), frame.maxX - minimumWidth)
            let snappedMinX = snapCoordinate(proposedMinX, target: desktopBounds.minX)
            resized.origin.x = snappedMinX
            resized.size.width = frame.maxX - snappedMinX
        case .right:
            let proposedMaxX = max(min(frame.maxX + deltaX, desktopBounds.maxX), frame.minX + minimumWidth)
            let snappedMaxX = snapCoordinate(proposedMaxX, target: desktopBounds.maxX)
            resized.size.width = snappedMaxX - frame.minX
        case .bottom:
            let proposedMinY = min(max(frame.minY + deltaY, desktopBounds.minY), frame.maxY - minimumHeight)
            let snappedMinY = snapCoordinate(proposedMinY, target: desktopBounds.minY)
            resized.origin.y = snappedMinY
            resized.size.height = frame.maxY - snappedMinY
        case .top:
            let proposedMaxY = max(min(frame.maxY + deltaY, desktopBounds.maxY), frame.minY + minimumHeight)
            let snappedMaxY = snapCoordinate(proposedMaxY, target: desktopBounds.maxY)
            resized.size.height = snappedMaxY - frame.minY
        case .topLeft:
            let proposedMinX = min(max(frame.minX + deltaX, desktopBounds.minX), frame.maxX - minimumWidth)
            let proposedMaxY = max(min(frame.maxY + deltaY, desktopBounds.maxY), frame.minY + minimumHeight)
            let snappedMinX = snapCoordinate(proposedMinX, target: desktopBounds.minX)
            let snappedMaxY = snapCoordinate(proposedMaxY, target: desktopBounds.maxY)
            resized.origin.x = snappedMinX
            resized.size.width = frame.maxX - snappedMinX
            resized.size.height = snappedMaxY - frame.minY
        case .topRight:
            let proposedMaxX = max(min(frame.maxX + deltaX, desktopBounds.maxX), frame.minX + minimumWidth)
            let proposedMaxY = max(min(frame.maxY + deltaY, desktopBounds.maxY), frame.minY + minimumHeight)
            let snappedMaxX = snapCoordinate(proposedMaxX, target: desktopBounds.maxX)
            let snappedMaxY = snapCoordinate(proposedMaxY, target: desktopBounds.maxY)
            resized.size.width = snappedMaxX - frame.minX
            resized.size.height = snappedMaxY - frame.minY
        case .bottomLeft:
            let proposedMinX = min(max(frame.minX + deltaX, desktopBounds.minX), frame.maxX - minimumWidth)
            let proposedMinY = min(max(frame.minY + deltaY, desktopBounds.minY), frame.maxY - minimumHeight)
            let snappedMinX = snapCoordinate(proposedMinX, target: desktopBounds.minX)
            let snappedMinY = snapCoordinate(proposedMinY, target: desktopBounds.minY)
            resized.origin.x = snappedMinX
            resized.size.width = frame.maxX - snappedMinX
            resized.origin.y = snappedMinY
            resized.size.height = frame.maxY - snappedMinY
        case .bottomRight:
            let proposedMaxX = max(min(frame.maxX + deltaX, desktopBounds.maxX), frame.minX + minimumWidth)
            let proposedMinY = min(max(frame.minY + deltaY, desktopBounds.minY), frame.maxY - minimumHeight)
            let snappedMaxX = snapCoordinate(proposedMaxX, target: desktopBounds.maxX)
            let snappedMinY = snapCoordinate(proposedMinY, target: desktopBounds.minY)
            resized.size.width = snappedMaxX - frame.minX
            resized.origin.y = snappedMinY
            resized.size.height = frame.maxY - snappedMinY
        }

        return resized
    }

    private func snappedMovedFrame(_ frame: CGRect, within desktopBounds: CGRect) -> CGRect {
        var snapped = frame

        if abs(snapped.minX - desktopBounds.minX) <= snapThreshold {
            snapped.origin.x = desktopBounds.minX
        } else if abs(snapped.maxX - desktopBounds.maxX) <= snapThreshold {
            snapped.origin.x = desktopBounds.maxX - snapped.width
        }

        if abs(snapped.minY - desktopBounds.minY) <= snapThreshold {
            snapped.origin.y = desktopBounds.minY
        } else if abs(snapped.maxY - desktopBounds.maxY) <= snapThreshold {
            snapped.origin.y = desktopBounds.maxY - snapped.height
        }

        return snapped
    }

    private func snapCoordinate(_ value: CGFloat, target: CGFloat) -> CGFloat {
        abs(value - target) <= snapThreshold ? target : value
    }

    private func drawSelectionInfoLabel() {
        let text = "\(Int(bounds.width.rounded())) × \(Int(bounds.height.rounded()))"
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let hPad: CGFloat = 10
        let vPad: CGFloat = 5
        let labelRect = CGRect(
            x: 10,
            y: max(10, bounds.maxY - textSize.height - vPad * 2 - 10),
            width: textSize.width + hPad * 2,
            height: textSize.height + vPad * 2
        )

        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(
            at: CGPoint(x: labelRect.minX + hPad, y: labelRect.minY + vPad),
            withAttributes: attributes
        )
    }

    private func updateCursor(at point: CGPoint) {
        if case .moving = dragMode {
            NSCursor.closedHand.set()
            return
        }

        if case let .resizing(edge) = dragMode {
            edge.cursor.set()
            return
        }

        if let edge = resizeEdge(at: point) {
            edge.cursor.set()
            return
        }

        NSCursor.openHand.set()
    }
}

private final class AnnotationEditingBackdropPanel: NSPanel {
    private let backdropView: AnnotationEditingBackdropView

    var onSelectionFrameChange: ((CGRect) -> Void)? {
        get { backdropView.onSelectionFrameChange }
        set { backdropView.onSelectionFrameChange = newValue }
    }

    var onCancelRequested: (() -> Void)? {
        get { backdropView.onCancelRequested }
        set { backdropView.onCancelRequested = newValue }
    }

    var onConfirmRequested: (() -> Void)? {
        get { backdropView.onConfirmRequested }
        set { backdropView.onConfirmRequested = newValue }
    }

    var allowsSelectionCreation: Bool {
        get { backdropView.allowsSelectionCreation }
        set { backdropView.allowsSelectionCreation = newValue }
    }

    init(level: NSWindow.Level) {
        let union = NSScreen.screens.reduce(CGRect.null) { partial, screen in
            partial.union(screen.frame)
        }
        backdropView = AnnotationEditingBackdropView(
            frame: CGRect(origin: .zero, size: union.size),
            windowOrigin: union.origin
        )

        super.init(
            contentRect: union,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        self.level = level
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        hasShadow = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        worksWhenModal = true
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        contentView = backdropView
    }

    func setSelectionFrame(_ frame: CGRect) {
        backdropView.selectionFrame = frame.offsetBy(dx: -self.frame.origin.x, dy: -self.frame.origin.y)
    }
}

private final class AnnotationEditingBackdropView: NSView {
    var onSelectionFrameChange: ((CGRect) -> Void)?
    var onCancelRequested: (() -> Void)?
    var onConfirmRequested: (() -> Void)?
    var allowsSelectionCreation = false
    var selectionFrame: CGRect = .zero {
        didSet { needsDisplay = true }
    }

    private let windowOrigin: CGPoint
    private var dragStartPoint: CGPoint?
    private var draftSelectionRect: CGRect?
    private var trackingAreaRef: NSTrackingArea?
    private let snapThreshold: CGFloat = 10

    init(frame frameRect: NSRect, windowOrigin: CGPoint) {
        self.windowOrigin = windowOrigin
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
        super.updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.42).setFill()
        bounds.fill()

        if let guideRect = activeGuideRect() {
            drawSnapGuides(for: guideRect)
        }

        if let draftSelectionRect {
            let border = NSBezierPath(rect: draftSelectionRect)
            border.lineWidth = 2
            NSColor.systemBlue.withAlphaComponent(0.92).setStroke()
            border.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if !allowsSelectionCreation {
            if event.clickCount >= 2 {
                onConfirmRequested?()
            }
            updateCursor(at: convert(event.locationInWindow, from: nil))
            return
        }

        dragStartPoint = convert(event.locationInWindow, from: nil)
        draftSelectionRect = nil
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard allowsSelectionCreation, let dragStartPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        let rect = snappedSelectionRect(from: dragStartPoint, to: point)
        draftSelectionRect = rect
        needsDisplay = true

        guard rect.width >= 2, rect.height >= 2 else { return }
        onSelectionFrameChange?(rect.offsetBy(dx: windowOrigin.x, dy: windowOrigin.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard allowsSelectionCreation else { return }
        if let dragStartPoint {
            let point = convert(event.locationInWindow, from: nil)
            let rect = snappedSelectionRect(from: dragStartPoint, to: point)
            if rect.width >= 2, rect.height >= 2 {
                onSelectionFrameChange?(rect.offsetBy(dx: windowOrigin.x, dy: windowOrigin.y))
            }
        }
        dragStartPoint = nil
        draftSelectionRect = nil
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancelRequested?()
    }

    private func updateCursor(at point: CGPoint) {
        guard bounds.contains(point) else { return }
        if allowsSelectionCreation {
            NSCursor.crosshair.set()
            return
        }
        Self.disabledToolCursor.set()
    }

    private static let disabledToolCursor: NSCursor = {
        let baseCursor = NSCursor.arrow
        let canvasSize = NSSize(
            width: max(24, baseCursor.image.size.width + 8),
            height: max(24, baseCursor.image.size.height + 8)
        )
        let image = NSImage(size: canvasSize)

        image.lockFocus()
        baseCursor.image.draw(
            in: CGRect(origin: .zero, size: baseCursor.image.size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )

        let badgeRect = CGRect(x: round(baseCursor.image.size.width / 2), y: 2, width: 12, height: 12)
        let badge = NSBezierPath(ovalIn: badgeRect)
        NSColor.systemRed.setFill()
        badge.fill()
        NSColor.white.setStroke()
        badge.lineWidth = 1.2
        badge.stroke()

        let slash = NSBezierPath()
        slash.move(to: CGPoint(x: badgeRect.minX + 2.4, y: badgeRect.minY + 2.3))
        slash.line(to: CGPoint(x: badgeRect.maxX - 2.3, y: badgeRect.maxY - 2.4))
        slash.lineWidth = 1.5
        slash.lineCapStyle = .round
        NSColor.white.setStroke()
        slash.stroke()
        image.unlockFocus()

        return NSCursor(image: image, hotSpot: baseCursor.hotSpot)
    }()

    private func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    private func snappedSelectionRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        var rect = normalizedRect(from: a, to: b)
        if abs(rect.minX - bounds.minX) <= snapThreshold {
            rect.origin.x = bounds.minX
        }
        if abs(rect.maxX - bounds.maxX) <= snapThreshold {
            rect.size.width = bounds.maxX - rect.minX
        }
        if abs(rect.minY - bounds.minY) <= snapThreshold {
            rect.origin.y = bounds.minY
        }
        if abs(rect.maxY - bounds.maxY) <= snapThreshold {
            rect.size.height = bounds.maxY - rect.minY
        }
        return rect
    }

    private func activeGuideRect() -> CGRect? {
        let candidate = draftSelectionRect ?? selectionFrame
        guard candidate.width > 1, candidate.height > 1 else { return nil }
        return candidate
    }

    private func drawSnapGuides(for rect: CGRect) {
        NSColor.systemBlue.withAlphaComponent(0.78).setStroke()

        if abs(rect.minX - bounds.minX) <= 0.5 {
            drawGuideLine(from: CGPoint(x: rect.minX, y: bounds.minY), to: CGPoint(x: rect.minX, y: bounds.maxY))
        }
        if abs(rect.maxX - bounds.maxX) <= 0.5 {
            drawGuideLine(from: CGPoint(x: rect.maxX, y: bounds.minY), to: CGPoint(x: rect.maxX, y: bounds.maxY))
        }
        if abs(rect.minY - bounds.minY) <= 0.5 {
            drawGuideLine(from: CGPoint(x: bounds.minX, y: rect.minY), to: CGPoint(x: bounds.maxX, y: rect.minY))
        }
        if abs(rect.maxY - bounds.maxY) <= 0.5 {
            drawGuideLine(from: CGPoint(x: bounds.minX, y: rect.maxY), to: CGPoint(x: bounds.maxX, y: rect.maxY))
        }
    }

    private func drawGuideLine(from start: CGPoint, to end: CGPoint) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = 1.6
        let dash: [CGFloat] = [6, 4]
        path.setLineDash(dash, count: dash.count, phase: 0)
        path.stroke()
    }
}

// MARK: – Pin window store (keeps floating screenshots alive)

final class PinWindowStore {
    static let shared = PinWindowStore()
    fileprivate static let basePinnedWindowLevel = NSWindow.Level.screenSaver.rawValue + 24
    fileprivate static let levelStride = 2

    private struct Entry {
        let panel: PinnedImagePanel
        let activationOrder: Int
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var nextActivationOrder = 0

    func pin(_ image: NSImage) {
        let panel = PinnedImagePanel(image: image)
        activate(panel)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    fileprivate func activate(_ panel: PinnedImagePanel) {
        nextActivationOrder += 1
        entries[ObjectIdentifier(panel)] = Entry(panel: panel, activationOrder: nextActivationOrder)
        refreshPinnedWindowLevels()
    }

    fileprivate func deactivate(_ panel: PinnedImagePanel) {
        entries.removeValue(forKey: ObjectIdentifier(panel))
        panel.applyUnpinnedWindowLevel()
        refreshPinnedWindowLevels()
    }

    fileprivate func remove(_ panel: PinnedImagePanel) {
        entries.removeValue(forKey: ObjectIdentifier(panel))
        refreshPinnedWindowLevels()
    }

    private func refreshPinnedWindowLevels() {
        let sortedPanels = entries.values
            .map { ($0.panel, $0.activationOrder) }
            .sorted { $0.1 < $1.1 }

        for (index, item) in sortedPanels.enumerated() {
            item.0.applyPinnedWindowOrder(index)
        }
    }
}

private final class PinnedImagePanel: NSPanel {
    private let pinStatusView = PinStatusTitlebarView()
    private let imageView = NSImageView()
    private var isPinnedToFront = true
    private var pinnedWindowOrder: Int?
    private var pinStatusConstraints: [NSLayoutConstraint] = []

    init(image: NSImage) {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let maxW = screen.width * 0.6
        let maxH = screen.height * 0.6
        let scale = min(1, maxW / image.size.width, maxH / image.size.height)
        let displaySize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let frame = CGRect(
            x: screen.midX - displaySize.width / 2,
            y: screen.midY - displaySize.height / 2,
            width: displaySize.width,
            height: displaySize.height
        )

        super.init(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        title = "StackShot"
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        hasShadow = true
        isMovableByWindowBackground = false
        minSize = NSSize(width: 180, height: 120)

        imageView.frame = CGRect(origin: .zero, size: displaySize)
        imageView.autoresizingMask = [.width, .height]
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        contentView = imageView

        setupPinStatusControl()
        installPinStatusViewIfNeeded()
        applyPinnedAppearance()
    }

    override func close() {
        PinWindowStore.shared.remove(self)
        super.close()
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        DispatchQueue.main.async { [weak self] in
            self?.installPinStatusViewIfNeeded()
            self?.applyPinnedAppearance()
        }
    }

    @objc
    private func togglePinnedFromTitlebar(_ sender: Any?) {
        setPinnedToFront(!isPinnedToFront)
    }

    private func setupPinStatusControl() {
        pinStatusView.button.target = self
        pinStatusView.button.action = #selector(togglePinnedFromTitlebar(_:))
        pinStatusView.update(isPinned: true, tooltip: EditorL10n.tr(.actionPin))
    }

    private func installPinStatusViewIfNeeded() {
        guard let titlebarView = standardWindowButton(.closeButton)?.superview else { return }
        guard pinStatusView.superview !== titlebarView else { return }

        pinStatusView.removeFromSuperview()
        titlebarView.addSubview(pinStatusView)

        NSLayoutConstraint.deactivate(pinStatusConstraints)
        pinStatusConstraints.removeAll()

        let centerAnchor = standardWindowButton(.closeButton)?.centerYAnchor ?? titlebarView.centerYAnchor
        pinStatusConstraints = [
            pinStatusView.trailingAnchor.constraint(equalTo: titlebarView.trailingAnchor, constant: -14),
            pinStatusView.centerYAnchor.constraint(equalTo: centerAnchor),
        ]
        NSLayoutConstraint.activate(pinStatusConstraints)
    }

    private func setPinnedToFront(_ pinned: Bool) {
        guard isPinnedToFront != pinned else { return }
        isPinnedToFront = pinned

        if pinned {
            applyPinnedAppearance()
            PinWindowStore.shared.activate(self)
            orderFrontRegardless()
        } else {
            PinWindowStore.shared.deactivate(self)
            applyUnpinnedWindowLevel()
        }
    }

    private func applyPinnedAppearance() {
        pinStatusView.update(isPinned: true, tooltip: EditorL10n.tr(.actionPin))
    }

    fileprivate func applyPinnedWindowOrder(_ order: Int) {
        isPinnedToFront = true
        pinnedWindowOrder = order
        level = NSWindow.Level(rawValue: PinWindowStore.basePinnedWindowLevel + order * PinWindowStore.levelStride)
        pinStatusView.update(isPinned: true, tooltip: EditorL10n.tr(.actionPin))
    }

    fileprivate func applyUnpinnedWindowLevel() {
        isPinnedToFront = false
        pinnedWindowOrder = nil
        level = .normal
        pinStatusView.update(isPinned: false, tooltip: EditorL10n.tr(.actionPin))
    }
}

private final class PinStatusTitlebarView: NSView {
    let button = NSButton()

    private static let fallbackPinnedTint = NSColor(
        srgbRed: CGFloat(0x6D) / 255.0,
        green: CGFloat(0xC6) / 255.0,
        blue: CGFloat(0x6C) / 255.0,
        alpha: 1
    )

    override var intrinsicContentSize: NSSize {
        NSSize(width: 34, height: 28)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.focusRingType = .none

        addSubview(button)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 34),
            heightAnchor.constraint(equalToConstant: 28),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(isPinned: Bool, tooltip: String) {
        let pinnedTint = preferredPinnedTintColor()
        let symbolName = isPinned ? "pin.fill" : "pin"
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: isPinned ? .bold : .medium)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(configuration)
        button.contentTintColor = isPinned ? pinnedTint : NSColor.secondaryLabelColor
        button.toolTip = tooltip

        let fillColor = NSColor.clear
        let strokeColor = isPinned
            ? NSColor.clear
            : NSColor.clear
        layer?.backgroundColor = fillColor.cgColor
        layer?.borderColor = strokeColor.cgColor
        layer?.shadowColor = nil
        layer?.shadowOpacity = 0
        layer?.shadowRadius = 0
        layer?.shadowOffset = .zero
    }

    private func preferredPinnedTintColor() -> NSColor {
        guard
            let zoomButton = window?.standardWindowButton(.zoomButton),
            let sampledColor = sampleCenterColor(from: zoomButton),
            sampledColor.alphaComponent > 0.2,
            sampledColor.greenComponent > sampledColor.redComponent,
            sampledColor.greenComponent > sampledColor.blueComponent
        else {
            return Self.fallbackPinnedTint
        }
        return sampledColor
    }

    private func sampleCenterColor(from view: NSView) -> NSColor? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)

        let sampleX = max(0, min(rep.pixelsWide - 1, rep.pixelsWide / 2))
        let sampleY = max(0, min(rep.pixelsHigh - 1, rep.pixelsHigh / 2))
        return rep.colorAt(x: sampleX, y: sampleY)?.usingColorSpace(.deviceRGB)?.withAlphaComponent(1)
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

    init(editorFrame: CGRect, toolbarView: AnnotationToolbarView, windowLevel: NSWindow.Level) {
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
        level = windowLevel
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
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
        let left = leftFrame(editorFrame: editorFrame, visible: visible)

        if preferBelow {
            if let below { return ToolbarLayout(frame: below, dock: .belowEditor) }
            if let right { return ToolbarLayout(frame: right, dock: .rightOfEditor) }
            if let left { return ToolbarLayout(frame: left, dock: .leftOfEditor) }
        } else {
            if let right { return ToolbarLayout(frame: right, dock: .rightOfEditor) }
            if let left { return ToolbarLayout(frame: left, dock: .leftOfEditor) }
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

    private static func leftFrame(editorFrame: CGRect, visible: CGRect) -> CGRect? {
        let base = AnnotationEditorMetrics.toolbarRightSize
        let width = min(base.width, editorFrame.width, visible.width - margin * 2)
        let height = min(base.height, editorFrame.height, visible.height - margin * 2)
        guard width >= base.width * 0.95, height >= base.height * 0.82 else { return nil }

        let x = editorFrame.minX - AnnotationEditorMetrics.toolbarGapToEditor - width
        guard x >= visible.minX + margin else { return nil }

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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
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
    let dock: ToolbarDockPosition

    func makeCoordinator() -> Coordinator {
        Coordinator(tool: tool, state: state, systemName: systemName, dock: dock)
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
        context.coordinator.dock = dock
        context.coordinator.button?.toolTip = help
        context.coordinator.refreshSymbol()
        context.coordinator.updateAppearance(selected: state.selectedTool == tool)
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        let tool: AnnotationTool
        var state: AnnotationEditorState
        let systemName: String
        var dock: ToolbarDockPosition
        var help: String = ""

        weak var container: NSView?
        weak var button: NSButton?
        var popover: NSPopover?

        init(tool: AnnotationTool, state: AnnotationEditorState, systemName: String, dock: ToolbarDockPosition) {
            self.tool = tool
            self.state = state
            self.systemName = systemName
            self.dock = dock
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
            pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: dock.popoverPreferredEdge)

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
    let dock: ToolbarDockPosition
    let help: String
    let onClick: (NSView, ToolbarDockPosition) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, dock: dock, onClick: onClick)
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
        context.coordinator.dock = dock
        context.coordinator.updateAppearance(selected: state.selectedTool == .emoji)
        context.coordinator.button?.toolTip = help
    }

    final class Coordinator: NSObject {
        var state: AnnotationEditorState
        var dock: ToolbarDockPosition
        let onClick: (NSView, ToolbarDockPosition) -> Void
        weak var container: NSView?
        weak var button: NSButton?

        init(state: AnnotationEditorState, dock: ToolbarDockPosition, onClick: @escaping (NSView, ToolbarDockPosition) -> Void) {
            self.state = state
            self.dock = dock
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
            onClick(sender, dock)
        }
    }
}

private struct ToolbarActionButton: NSViewRepresentable {
    enum Glyph {
        case symbol(String)
        /// Custom template image already sized for SF-Symbol-equivalent
        /// rendering (~16pt point size, medium weight).
        case custom(NSImage)
    }

    let glyph: Glyph
    let help: String
    let tintColor: NSColor?
    let backgroundColor: NSColor?
    let onClick: () -> Void

    init(systemName: String,
         help: String,
         tintColor: NSColor? = nil,
         backgroundColor: NSColor? = nil,
         onClick: @escaping () -> Void) {
        self.glyph = .symbol(systemName)
        self.help = help
        self.tintColor = tintColor
        self.backgroundColor = backgroundColor
        self.onClick = onClick
    }

    init(customImage: NSImage,
         help: String,
         tintColor: NSColor? = nil,
         backgroundColor: NSColor? = nil,
         onClick: @escaping () -> Void) {
        self.glyph = .custom(customImage)
        self.help = help
        self.tintColor = tintColor
        self.backgroundColor = backgroundColor
        self.onClick = onClick
    }

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
            glyph: glyph,
            help: help,
            tintColor: tintColor,
            backgroundColor: backgroundColor
        )

        container.addSubview(button)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            glyph: glyph,
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
            glyph: Glyph,
            help: String,
            tintColor: NSColor?,
            backgroundColor: NSColor?
        ) {
            guard let container, let button else { return }
            switch glyph {
            case .symbol(let name):
                let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
                button.image = NSImage(systemSymbolName: name, accessibilityDescription: help)?
                    .withSymbolConfiguration(config)
            case .custom(let image):
                // Template rendering lets `contentTintColor` recolor it
                // exactly the way SF Symbols are recolored.
                image.isTemplate = true
                button.image = image
            }
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

/// Factory for custom toolbar glyphs drawn at SF-Symbol-equivalent
/// dimensions so they slot into the toolbar with identical visual
/// weight to the system symbols.
enum ToolbarGlyphImage {
    // (no entries currently — `ScrollCaptureGlyph` lives as a SwiftUI
    // view in FloatingToolbarPanel.swift so it can share the OCR
    // glyph's stroke recipe.)
}

// MARK: – SwiftUI Annotation Toolbar

/// Small green checkmark badge overlaid on the OCR-translate button to
/// indicate that the canvas currently shows the translated overlay
/// (rather than the original screenshot).
private struct OCRTranslationAppliedBadge: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.green)
            Circle()
                .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.2)
            Image(systemName: "checkmark")
                .font(.system(size: 7, weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(width: 12, height: 12)
        .shadow(color: Color.black.opacity(0.18), radius: 1.5, x: 0, y: 0.5)
        .accessibilityHidden(true)
    }
}

private struct AnnotationToolbarView: View {
    @ObservedObject var state: AnnotationEditorState
    var dock: ToolbarDockPosition = .belowEditor
    var onAdjustSelection: () -> Void
    var onUndo:         () -> Void
    var onSave:         () -> Void
    var onPin:          () -> Void
    var onShare:        () -> Void
    var onCancel:       () -> Void
    var onConfirm:      () -> Void
    var onEmoji:        (NSView, ToolbarDockPosition) -> Void
    var onOCR:          () -> Void
    var onOCRTranslate: () -> Void
    var onScrollCapture:(CGRect) -> Void

    private let configurableTools: Set<AnnotationTool> = [.rectangle, .circle, .arrow, .pen, .mosaic, .text]
    private enum ToolbarToken: String {
        case adjustSelection
        case rectangle, circle, emoji, arrow, pen, mosaic, text, ocrTranslate, ocr, scrollCapture, crop
        case undo, save, pin, share
        case cancel, confirm
    }

    private var orderedTokens: [ToolbarToken] {
        var tokens: [ToolbarToken] = [
            .rectangle, .circle, .emoji, .arrow, .pen, .mosaic, .text
        ]
        if AnnotationEditorFeatureAvailability.supportsOCRTranslationUI {
            tokens.append(.ocrTranslate)
        }
        tokens.append(contentsOf: [
            .ocr, .scrollCapture, .crop, .undo, .save, .pin, .share, .cancel, .confirm
        ])
        return tokens
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
        case .adjustSelection:
            adjustSelectionButton
        case .rectangle:
            drawTool(.rectangle, "square", EditorL10n.tr(.toolRectangle))
        case .circle:
            drawTool(.circle, "circle", EditorL10n.tr(.toolCircle))
        case .emoji:
            EmojiToolbarButton(state: state, dock: dock, help: EditorL10n.tr(.toolEmoji), onClick: onEmoji)
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
            ocrToolButton(EditorL10n.tr(.toolOCR))
        case .crop:
            drawTool(.crop, "crop", EditorL10n.tr(.toolCrop))
        case .scrollCapture:
            scrollCaptureButton
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

    private var adjustSelectionButton: some View {
        Button(action: onAdjustSelection) {
            Image(systemName: "viewfinder")
                .font(.system(size: 16, weight: .medium))
                .frame(width: AnnotationEditorMetrics.toolbarButtonSize,
                       height: AnnotationEditorMetrics.toolbarButtonSize)
        }
        .buttonStyle(.plain)
        .background(
            state.isSelectionAdjustmentMode ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .help(EditorL10n.tr(.actionAdjustSelection))
    }

    @ViewBuilder
    private func drawTool(_ tool: AnnotationTool, _ icon: String, _ tip: String) -> some View {
        let supportsStyle = configurableTools.contains(tool)

        if supportsStyle {
            ConfigurableToolToolbarButton(state: state, tool: tool, systemName: icon, help: tip, dock: dock)
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
    private func ocrToolButton(_ tip: String) -> some View {
        let isRunning = state.isOCRRunning

        Button {
            guard !isRunning else { return }
            state.selectedTool = .ocr
            onOCR()
        } label: {
            Group {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    OCRToolbarGlyph()
                        .frame(width: 18, height: 18)
                }
            }
            .frame(width: AnnotationEditorMetrics.toolbarButtonSize,
                   height: AnnotationEditorMetrics.toolbarButtonSize)
        }
        .buttonStyle(.plain)
        .background(
            (state.selectedTool == .ocr || isRunning) ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .disabled(isRunning)
        .help(tip)
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

    /// Custom scroll-capture button: rounded portrait rectangle (with
    /// dashed vertical sides) wrapping a vertical double-headed arrow.
    /// Stroke width matches the OCR glyph (`size * 0.09`) and the
    /// inner glyph is rendered at 18×18 like OCR for visual parity.
    private var scrollCaptureButton: some View {
        let selectedCropRect = state.selectedCropRect
        return Button {
            onScrollCapture(selectedCropRect)
        } label: {
            ScrollCaptureGlyph()
                .frame(width: 18, height: 18)
                .frame(width: AnnotationEditorMetrics.toolbarButtonSize,
                       height: AnnotationEditorMetrics.toolbarButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            Color.primary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .help(EditorL10n.tr(.toolScrollCapture))
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

// MARK: – OCR Translate overlay pipeline (macOS 15+)

/// A single recognized text region mapped from Vision observations to image pixels.
struct OCRTextRegion {
    /// Bounding box in image pixel coordinates with origin top-left.
    var imageRect: CGRect
    var original: String
    var translated: String?
    /// Sampled text/stroke color.
    var foreground: NSColor
    /// Sampled background color used to mask the original text.
    var background: NSColor
}

private struct OCRRecognitionSnapshot {
    var imageSize: CGSize
    var regions: [OCRTextRegion]
}

private enum OCRRecognitionPipeline {
    private static let recognitionLanguages = [
        "zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "ru-RU"
    ]

    static func recognize(in image: NSImage, completion: @escaping (Result<OCRRecognitionSnapshot, Error>) -> Void) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            completion(.success(OCRRecognitionSnapshot(imageSize: image.size, regions: [])))
            return
        }

        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let sampler = PixelSampler(cgImage: cgImage)
        let request = VNRecognizeTextRequest { request, error in
            if let error {
                completion(.failure(error))
                return
            }

            let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
            let regions = observations.compactMap { observation -> OCRTextRegion? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let text = candidate.string
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

                let bb = observation.boundingBox
                let rect = CGRect(
                    x: bb.origin.x * imageSize.width,
                    y: (1 - bb.origin.y - bb.height) * imageSize.height,
                    width: bb.width * imageSize.width,
                    height: bb.height * imageSize.height
                ).integral
                let colors = sampler?.classifyColors(in: rect) ?? (fg: .labelColor, bg: .windowBackgroundColor)
                return OCRTextRegion(
                    imageRect: rect,
                    original: text,
                    translated: nil,
                    foreground: colors.fg,
                    background: colors.bg
                )
            }

            completion(.success(OCRRecognitionSnapshot(imageSize: imageSize, regions: regions)))
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = recognitionLanguages

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                completion(.failure(error))
            }
        }
    }
}

private enum OCRStructuredTextComposer {
    private struct Line {
        var regions: [OCRTextRegion]

        var rect: CGRect {
            guard let first = regions.first else { return .zero }
            return regions.dropFirst().reduce(first.imageRect) { partial, region in
                partial.union(region.imageRect)
            }
        }

        var medianHeight: CGFloat {
            OCRStructuredTextComposer.median(for: regions.map { max(1, $0.imageRect.height) })
        }
    }

    static func makeAttributedString(from regions: [OCRTextRegion], imageSize: CGSize, preferredTextWidth: CGFloat) -> NSAttributedString {
        let trimmedRegions = regions.filter { !$0.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !trimmedRegions.isEmpty else { return NSAttributedString() }

        let lines = clusterLines(from: trimmedRegions)
        let globalMedianHeight = median(for: trimmedRegions.map { max(1, $0.imageRect.height) })
        let output = NSMutableAttributedString()

        for lineIndex in lines.indices {
            let line = lines[lineIndex]
            let pointSize = fittedPointSize(for: line, globalMedianHeight: globalMedianHeight, preferredTextWidth: preferredTextWidth)
            let weight = fontWeight(for: line, globalMedianHeight: globalMedianHeight)
            let paragraphStyle = makeParagraphStyle(for: line, imageSize: imageSize, pointSize: pointSize)
            let font = NSFont.systemFont(ofSize: pointSize, weight: weight)
            let sortedRegions = line.regions.sorted { $0.imageRect.minX < $1.imageRect.minX }

            for regionIndex in sortedRegions.indices {
                if regionIndex > 0 {
                    let gapString = spacer(
                        between: sortedRegions[regionIndex - 1],
                        and: sortedRegions[regionIndex],
                        medianHeight: globalMedianHeight
                    )
                    if !gapString.isEmpty {
                        output.append(
                            NSAttributedString(
                                string: gapString,
                                attributes: [
                                    .font: font,
                                    .paragraphStyle: paragraphStyle,
                                    .foregroundColor: NSColor.clear
                                ]
                            )
                        )
                    }
                }

                let region = sortedRegions[regionIndex]

                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .paragraphStyle: paragraphStyle,
                    .foregroundColor: foregroundColor(for: region)
                ]
                if let backgroundColor = backgroundHighlightColor(for: region) {
                    attributes[.backgroundColor] = backgroundColor
                }
                output.append(NSAttributedString(string: region.original, attributes: attributes))
            }

            if lineIndex < lines.count - 1 {
                output.append(
                    NSAttributedString(
                        string: lineSeparator(between: line, and: lines[lineIndex + 1], globalMedianHeight: globalMedianHeight),
                        attributes: [
                            .font: font,
                            .paragraphStyle: paragraphStyle
                        ]
                    )
                )
            }
        }

        return output
    }

    private static func clusterLines(from regions: [OCRTextRegion]) -> [Line] {
        let sorted = regions.sorted { lhs, rhs in
            let verticalDelta = lhs.imageRect.minY - rhs.imageRect.minY
            if abs(verticalDelta) > max(lhs.imageRect.height, rhs.imageRect.height) * 0.45 {
                return verticalDelta < 0
            }
            return lhs.imageRect.minX < rhs.imageRect.minX
        }

        var lines: [Line] = []
        for region in sorted {
            if let last = lines.last, belongs(region, to: last) {
                lines[lines.count - 1].regions.append(region)
            } else {
                lines.append(Line(regions: [region]))
            }
        }

        for index in lines.indices {
            lines[index].regions.sort { $0.imageRect.minX < $1.imageRect.minX }
        }
        return lines
    }

    private static func belongs(_ region: OCRTextRegion, to line: Line) -> Bool {
        let lineRect = line.rect
        let verticalGap = region.imageRect.minY - lineRect.maxY
        let overlap = min(region.imageRect.maxY, lineRect.maxY) - max(region.imageRect.minY, lineRect.minY)
        let centerDistance = abs(region.imageRect.midY - lineRect.midY)
        let allowedGap = max(region.imageRect.height, line.medianHeight) * 0.42
        return (verticalGap <= allowedGap && centerDistance <= max(region.imageRect.height, lineRect.height) * 0.62)
            || overlap > min(region.imageRect.height, lineRect.height) * 0.2
    }

    private static func fittedPointSize(for line: Line, globalMedianHeight: CGFloat, preferredTextWidth: CGFloat) -> CGFloat {
        let basePointSize = max(11, min(28, 13 * (line.medianHeight / max(globalMedianHeight, 1))))
        let weight = fontWeight(for: line, globalMedianHeight: globalMedianHeight)
        let font = NSFont.systemFont(ofSize: basePointSize, weight: weight)
        let lineText = composedLineString(for: line, globalMedianHeight: globalMedianHeight)
        let measuredWidth = (lineText as NSString).size(withAttributes: [.font: font]).width
        guard measuredWidth > preferredTextWidth, measuredWidth > 1 else {
            return basePointSize
        }

        return max(11, floor(basePointSize * preferredTextWidth / measuredWidth))
    }

    private static func fontWeight(for line: Line, globalMedianHeight: CGFloat) -> NSFont.Weight {
        let ratio = line.medianHeight / max(globalMedianHeight, 1)
        if ratio >= 1.45 { return .bold }
        if ratio >= 1.18 { return .semibold }
        return .regular
    }

    private static func makeParagraphStyle(for line: Line, imageSize: CGSize, pointSize: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment(for: line.rect, imageWidth: imageSize.width)
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = max(1, pointSize * 0.12)
        style.defaultTabInterval = max(28, pointSize * 3.2)
        return style
    }

    private static func alignment(for rect: CGRect, imageWidth: CGFloat) -> NSTextAlignment {
        guard imageWidth > 1 else { return .left }
        let horizontalCenterOffset = abs(rect.midX - imageWidth / 2) / imageWidth
        if horizontalCenterOffset < 0.08 && rect.width < imageWidth * 0.72 {
            return .center
        }
        if rect.midX > imageWidth * 0.68 && rect.minX > imageWidth * 0.28 {
            return .right
        }
        return .left
    }

    private static func composedLineString(for line: Line, globalMedianHeight: CGFloat) -> String {
        let sortedRegions = line.regions.sorted { $0.imageRect.minX < $1.imageRect.minX }
        var result = ""
        for regionIndex in sortedRegions.indices {
            if regionIndex > 0 {
                result += spacer(
                    between: sortedRegions[regionIndex - 1],
                    and: sortedRegions[regionIndex],
                    medianHeight: globalMedianHeight
                )
            }
            result += sortedRegions[regionIndex].original
        }
        return result
    }

    private static func spacer(between lhs: OCRTextRegion, and rhs: OCRTextRegion, medianHeight: CGFloat) -> String {
        let gap = rhs.imageRect.minX - lhs.imageRect.maxX
        if gap > medianHeight * 3.2 { return "\t" }
        if gap > medianHeight * 1.15 { return "  " }
        if gap > medianHeight * 0.32 { return " " }
        return ""
    }

    private static func lineSeparator(between upper: Line, and lower: Line, globalMedianHeight: CGFloat) -> String {
        let verticalGap = lower.rect.minY - upper.rect.maxY
        if verticalGap > globalMedianHeight * 1.2 {
            return "\n\n"
        }
        return "\n"
    }

    private static func foregroundColor(for region: OCRTextRegion) -> NSColor {
        let foreground = region.foreground.usingColorSpace(.deviceRGB) ?? .labelColor
        let background = region.background.usingColorSpace(.deviceRGB) ?? .textBackgroundColor
        if contrastRatio(foreground, background) < 1.2 {
            return .labelColor
        }
        return foreground
    }

    private static func backgroundHighlightColor(for region: OCRTextRegion) -> NSColor? {
        let foreground = region.foreground.usingColorSpace(.deviceRGB) ?? .labelColor
        guard contrastRatio(foreground, .textBackgroundColor) < 2.5 else { return nil }
        let background = region.background.usingColorSpace(.deviceRGB) ?? .windowBackgroundColor
        return background.withAlphaComponent(0.26)
    }

    private static func contrastRatio(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let left = lhs.usingColorSpace(.deviceRGB) ?? lhs
        let right = rhs.usingColorSpace(.deviceRGB) ?? rhs
        let lhsLum = relativeLuminance(of: left)
        let rhsLum = relativeLuminance(of: right)
        let brighter = max(lhsLum, rhsLum)
        let darker = min(lhsLum, rhsLum)
        return (brighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(of color: NSColor) -> CGFloat {
        func linearize(_ component: CGFloat) -> CGFloat {
            if component <= 0.03928 {
                return component / 12.92
            }
            return pow((component + 0.055) / 1.055, 2.4)
        }

        let red = linearize(color.redComponent)
        let green = linearize(color.greenComponent)
        let blue = linearize(color.blueComponent)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    private static func median(for values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 1 }
        let sorted = values.sorted()
        if sorted.count.isMultiple(of: 2) {
            let upper = sorted[sorted.count / 2]
            let lower = sorted[sorted.count / 2 - 1]
            return (lower + upper) / 2
        }
        return sorted[sorted.count / 2]
    }
}

private struct OCRTranslateProgressOverlay: View {
    let badgeTitle: String
    let title: String
    let detail: String
    let cancelTitle: String
    let onCancel: () -> Void

    @State private var pulse = false
    @State private var orbit = false
    @State private var bars = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black.opacity(0.24), Color.black.opacity(0.48)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.08, green: 0.14, blue: 0.24).opacity(0.96),
                                    Color(red: 0.19, green: 0.07, blue: 0.31).opacity(0.95)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 30, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.16, green: 0.88, blue: 0.98).opacity(0.92),
                                            Color(red: 0.97, green: 0.43, blue: 0.84).opacity(0.82),
                                            Color(red: 1.0, green: 0.67, blue: 0.29).opacity(0.9)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.2
                                )
                        }
                        .shadow(color: Color(red: 0.09, green: 0.81, blue: 0.96).opacity(0.24), radius: 30, y: 12)

                    Text(badgeTitle)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.96))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.12), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.8))
                        .padding(16)

                    VStack(spacing: 18) {
                        ZStack {
                            Circle()
                                .fill(
                                    RadialGradient(
                                        colors: [
                                            Color(red: 0.18, green: 0.94, blue: 0.99).opacity(0.75),
                                            Color(red: 0.18, green: 0.94, blue: 0.99).opacity(0.06)
                                        ],
                                        center: .center,
                                        startRadius: 2,
                                        endRadius: 56
                                    )
                                )
                                .frame(width: pulse ? 132 : 108, height: pulse ? 132 : 108)

                            Circle()
                                .stroke(
                                    AngularGradient(
                                        colors: [
                                            Color(red: 0.17, green: 0.92, blue: 1.0),
                                            Color(red: 0.98, green: 0.35, blue: 0.82),
                                            Color(red: 1.0, green: 0.7, blue: 0.28),
                                            Color(red: 0.17, green: 0.92, blue: 1.0)
                                        ],
                                        center: .center
                                    ),
                                    lineWidth: 3
                                )
                                .frame(width: 110, height: 110)
                                .rotationEffect(.degrees(orbit ? 360 : 0))

                            Circle()
                                .stroke(Color.white.opacity(0.26), lineWidth: 1.3)
                                .frame(width: pulse ? 88 : 74, height: pulse ? 88 : 74)

                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.12, green: 0.89, blue: 0.99),
                                            Color(red: 0.41, green: 0.38, blue: 1.0)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 64, height: 64)
                                .shadow(color: Color(red: 0.14, green: 0.88, blue: 1.0).opacity(0.55), radius: 18)

                            Image(systemName: "translate")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .frame(height: 124)

                        VStack(spacing: 10) {
                            Text(title)
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)

                            Text(detail)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.84))
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                        }

                        HStack(spacing: 8) {
                            ForEach(0..<5, id: \.self) { index in
                                Capsule(style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color.white.opacity(0.96),
                                                Color(red: 0.19, green: 0.91, blue: 0.99)
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .frame(width: 9, height: bars ? [14, 28, 38, 28, 14][index] : [26, 14, 28, 14, 26][index])
                                    .shadow(color: Color(red: 0.16, green: 0.9, blue: 1.0).opacity(0.3), radius: 8)
                                    .animation(
                                        .easeInOut(duration: 0.76)
                                            .repeatForever(autoreverses: true)
                                            .delay(Double(index) * 0.08),
                                        value: bars
                                    )
                            }
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.vertical, 30)
                }
                .frame(maxWidth: 460)
                .padding(.horizontal, 24)

                Spacer()

                Button(action: onCancel) {
                    HStack(spacing: 10) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18, weight: .bold))
                        Text(cancelTitle)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .frame(minWidth: 228)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.41, blue: 0.33),
                                Color(red: 1.0, green: 0.68, blue: 0.26)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: Capsule(style: .continuous)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.34), lineWidth: 1)
                    )
                    .shadow(color: Color(red: 1.0, green: 0.6, blue: 0.18).opacity(0.42), radius: 20, y: 8)
                    .scaleEffect(pulse ? 1.02 : 0.98)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true)) {
                pulse = true
            }
            withAnimation(.linear(duration: 7.2).repeatForever(autoreverses: false)) {
                orbit = true
            }
            withAnimation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true)) {
                bars = true
            }
        }
    }
}

@available(macOS 15.0, *)
extension AnnotationEditorPanel {

    func toggleOCRTranslateOverlay() {
        guard AppStoreComplianceFeatures.isOCRTranslationOverlayEnabled else {
            showAlert(
                title: EditorL10n.tr(.ocrTranslateFailedTitle),
                message: EditorL10n.tr(.ocrTranslateFailedMessagePrefix)
                    + AppComplianceL10n.ocrTranslationUnavailableMessage
            )
            return
        }
        guard !isOCRTranslating else { return }

        if isOCRTranslationApplied {
            if let original = preTranslationScreenshot {
                canvas.screenshot = original
            }
            preTranslationScreenshot = nil
            isOCRTranslationApplied = false
            if state.selectedTool == .ocrTranslate {
                state.selectedTool = nil
            }
            return
        }

        preTranslationScreenshot = canvas.screenshot
        state.selectedTool = .ocrTranslate
        runOCRTranslateOverlay(sourceImage: canvas.screenshot)
    }

    func runOCRTranslateOverlay(sourceImage: NSImage) {
        guard !isOCRTranslating else { return }
        let sessionToken = UUID()
        ocrTranslateSessionToken = sessionToken
        isOCRTranslating = true
        showTranslateHUD()
        syncFloatingToolbarVisibility()

        ocrTranslateTask?.cancel()
        ocrTranslateTask = Task { [weak self] in
            do {
                let regions = try await OCRTranslateOverlayRunner.recognize(in: sourceImage)
                guard !Task.isCancelled else { return }
                if regions.isEmpty {
                    await MainActor.run {
                        guard let self, self.isCurrentOCRTranslateSession(sessionToken) else { return }
                        self.ocrTranslateTask = nil
                        self.isOCRTranslating = false
                        self.isOCRTranslationApplied = false
                        self.preTranslationScreenshot = nil
                        if self.state.selectedTool == .ocrTranslate {
                            self.state.selectedTool = nil
                        }
                        self.hideTranslateHUD()
                        self.showAlert(
                            title: EditorL10n.tr(.ocrEmptyTitle),
                            message: EditorL10n.tr(.ocrTranslatableEmptyMessage)
                        )
                    }
                    return
                }
                await MainActor.run {
                    guard let self, self.isCurrentOCRTranslateSession(sessionToken) else { return }
                    self.ocrTranslateTask = nil
                    self.beginTranslationSession(sourceImage: sourceImage, regions: regions, sessionToken: sessionToken)
                }
            } catch is CancellationError {
                await MainActor.run {
                    if self?.ocrTranslateSessionToken == sessionToken {
                        self?.ocrTranslateTask = nil
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self, self.isCurrentOCRTranslateSession(sessionToken) else { return }
                    self.ocrTranslateTask = nil
                    self.handleOCRTranslateFailure(error)
                }
            }
        }
    }

    private func beginTranslationSession(sourceImage: NSImage, regions: [OCRTextRegion], sessionToken: UUID) {
        // Inject a hidden hosting view to drive .translationTask.
        let runner = OCRTranslationRunnerView(
            sources: regions.map { $0.original },
            onResult: { [weak self] translated in
                guard let self, self.isCurrentOCRTranslateSession(sessionToken) else { return }
                self.finishTranslation(
                    sourceImage: sourceImage,
                    regions: regions,
                    translations: translated
                )
            },
            onFailure: { [weak self] error in
                guard let self, self.isCurrentOCRTranslateSession(sessionToken) else { return }
                self.handleOCRTranslateFailure(error)
            }
        )
        let hosting = NSHostingView(rootView: runner)
        hosting.frame = CGRect(x: -1, y: -1, width: 1, height: 1)
        hosting.alphaValue = 0
        contentView?.addSubview(hosting)
        translationHostView = hosting
    }

    private func isCurrentOCRTranslateSession(_ sessionToken: UUID) -> Bool {
        isOCRTranslating && ocrTranslateSessionToken == sessionToken
    }

    private func cancelOCRTranslationProcess(restoreToolbar: Bool = true) {
        ocrTranslateSessionToken = UUID()
        ocrTranslateTask?.cancel()
        ocrTranslateTask = nil
        tearDownTranslationHost()
        hideTranslateHUD(syncToolbar: restoreToolbar)
        isOCRTranslating = false
        isOCRTranslationApplied = false
        preTranslationScreenshot = nil
        if state.selectedTool == .ocrTranslate {
            state.selectedTool = nil
        }
        if restoreToolbar {
            syncFloatingToolbarVisibility()
        }
    }

    private func finishTranslation(sourceImage: NSImage, regions: [OCRTextRegion], translations: [String]) {
        tearDownTranslationHost()
        ocrTranslateTask = nil
        var merged = regions
        var translatedCount = 0
        for idx in merged.indices where idx < translations.count {
            let translated = translations[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            if !translated.isEmpty, translated != merged[idx].original {
                merged[idx].translated = translated
                translatedCount += 1
            } else {
                merged[idx].translated = nil
            }
        }

        guard translatedCount > 0 else {
            isOCRTranslating = false
            isOCRTranslationApplied = false
            preTranslationScreenshot = nil
            if state.selectedTool == .ocrTranslate {
                state.selectedTool = nil
            }
            hideTranslateHUD()
            showAlert(
                title: EditorL10n.tr(.ocrEmptyTitle),
                message: EditorL10n.tr(.ocrTranslatableEmptyMessage)
            )
            return
        }

        let composed = OCRTranslateOverlayRunner.compose(base: sourceImage, regions: merged)
        canvas.screenshot = composed
        isOCRTranslating = false
        isOCRTranslationApplied = true
        state.selectedTool = .ocrTranslate
        hideTranslateHUD()
    }

    private func handleOCRTranslateFailure(_ error: Error) {
        tearDownTranslationHost()
        ocrTranslateTask = nil
        isOCRTranslating = false
        isOCRTranslationApplied = false
        preTranslationScreenshot = nil
        if state.selectedTool == .ocrTranslate {
            state.selectedTool = nil
        }
        hideTranslateHUD()
        showAlert(
            title: EditorL10n.tr(.ocrTranslateFailedTitle),
            message: EditorL10n.tr(.ocrTranslateFailedMessagePrefix) + error.localizedDescription
        )
    }

    private func tearDownTranslationHost() {
        translationHostView?.removeFromSuperview()
        translationHostView = nil
    }

    private func showTranslateHUD() {
        guard translateHUD == nil, let content = contentView else { return }
        let host = NSHostingView(
            rootView: OCRTranslateProgressOverlay(
                badgeTitle: EditorL10n.tr(.toolOCRTranslate),
                title: EditorL10n.tr(.ocrTranslateInProgress),
                detail: EditorL10n.tr(.ocrTranslateProgressDetail),
                cancelTitle: EditorL10n.tr(.actionCancelTranslation),
                onCancel: { [weak self] in
                    self?.cancelOCRTranslationProcess()
                }
            )
        )
        host.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            host.topAnchor.constraint(equalTo: content.topAnchor),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        translateHUD = host
    }

    private func hideTranslateHUD(syncToolbar: Bool = true) {
        translateHUD?.removeFromSuperview()
        translateHUD = nil
        if syncToolbar {
            syncFloatingToolbarVisibility()
        }
    }
}

@available(macOS 15.0, *)
private enum OCRTranslateOverlayRunner {

    static func recognize(in image: NSImage) async throws -> [OCRTextRegion] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }
        let width = cgImage.width
        let height = cgImage.height

        let observations: [VNRecognizedTextObservation] = try await withCheckedThrowingContinuation { cont in
            let req = VNRecognizeTextRequest { request, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                cont.resume(returning: (request.results as? [VNRecognizedTextObservation]) ?? [])
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            req.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "ru-RU"]
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([req])
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        guard !observations.isEmpty, let sampler = PixelSampler(cgImage: cgImage) else {
            return []
        }

        return observations.compactMap { obs -> OCRTextRegion? in
            guard let text = obs.topCandidates(1).first?.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            // Vision bounding box is normalized with origin bottom-left; convert to pixel rect (top-left origin).
            let bb = obs.boundingBox
            let rect = CGRect(
                x: bb.origin.x * CGFloat(width),
                y: (1 - bb.origin.y - bb.height) * CGFloat(height),
                width: bb.width * CGFloat(width),
                height: bb.height * CGFloat(height)
            ).integral
            let (fg, bg) = sampler.classifyColors(in: rect)
            return OCRTextRegion(
                imageRect: rect,
                original: text,
                translated: nil,
                foreground: fg,
                background: bg
            )
        }
    }

    @MainActor
    static func compose(base: NSImage, regions: [OCRTextRegion]) -> NSImage {
        // Use the image pixel dimensions so overlay coordinates match Vision output.
        let cgRef = base.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let pixelSize = cgRef.map { CGSize(width: $0.width, height: $0.height) } ?? base.size
        let img = NSImage(size: pixelSize)
        img.lockFocusFlipped(false)
        defer { img.unlockFocus() }

        base.draw(in: CGRect(origin: .zero, size: pixelSize),
                  from: .zero,
                  operation: .copy,
                  fraction: 1.0)

        for region in regions {
            guard let translated = region.translated?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !translated.isEmpty,
                  translated != region.original else { continue }
            let imageRect = region.imageRect
            // Translate top-left origin rect into the bottom-left origin drawing space.
            let drawRect = CGRect(
                x: imageRect.origin.x,
                y: pixelSize.height - imageRect.origin.y - imageRect.height,
                width: imageRect.width,
                height: imageRect.height
            ).insetBy(dx: -1, dy: -1)

            // Mask out the original text with the sampled background color.
            region.background.setFill()
            NSBezierPath(rect: drawRect).fill()

            // Draw translated text centered, scaled to fit the bounding box.
            drawFittedText(translated,
                           in: drawRect,
                           color: region.foreground)
        }
        return img
    }

    private static func drawFittedText(_ text: String, in rect: CGRect, color: NSColor) {
        let ns = text as NSString
        // Start from a font size close to the bounding box height, then shrink until width fits.
        var size = max(6, floor(rect.height * 0.9))
        let minimumSize: CGFloat = 6
        let maxWidth = max(1, rect.width - 2)

        var font = NSFont.systemFont(ofSize: size)
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var textSize = ns.size(withAttributes: attrs)
        while (textSize.width > maxWidth || textSize.height > rect.height) && size > minimumSize {
            size -= 1
            font = NSFont.systemFont(ofSize: size)
            attrs[.font] = font
            textSize = ns.size(withAttributes: attrs)
        }

        let drawPoint = CGPoint(
            x: rect.midX - textSize.width / 2,
            y: rect.midY - textSize.height / 2
        )
        ns.draw(at: drawPoint, withAttributes: attrs)
    }
}

/// SwiftUI host that drives Apple's Translation framework session.
@available(macOS 15.0, *)
private struct OCRTranslationRunnerView: View {
    let sources: [String]
    let onResult: ([String]) -> Void
    let onFailure: (Error) -> Void

    @State private var configuration: TranslationSession.Configuration?

    init(sources: [String],
         onResult: @escaping ([String]) -> Void,
         onFailure: @escaping (Error) -> Void) {
        self.sources = sources
        self.onResult = onResult
        self.onFailure = onFailure
        // Eagerly resolve source/target so `.translationTask` fires
        // immediately with a usable configuration (avoids racey nil
        // pass that often produced empty sessions).
        let resolved = OCRTranslationLanguageResolver.resolve(for: sources)
        _configuration = State(initialValue: TranslationSession.Configuration(
            source: resolved.source,
            target: resolved.target
        ))
    }

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(configuration) { session in
                await runTranslation(using: session)
            }
    }

    private func runTranslation(using session: TranslationSession) async {
        // 1. Pre-warm: ask the framework to download / prepare the
        //    language pair before issuing translate calls. Without this,
        //    the first call routinely fails on a fresh machine.
        do {
            try await session.prepareTranslation()
        } catch {
            // Non-fatal: prepareTranslation may throw when the user
            // declines a download prompt, but individual translate
            // calls can still succeed for already-installed pairs.
        }

        // 2. Skip strings that aren't worth translating; preserve them
        //    as-is so a single bad item never wrecks the batch.
        let work = sources.enumerated().map { (index, text) -> (Int, String) in
            (index, text)
        }
        let translatable = work.filter { OCRTranslationLanguageResolver.isTranslatable($0.1) }

        var results = sources                     // fallback = original
        guard !translatable.isEmpty else {
            await MainActor.run { onResult(results) }
            return
        }

        // 3. Try the batch API first. It's faster and more tolerant of
        //    individual quirky inputs than per-item calls.
        let requests = translatable.map { (idx, text) in
            TranslationSession.Request(sourceText: text, clientIdentifier: String(idx))
        }

        do {
            let responses = try await session.translations(from: requests)
            for response in responses {
                if let raw = response.clientIdentifier, let idx = Int(raw),
                   idx >= 0, idx < results.count {
                    let translated = response.targetText
                    if !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        results[idx] = translated
                    }
                }
            }
            await MainActor.run { onResult(results) }
            return
        } catch {
            // Fall through to per-item retry below.
        }

        // 4. Per-item fallback: each failure is contained.
        for (idx, text) in translatable {
            do {
                let response = try await session.translate(text)
                let translated = response.targetText
                if !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    results[idx] = translated
                }
            } catch {
                // Keep the original text for this region.
                continue
            }
        }
        await MainActor.run { onResult(results) }
    }
}

/// Picks source / target languages for the OCR translation pipeline.
/// Centralised so the runner view stays focused on Apple's API surface.
@available(macOS 15.0, *)
private enum OCRTranslationLanguageResolver {

    static func resolve(for sources: [String]) -> (source: Locale.Language?, target: Locale.Language?) {
        let joined = sources.joined(separator: "\n")
        let detected = detectLanguage(in: joined)
        let detectedCode = detected?.languageCode?.identifier

        // Pick a target that is *different* from the detected source.
        // Apple's framework treats source == target as an error.
        let preferred = preferredTargetLanguageCodes(excluding: detectedCode)
        let targetCode = preferred.first
        let target = targetCode.map { Locale.Language(identifier: $0) }
        return (detected, target)
    }

    static func isTranslatable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 1 else { return false }
        // Pure digits / punctuation / symbols typically cause the
        // framework to throw; skip them so the batch survives.
        let nonAlpha = CharacterSet.letters.inverted
        if trimmed.unicodeScalars.allSatisfy({ nonAlpha.contains($0) }) {
            return false
        }
        return true
    }

    private static func detectLanguage(in text: String) -> Locale.Language? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        return Locale.Language(identifier: dominant.rawValue)
    }

    /// User's preferred languages in order, normalised to BCP-47 base
    /// codes (e.g. `zh-Hans`, `en`, `ja`), with the detected source
    /// removed so we never pick the same language for both sides.
    private static func preferredTargetLanguageCodes(excluding sourceCode: String?) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        let current = normalizeLanguageCode(Locale.current.identifier)
        if !current.isEmpty,
           !(sourceCode.map { codesAreEquivalent(current, $0) } ?? false),
           seen.insert(current).inserted {
            ordered.append(current)
        }

        for raw in Locale.preferredLanguages {
            let normalized = normalizeLanguageCode(raw)
            guard !normalized.isEmpty else { continue }
            if let source = sourceCode, codesAreEquivalent(normalized, source) { continue }
            if seen.insert(normalized).inserted {
                ordered.append(normalized)
            }
        }
        // Sensible defaults if the user has only the source language
        // configured: prefer English when the source is non-English,
        // otherwise prefer Simplified Chinese.
        if ordered.isEmpty {
            if let source = sourceCode, codesAreEquivalent(source, "en") {
                ordered.append("zh-Hans")
            } else {
                ordered.append("en")
            }
        }
        return ordered
    }

    private static func normalizeLanguageCode(_ raw: String) -> String {
        // Locale.preferredLanguages returns things like "zh-Hans-CN".
        // Translation expects the script-qualified base ("zh-Hans") or
        // a plain code ("en"). Strip the region.
        let language = Locale.Language(identifier: raw)
        let base: String
        if let script = language.script?.identifier,
           let code = language.languageCode?.identifier,
           !script.isEmpty {
            base = "\(code)-\(script)"
        } else if let code = language.languageCode?.identifier {
            base = code
        } else {
            base = raw
        }
        return base
    }

    private static func codesAreEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        let l = Locale.Language(identifier: lhs).languageCode?.identifier ?? lhs
        let r = Locale.Language(identifier: rhs).languageCode?.identifier ?? rhs
        return l.caseInsensitiveCompare(r) == .orderedSame
    }
}

// MARK: – Pixel sampler used to infer foreground/background colors for each text region.

private final class PixelSampler {
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int
    private let buffer: [UInt8]

    init?(cgImage: CGImage) {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = pixels.withUnsafeMutableBytes({ ptr -> CGContext? in
            guard let base = ptr.baseAddress else { return nil }
            return CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )
        }) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.buffer = pixels
    }

    /// Separates pixels in `rect` (image pixel coords, top-left origin) into text / background clusters via luminance.
    /// The minority cluster is treated as text (foreground); the majority cluster as background.
    func classifyColors(in rect: CGRect) -> (fg: NSColor, bg: NSColor) {
        let minX = max(0, Int(rect.minX))
        let maxX = min(width, Int(ceil(rect.maxX)))
        let minY = max(0, Int(rect.minY))
        let maxY = min(height, Int(ceil(rect.maxY)))
        guard maxX > minX, maxY > minY else {
            return (.labelColor, .windowBackgroundColor)
        }

        // Sample every pixel in small rects; stride larger ones to cap work.
        let stride = max(1, Int(ceil(sqrt(Double((maxX - minX) * (maxY - minY)) / 2000.0))))

        var samples: [(r: Int, g: Int, b: Int, lum: Double)] = []
        samples.reserveCapacity(((maxX - minX) / stride) * ((maxY - minY) / stride) + 16)

        for y in Swift.stride(from: minY, to: maxY, by: stride) {
            for x in Swift.stride(from: minX, to: maxX, by: stride) {
                let idx = y * bytesPerRow + x * 4
                let r = Int(buffer[idx])
                let g = Int(buffer[idx + 1])
                let b = Int(buffer[idx + 2])
                // Rec. 601 luma approximation.
                let lum = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
                samples.append((r, g, b, lum))
            }
        }
        guard !samples.isEmpty else {
            return (.labelColor, .windowBackgroundColor)
        }

        let avgLum = samples.reduce(0.0) { $0 + $1.lum } / Double(samples.count)
        var darkR = 0, darkG = 0, darkB = 0, darkCount = 0
        var lightR = 0, lightG = 0, lightB = 0, lightCount = 0
        for s in samples {
            if s.lum < avgLum {
                darkR += s.r; darkG += s.g; darkB += s.b; darkCount += 1
            } else {
                lightR += s.r; lightG += s.g; lightB += s.b; lightCount += 1
            }
        }
        func makeColor(_ r: Int, _ g: Int, _ b: Int, count: Int) -> NSColor {
            guard count > 0 else { return .labelColor }
            return NSColor(
                srgbRed: CGFloat(r) / CGFloat(count) / 255.0,
                green: CGFloat(g) / CGFloat(count) / 255.0,
                blue: CGFloat(b) / CGFloat(count) / 255.0,
                alpha: 1
            )
        }
        let darkColor = makeColor(darkR, darkG, darkB, count: darkCount)
        let lightColor = makeColor(lightR, lightG, lightB, count: lightCount)

        // Minority cluster is foreground (text); majority is background.
        if darkCount <= lightCount {
            return (fg: darkColor, bg: lightColor)
        } else {
            return (fg: lightColor, bg: darkColor)
        }
    }
}

private final class OCRScanOverlayView: NSView {
    private let dimLayer = CALayer()
    private let bandLayer = CAGradientLayer()
    private let lineLayer = CAGradientLayer()
    private var isAnimating = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        alphaValue = 0
        setupLayers()
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        guard let rootLayer = layer else { return }

        rootLayer.frame = bounds
        dimLayer.frame = bounds

        let bandHeight = max(56, bounds.height * 0.14)
        bandLayer.frame = CGRect(x: 0, y: bounds.height - bandHeight, width: bounds.width, height: bandHeight)

        let lineHeight: CGFloat = 2
        lineLayer.frame = CGRect(x: 0, y: bounds.height - lineHeight, width: bounds.width, height: lineHeight)
    }

    func startAnimating() {
        guard !isAnimating else { return }

        isAnimating = true
        isHidden = false
        alphaValue = 0
        layoutSubtreeIfNeeded()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 1
        }

        bandLayer.removeAllAnimations()
        lineLayer.removeAllAnimations()

        let duration: CFTimeInterval = 1.9

        let bandAnimation = CABasicAnimation(keyPath: "position.y")
        bandAnimation.fromValue = bounds.height + bandLayer.bounds.height / 2
        bandAnimation.toValue = -bandLayer.bounds.height / 2
        bandAnimation.duration = duration
        bandAnimation.repeatCount = .infinity
        bandAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bandAnimation.isRemovedOnCompletion = false
        bandLayer.add(bandAnimation, forKey: "scanBand")

        let lineAnimation = CABasicAnimation(keyPath: "position.y")
        lineAnimation.fromValue = bounds.height + lineLayer.bounds.height / 2
        lineAnimation.toValue = -lineLayer.bounds.height / 2
        lineAnimation.duration = duration
        lineAnimation.repeatCount = .infinity
        lineAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        lineAnimation.isRemovedOnCompletion = false
        lineLayer.add(lineAnimation, forKey: "scanLine")

        let pulseAnimation = CABasicAnimation(keyPath: "opacity")
        pulseAnimation.fromValue = 0.82
        pulseAnimation.toValue = 0.96
        pulseAnimation.duration = 1.25
        pulseAnimation.autoreverses = true
        pulseAnimation.repeatCount = .infinity
        pulseAnimation.isRemovedOnCompletion = false
        bandLayer.add(pulseAnimation, forKey: "scanPulse")
    }

    func stopAnimating() {
        guard isAnimating else {
            alphaValue = 0
            isHidden = true
            return
        }

        isAnimating = false
        bandLayer.removeAllAnimations()
        lineLayer.removeAllAnimations()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, !self.isAnimating else { return }
            self.isHidden = true
        }
    }

    private func setupLayers() {
        let accentColor = NSColor.controlAccentColor.usingColorSpace(.deviceRGB) ?? .systemGreen

        dimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.04).cgColor

        bandLayer.colors = [
            accentColor.withAlphaComponent(0).cgColor,
            accentColor.withAlphaComponent(0.025).cgColor,
            accentColor.withAlphaComponent(0.10).cgColor,
            accentColor.withAlphaComponent(0.025).cgColor,
            accentColor.withAlphaComponent(0).cgColor,
        ]
        bandLayer.locations = [0, 0.3, 0.5, 0.7, 1]
        bandLayer.startPoint = CGPoint(x: 0.5, y: 1)
        bandLayer.endPoint = CGPoint(x: 0.5, y: 0)
        bandLayer.opacity = 0.88

        lineLayer.colors = [
            accentColor.withAlphaComponent(0).cgColor,
            accentColor.withAlphaComponent(0.24).cgColor,
            NSColor.white.withAlphaComponent(0.72).cgColor,
            accentColor.withAlphaComponent(0.24).cgColor,
            accentColor.withAlphaComponent(0).cgColor,
        ]
        lineLayer.startPoint = CGPoint(x: 0, y: 0.5)
        lineLayer.endPoint = CGPoint(x: 1, y: 0.5)
        lineLayer.shadowColor = accentColor.withAlphaComponent(0.45).cgColor
        lineLayer.shadowOpacity = 1
        lineLayer.shadowRadius = 18
        lineLayer.shadowOffset = .zero

        layer?.addSublayer(dimLayer)
        layer?.addSublayer(bandLayer)
        layer?.addSublayer(lineLayer)
    }
}
