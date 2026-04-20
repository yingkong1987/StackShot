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
    private var dragAnchorPoint: CGPoint?
    private var preparedScreenSnapshot: CGImage?
    private var preparedDesktopBounds: CGRect?
    private var didRequestScreenCaptureThisLaunch = false
    private var didShowScreenCaptureAlertThisLaunch = false

    private init() {}

    // MARK: – Public entry

    func activateFromHotkey() {
        guard ensureScreenCapturePermission(interactive: true) else {
            endSession()
            return
        }
        annotationEditor?.orderOut(nil)
        annotationEditor?.close()
        annotationEditor = nil
        dismissHoverUI()

        // 在显示遮罩前冻结全屏快照（供放大镜使用）和当前窗口顺序（供 hover 命中使用）。
        let screenSnapshot = prepareSessionSnapshot()
        let windowSnapshot = WindowUnderMouseService.captureSnapshot()
        let windowInfo = WindowUnderMouseService.windowUnderMouse(snapshot: windowSnapshot)

        NSApp.activate(ignoringOtherApps: true)

        let overlayWindow = RegionSelectionOverlay(
            shape: .rectangle,
            screenSnapshot: screenSnapshot,
            windowSnapshot: windowSnapshot,
            initialWindowRect: windowInfo?.bounds,
            commitSelectionImmediately: true,
            onComplete: { [weak self] rect, shape in
                self?.handleCaptured(rect: rect, shape: shape, initialTool: nil)
            },
            onCancel: { [weak self] in self?.endSession() }
        )
        overlayWindow.prepareForCapture()
        overlay = overlayWindow
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
        handleHoverDragSelection()
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
        // 悬停阶段只展示高亮，不展示工具栏；
        // 工具栏会在确认框选并进入编辑卡后显示。
        toolbar?.orderOut(nil)
        toolbar = nil
    }

    private func handleHoverDragSelection() {
        let leftPressed = (NSEvent.pressedMouseButtons & 1) == 1
        let cursor = NSEvent.mouseLocation

        guard leftPressed else {
            dragAnchorPoint = nil
            return
        }

        if dragAnchorPoint == nil {
            dragAnchorPoint = cursor
            return
        }

        guard
            let anchor = dragAnchorPoint,
            hypot(cursor.x - anchor.x, cursor.y - anchor.y) >= 4
        else {
            return
        }

        dragAnchorPoint = nil
        startSelection(
            .rectangle,
            initialDragStart: anchor,
            initialTool: nil,
            useShapeDefaultTool: false
        )
    }

    // MARK: – Double-click whole window

    private func handleMouseDown(_ event: NSEvent) {
        guard event.clickCount >= 2, overlay == nil else { return }
        captureCurrentHoveredWindowByDoubleClick()
    }

    private func captureCurrentHoveredWindowByDoubleClick() {
        guard ensureScreenCapturePermission(interactive: false) else { endSession(); return }
        guard let info = currentHoveredWindow ?? WindowUnderMouseService.windowUnderMouse() else { return }

        if info.windowID == 0 {
            let rect = Self.quartzRect(fromAppKitRect: info.bounds)
            guard let cgImage = CGWindowListCreateImage(
                rect, .optionOnScreenOnly, kCGNullWindowID, .bestResolution
            ) else {
                showCaptureFailedAlert(reason: "窗口截图失败，可能被系统隐私设置阻止。")
                endSession()
                return
            }

            let image = NSImage(cgImage: cgImage,
                                size: NSSize(width: info.bounds.width, height: info.bounds.height))
            dismissHoverUI()
            showAnnotationEditor(for: image, initialTool: nil)
            return
        }

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
        showAnnotationEditor(for: image, initialTool: nil)
    }

    // MARK: – Region selection

    /// Start drag-to-select for the chosen shape.
    private func startSelection(
        _ shape: RegionSelectionShape,
        initialDragStart: CGPoint? = nil,
        initialTool: AnnotationTool? = nil,
        useShapeDefaultTool: Bool = true
    ) {
        guard ensureScreenCapturePermission(interactive: false) else { endSession(); return }
        endHoverTracking()
        highlight?.orderOut(nil)
        toolbar?.orderOut(nil)

        let screenSnapshot = prepareSessionSnapshot()

        let overlayWindow = RegionSelectionOverlay(
            shape: shape,
            screenSnapshot: screenSnapshot,
            initialDragStartGlobal: initialDragStart,
            commitSelectionImmediately: true,
            onComplete: { [weak self] rect, sh in
                let tool = useShapeDefaultTool ? (initialTool ?? shapeDefaultTool(sh)) : initialTool
                self?.handleCaptured(rect: rect, shape: sh, initialTool: tool)
            },
            onCancel: { [weak self] in self?.endSession() }
        )
        overlayWindow.prepareForCapture()
        overlay = overlayWindow
    }

    /// Capture a rectangular region and open the editor with a specific initial tool.
    private func captureAndOpenEditor(initialTool: AnnotationTool? = nil) {
        guard ensureScreenCapturePermission(interactive: false) else { endSession(); return }
        endHoverTracking()
        highlight?.orderOut(nil)
        toolbar?.orderOut(nil)

        let screenSnapshot = prepareSessionSnapshot()

        let overlayWindow = RegionSelectionOverlay(
            shape: .rectangle,
            screenSnapshot: screenSnapshot,
            commitSelectionImmediately: true,
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
                                 initialTool: AnnotationTool? = nil) {
        // NOTE: Do NOT use defer { endSession() } here.  endSession() calls orderOut / nil on
        // overlay/toolbar/highlight while the AnnotationEditorPanel is animating in; that causes
        // _NSWindowTransformAnimation to hold dangling pointers → crash in objc_release.
        guard rect.width >= 2, rect.height >= 2 else { endSession(); return }

        // 先隐藏遮罩层，避免放大镜等 UI 出现在截图结果中。
        overlay?.orderOut(nil)

        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2.0
        let snappedAppKit = CGRect(
            x: floor(rect.origin.x * scale) / scale,
            y: floor(rect.origin.y * scale) / scale,
            width:  ceil(rect.width  * scale) / scale,
            height: ceil(rect.height * scale) / scale
        )
        let snappedQuartz = Self.quartzRect(fromAppKitRect: snappedAppKit)

        guard let cgImage = CGWindowListCreateImage(
            snappedQuartz, .optionOnScreenOnly, kCGNullWindowID, .bestResolution
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
                              size: NSSize(width: snappedAppKit.width, height: snappedAppKit.height))
        if shape == .circle {
            nsImage = Self.applyCircularMask(to: nsImage) ?? nsImage
        }

        dismissHoverUI()
        showAnnotationEditor(for: nsImage, initialTool: initialTool, captureRect: snappedAppKit)
    }

    private func showAnnotationEditor(for image: NSImage,
                                      initialTool: AnnotationTool? = nil,
                                      captureRect: CGRect? = nil) {
        let editor = AnnotationEditorPanel(
            screenshot: image,
            initialTool: initialTool,
            captureRect: captureRect,
            sourceScreenSnapshot: preparedScreenSnapshot,
            sourceDesktopBounds: preparedDesktopBounds
        )
        editor.onConfirm = { [weak self] _ in self?.annotationEditor = nil }
        editor.onCancel  = { [weak self] in   self?.annotationEditor = nil }
        preparedScreenSnapshot = nil
        preparedDesktopBounds = nil
        NSApp.activate(ignoringOtherApps: true)
        editor.orderFrontRegardless()
        editor.makeKeyAndOrderFront(nil)
        annotationEditor = editor
    }

    /// Replace the current annotation editor (used by scroll capture to swap in the stitched result).
    func replaceEditor(_ editor: AnnotationEditorPanel) {
        annotationEditor?.orderOut(nil)
        editor.onConfirm = { [weak self] _ in self?.annotationEditor = nil }
        editor.onCancel  = { [weak self] in   self?.annotationEditor = nil }
        annotationEditor = editor
    }

    // MARK: – Utilities

    /// Hide and nil all hover-phase windows using orderOut (no close animation) to
    /// avoid CoreAnimation conflicts when showing the annotation editor immediately after.
    private func dismissHoverUI() {
        endHoverTracking()
        dragAnchorPoint = nil
        currentHoveredWindow = nil
        overlay?.orderOut(nil);   overlay   = nil
        toolbar?.orderOut(nil);   toolbar   = nil
        highlight?.orderOut(nil); highlight = nil
    }

    func endSession() {
        dismissHoverUI()
        preparedScreenSnapshot = nil
        preparedDesktopBounds = nil
        // Annotation editor manages its own lifecycle via onConfirm / onCancel.
    }

    private func prepareSessionSnapshot() -> CGImage? {
        let snapshot = CGWindowListCreateImage(
            .infinite,
            .optionOnScreenOnly,
            kCGNullWindowID,
            .bestResolution
        )
        preparedScreenSnapshot = snapshot
        preparedDesktopBounds = Self.desktopBounds()
        return snapshot
    }

    private func ensureScreenCapturePermission(interactive: Bool) -> Bool {
        #if DEBUG
        // 调试模式下默认放行，避免频繁权限弹窗打断开发流程。
        return true
        #else
        if CGPreflightScreenCaptureAccess() {
            didShowScreenCaptureAlertThisLaunch = false
            return true
        }

        // 非交互检查只返回权限状态，不主动弹系统权限请求和提示。
        guard interactive else { return false }

        // 同一次应用运行周期内只展示一次引导，避免每次截图都打断。
        if didShowScreenCaptureAlertThisLaunch {
            return false
        }
        didShowScreenCaptureAlertThisLaunch = true

        // Show a clear guide so the user knows exactly what to do.
        let alert = NSAlert()
        alert.messageText     = "需要屏幕录制权限"
        alert.informativeText = """
            请按以下步骤操作：
            1. 点击「打开系统设置」
            2. 在「屏幕录制」列表中找到 StackShot，开启开关
            3. 若你已开启权限但仍提示，请先完全退出并重新打开 StackShot
            4. 重新按下快捷键 Shift + Command + A 即可截图
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if !didRequestScreenCaptureThisLaunch {
                CGRequestScreenCaptureAccess()
                didRequestScreenCaptureThisLaunch = true
            }
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

    private static func quartzRect(fromAppKitRect rect: CGRect) -> CGRect {
        let desktopBounds = desktopBounds()
        guard desktopBounds.isNull == false else { return rect }

        return CGRect(
            x: rect.origin.x,
            y: desktopBounds.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private static func desktopBounds() -> CGRect {
        NSScreen.screens.reduce(CGRect.null) { partial, screen in
            partial.union(screen.frame)
        }
    }

    private func showCaptureFailedAlert(reason: String) {
        // Ensure alert is visible above capture overlays/highlight windows.
        dismissHoverUI()
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText     = "截图失败"
        alert.informativeText = reason
        alert.alertStyle      = .informational
        alert.addButton(withTitle: "好")
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
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
