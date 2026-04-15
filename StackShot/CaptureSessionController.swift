import AppKit
import CoreGraphics

/// 协调高亮边框、工具条与区域选取流程。
final class CaptureSessionController {
    static let shared = CaptureSessionController()

    private var highlight: HighlightBorderWindow?
    private var toolbar: FloatingToolbarPanel?
    private var overlay: RegionSelectionOverlay?
    private var annotationEditor: AnnotationEditorPanel?
    private var currentHoveredWindow: WindowUnderMouseInfo?
    private var hoverTimer: Timer?
    private var globalClickMonitor: Any?

    private init() {}

    // MARK: – Public entry

    func activateFromHotkey() {
        annotationEditor?.close()
        annotationEditor = nil
        dismissHoverUI()
        NSApp.activate(ignoringOtherApps: true)
        // 产品流程：先框选截图区域，完成后再进入编辑工具栏。
        captureAndOpenEditor(initialTool: .rectangle)
    }

    // MARK: – Hover tracking

    private func beginHoverTracking() {
        if hoverTimer == nil {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
                self?.refreshHoveredWindow(force: false)
            }
        }
        if globalClickMonitor == nil {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                self?.handleMouseDown(event)
            }
        }
    }

    private func endHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        if let m = globalClickMonitor {
            NSEvent.removeMonitor(m)
            globalClickMonitor = nil
        }
    }

    private func refreshHoveredWindow(force: Bool) {
        guard overlay == nil else { return }
        let latest = WindowUnderMouseService.windowUnderMouse()
        guard force || latest != currentHoveredWindow else { return }
        currentHoveredWindow = latest

        guard let info = latest else {
            highlight?.orderOut(nil)
            toolbar?.orderOut(nil)
            return
        }

        if let h = highlight {
            h.setFrame(info.bounds, display: true)
            h.orderFrontRegardless()
        } else {
            let h = HighlightBorderWindow(frame: info.bounds)
            h.orderFrontRegardless()
            highlight = h
        }

        if let t = toolbar {
            t.reposition(anchorFrame: info.bounds)
            t.orderFrontRegardless()
        } else {
            let t = FloatingToolbarPanel(
                anchorFrame: info.bounds,
                callbacks: makeToolbarCallbacks()
            )
            t.orderFrontRegardless()
            toolbar = t
        }
    }

    // MARK: – Build all 16 toolbar callbacks

    private func makeToolbarCallbacks() -> FloatingToolbarCallbacks {
        FloatingToolbarCallbacks(
            // Group 1 – capture / draw
            onRect:         { [weak self] in self?.startSelection(.rectangle) },
            onCircle:       { [weak self] in self?.startSelection(.circle) },
            onEmoji:        { NSApp.orderFrontCharacterPalette(nil) },
            onArrow:        { [weak self] in self?.captureAndOpenEditor(initialTool: .arrow) },
            onPen:          { [weak self] in self?.captureAndOpenEditor(initialTool: .pen) },
            onMosaic:       { [weak self] in self?.captureAndOpenEditor(initialTool: .mosaic) },
            onText:         { [weak self] in self?.captureAndOpenEditor(initialTool: .text) },
            // Group 2 – process (capture first, then apply)
            onOCRTranslate: { [weak self] in self?.captureAndOpenEditor(initialTool: .ocrTranslate) },
            onOCR:          { [weak self] in self?.captureAndOpenEditor(initialTool: .ocr) },
            onCrop:         { [weak self] in self?.captureAndOpenEditor(initialTool: .crop) },
            // Group 3 – actions (capture first, then perform)
            onUndo:         { },          // no-op before capture
            onSave:         { [weak self] in self?.captureAndOpenEditor(initialTool: .rectangle) },
            onPin:          { [weak self] in self?.captureAndOpenEditor(initialTool: .rectangle) },
            onShare:        { [weak self] in self?.captureAndOpenEditor(initialTool: .rectangle) },
            onCancel:       { [weak self] in self?.endSession() },
            onConfirm:      { [weak self] in self?.captureAndOpenEditor(initialTool: .rectangle) }
        )
    }

    // MARK: – Double-click whole window

    private func handleMouseDown(_ event: NSEvent) {
        guard event.clickCount >= 2, overlay == nil else { return }
        captureCurrentHoveredWindowByDoubleClick()
    }

    private func captureCurrentHoveredWindowByDoubleClick() {
        guard ensureScreenCapturePermission() else { endSession(); return }
        guard let info = currentHoveredWindow ?? WindowUnderMouseService.windowUnderMouse() else { return }

        guard let cgImage = CGWindowListCreateImage(
            .null, .optionIncludingWindow, info.windowID, .bestResolution
        ) else {
            showCaptureFailedAlert(reason: "窗口截图失败，可能被系统隐私设置阻止。")
            endSession()
            return
        }

        let image = NSImage(cgImage: cgImage,
                            size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        dismissHoverUI()
        showAnnotationEditor(for: image, initialTool: .rectangle)
    }

    // MARK: – Region selection

    /// Start drag-to-select for the chosen shape.
    private func startSelection(_ shape: RegionSelectionShape) {
        guard ensureScreenCapturePermission() else { endSession(); return }
        endHoverTracking()
        highlight?.orderOut(nil)
        toolbar?.orderOut(nil)

        let overlayWindow = RegionSelectionOverlay(
            shape: shape,
            onComplete: { [weak self] rect, sh in
                self?.handleCaptured(rect: rect, shape: sh, initialTool: shapeDefaultTool(sh))
            },
            onCancel: { [weak self] in self?.endSession() }
        )
        overlayWindow.prepareForCapture()
        overlay = overlayWindow
    }

    /// Capture a rectangular region and open the editor with a specific initial tool.
    private func captureAndOpenEditor(initialTool: AnnotationTool) {
        guard ensureScreenCapturePermission() else { endSession(); return }
        endHoverTracking()
        highlight?.orderOut(nil)
        toolbar?.orderOut(nil)

        let overlayWindow = RegionSelectionOverlay(
            shape: .rectangle,
            onComplete: { [weak self] rect, _ in
                self?.handleCaptured(rect: rect, shape: .rectangle, initialTool: initialTool)
            },
            onCancel: { [weak self] in self?.endSession() }
        )
        overlayWindow.prepareForCapture()
        overlay = overlayWindow
    }

    // MARK: – Post-capture

    private func handleCaptured(rect: CGRect, shape: RegionSelectionShape,
                                 initialTool: AnnotationTool = .rectangle) {
        // NOTE: Do NOT use defer { endSession() } here.  endSession() calls orderOut / nil on
        // overlay/toolbar/highlight while the AnnotationEditorPanel is animating in; that causes
        // _NSWindowTransformAnimation to hold dangling pointers → crash in objc_release.
        guard rect.width >= 2, rect.height >= 2 else { endSession(); return }

        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2.0
        let snapped = CGRect(
            x: floor(rect.origin.x * scale) / scale,
            y: floor(rect.origin.y * scale) / scale,
            width:  ceil(rect.width  * scale) / scale,
            height: ceil(rect.height * scale) / scale
        )

        guard let cgImage = CGWindowListCreateImage(
            snapped, .optionOnScreenOnly, kCGNullWindowID, .bestResolution
        ) else {
            showCaptureFailedAlert(reason: "无法创建图像，可能被系统隐私设置阻止。")
            endSession()
            return
        }

        if cgImage.width <= 1 || cgImage.height <= 1 {
            showCaptureFailedAlert(reason: "截图为空。请在「系统设置 → 隐私与安全性 → 屏幕录制」中允许 StackShot。")
            endSession()
            return
        }

        var nsImage = NSImage(cgImage: cgImage,
                              size: NSSize(width: snapped.width, height: snapped.height))
        if shape == .circle {
            nsImage = Self.applyCircularMask(to: nsImage) ?? nsImage
        }

        dismissHoverUI()
        showAnnotationEditor(for: nsImage, initialTool: initialTool)
    }

    private func showAnnotationEditor(for image: NSImage,
                                      initialTool: AnnotationTool = .rectangle) {
        let editor = AnnotationEditorPanel(screenshot: image, initialTool: initialTool)
        editor.onConfirm = { [weak self] _ in self?.annotationEditor = nil }
        editor.onCancel  = { [weak self] in   self?.annotationEditor = nil }
        NSApp.activate(ignoringOtherApps: true)
        editor.makeKeyAndOrderFront(nil)
        annotationEditor = editor
    }

    // MARK: – Utilities

    /// Hide and nil all hover-phase windows using orderOut (no close animation) to
    /// avoid CoreAnimation conflicts when showing the annotation editor immediately after.
    private func dismissHoverUI() {
        endHoverTracking()
        currentHoveredWindow = nil
        overlay?.orderOut(nil);   overlay   = nil
        toolbar?.orderOut(nil);   toolbar   = nil
        highlight?.orderOut(nil); highlight = nil
    }

    func endSession() {
        dismissHoverUI()
        // Annotation editor manages its own lifecycle via onConfirm / onCancel.
    }

    private func ensureScreenCapturePermission() -> Bool {
        #if DEBUG
        // 开发调试阶段默认放行，避免频繁弹权限引导打断流程。
        return true
        #else
        if CGPreflightScreenCaptureAccess() { return true }

        // CGRequestScreenCaptureAccess() registers the app in
        // System Settings > Privacy & Security > Screen Recording
        // (required before the user can see it in the list).
        CGRequestScreenCaptureAccess()

        // Show a clear guide so the user knows exactly what to do.
        let alert = NSAlert()
        alert.messageText     = "需要屏幕录制权限"
        alert.informativeText = """
            请按以下步骤操作：
            1. 点击「打开系统设置」
            2. 在「屏幕录制」列表中找到 StackShot，开启开关
            3. 重新按下快捷键 Shift + Command + A 即可截图
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            NSWorkspace.shared.open(url)
        }

        return false
        #endif
    }

    private static func applyCircularMask(to image: NSImage) -> NSImage? {
        let size = image.size
        guard size.width > 1, size.height > 1 else { return nil }
        return NSImage(size: size, flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            image.draw(in: rect, from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1)
            return true
        }
    }

    private func showCaptureFailedAlert(reason: String) {
        let alert = NSAlert()
        alert.messageText     = "截图失败"
        alert.informativeText = reason
        alert.alertStyle      = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

// Default annotation tool for a given capture shape.
private func shapeDefaultTool(_ shape: RegionSelectionShape) -> AnnotationTool {
    switch shape {
    case .rectangle: return .rectangle
    case .circle:    return .circle
    }
}
