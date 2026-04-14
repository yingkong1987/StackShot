import AppKit
import CoreGraphics

/// 协调高亮边框、工具条与区域选取流程。
final class CaptureSessionController {
    static let shared = CaptureSessionController()

    private var highlight: HighlightBorderWindow?
    private var toolbar: FloatingToolbarPanel?
    private var overlay: RegionSelectionOverlay?
    private var currentHoveredWindow: WindowUnderMouseInfo?
    private var hoverTimer: Timer?
    private var globalClickMonitor: Any?

    private init() {}

    func activateFromHotkey() {
        endSession()
        NSApp.activate(ignoringOtherApps: true)
        beginHoverTracking()
        refreshHoveredWindow(force: true)
    }

    private func presentEmoji() {
        NSApp.orderFrontCharacterPalette(nil)
    }

    private func startSelection(_ shape: RegionSelectionShape) {
        endHoverTracking()
        highlight?.orderOut(nil)
        toolbar?.orderOut(nil)
        
        guard ensureScreenCapturePermission() else {
            endSession()
            return
        }

        let sheet = RegionSelectionOverlay(
            shape: shape,
            onComplete: { [weak self] rect, sh in
                self?.handleCaptured(rect: rect, shape: sh)
            },
            onCancel: { [weak self] in
                self?.endSession()
            }
        )
        sheet.prepareForCapture()
        overlay = sheet
    }

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

        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
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

        if let highlight {
            highlight.setFrame(info.bounds, display: true)
            highlight.orderFrontRegardless()
        } else {
            let newHighlight = HighlightBorderWindow(frame: info.bounds)
            newHighlight.orderFrontRegardless()
            highlight = newHighlight
        }

        if let toolbar {
            toolbar.reposition(anchorFrame: info.bounds)
            toolbar.orderFrontRegardless()
        } else {
            let tb = FloatingToolbarPanel(
                anchorFrame: info.bounds,
                onCircle: { [weak self] in self?.startSelection(.circle) },
                onRect: { [weak self] in self?.startSelection(.rectangle) },
                onEmoji: { [weak self] in self?.presentEmoji() }
            )
            tb.orderFrontRegardless()
            toolbar = tb
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard event.clickCount >= 2 else { return }
        guard overlay == nil else { return }
        captureCurrentHoveredWindowByDoubleClick()
    }

    private func captureCurrentHoveredWindowByDoubleClick() {
        guard ensureScreenCapturePermission() else {
            endSession()
            return
        }
        guard let info = currentHoveredWindow ?? WindowUnderMouseService.windowUnderMouse() else { return }
        defer { endSession() }

        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            info.windowID,
            .bestResolution
        ) else {
            showCaptureFailedAlert(reason: "窗口截图失败，可能被系统隐私设置阻止。")
            return
        }

        let imageSize = NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        let image = NSImage(cgImage: cgImage, size: imageSize)
        writeToPasteboard(image)
    }

    private func ensureScreenCapturePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        // 避免在当前环境调用 CGRequestScreenCaptureAccess 引发崩溃，
        // 仅进行预检查并跳转系统设置，由用户手动授权。
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        NSSound.beep()
        return false
    }

    private func handleCaptured(rect: CGRect, shape: RegionSelectionShape) {
        defer { endSession() }

        guard rect.width >= 2, rect.height >= 2 else { return }

        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2.0
        let snapped = CGRect(
            x: floor(rect.origin.x * scale) / scale,
            y: floor(rect.origin.y * scale) / scale,
            width: ceil(rect.width * scale) / scale,
            height: ceil(rect.height * scale) / scale
        )

        guard let cgImage = CGWindowListCreateImage(
            snapped,
            .optionOnScreenOnly,
            kCGNullWindowID,
            .bestResolution
        ) else {
            showCaptureFailedAlert(reason: "无法创建图像，可能被系统隐私设置阻止。")
            return
        }

        if cgImage.width <= 1 || cgImage.height <= 1 {
            showCaptureFailedAlert(reason: "截图为空。请在「系统设置 → 隐私与安全性 → 屏幕录制」中允许 StackShot。")
            return
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: snapped.width, height: snapped.height))

        let output: NSImage
        switch shape {
        case .rectangle:
            output = nsImage
        case .circle:
            output = Self.applyCircularMask(to: nsImage) ?? nsImage
        }
        writeToPasteboard(output)
    }

    private static func applyCircularMask(to image: NSImage) -> NSImage? {
        let size = image.size
        guard size.width > 1, size.height > 1 else { return nil }
        let img = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect)
            path.addClip()
            image.draw(in: rect, from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1)
            return true
        }
        return img
    }

    private func showCaptureFailedAlert(reason: String) {
        let alert = NSAlert()
        alert.messageText = "截图失败"
        alert.informativeText = reason
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func writeToPasteboard(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.writeObjects([image]) {
            NSSound.beep()
        }
    }

    func endSession() {
        endHoverTracking()
        currentHoveredWindow = nil
        overlay?.close()
        overlay = nil
        toolbar?.close()
        toolbar = nil
        highlight?.close()
        highlight = nil
    }
}
