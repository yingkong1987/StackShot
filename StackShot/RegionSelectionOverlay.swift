import AppKit
import CoreGraphics

enum RegionSelectionShape {
    case rectangle
    case circle
}

/// 全屏半透明遮罩 + 拖拽选取 + 放大镜 + 色值取色器；Esc/右键取消。
final class RegionSelectionOverlay: NSWindow {
    override var canBecomeKey: Bool { true }

    init(
        shape: RegionSelectionShape,
        screenSnapshot: CGImage? = nil,
        windowSnapshot: WindowUnderMouseSnapshot? = nil,
        initialWindowRect: CGRect? = nil,
        initialDragStartGlobal: CGPoint? = nil,
        onComplete: @escaping (CGRect, RegionSelectionShape) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let union = Self.unionScreenFrame()
        super.init(contentRect: union, styleMask: [.borderless], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = false
        hasShadow = false

        let view = SelectionOverlayView(
            frame: NSRect(origin: .zero, size: union.size),
            shape: shape,
            screenSnapshot: screenSnapshot,
            windowSnapshot: windowSnapshot,
            initialWindowRect: initialWindowRect.map { globalRect in
                CGRect(
                    x: globalRect.origin.x - union.origin.x,
                    y: globalRect.origin.y - union.origin.y,
                    width: globalRect.width,
                    height: globalRect.height
                )
            },
            windowOrigin: union.origin,
            initialDragStartLocal: initialDragStartGlobal.map { global in
                CGPoint(x: global.x - union.origin.x, y: global.y - union.origin.y)
            },
            onFinish: { [weak self] localRect in
                guard let self else { return }
                let global = localRect.offsetBy(dx: self.frame.origin.x, dy: self.frame.origin.y)
                onComplete(global, shape)
            },
            onAbort: onCancel
        )
        contentView = view
    }

    func prepareForCapture() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(contentView)
    }

    private static func unionScreenFrame() -> CGRect {
        var u = CGRect.null
        for s in NSScreen.screens {
            u = u.union(s.frame)
        }
        return u
    }
}

// MARK: – Selection Overlay View

private final class SelectionOverlayView: NSView {
    private let shape: RegionSelectionShape
    private let onFinish: (CGRect) -> Void
    private let onAbort: () -> Void

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private let initialDragStartLocal: NSPoint?
    private var externalDragTimer: Timer?

    // Magnifier & auto-window-selection
    private let screenSnapshot: CGImage?
    private let snapshotBitmapRep: NSBitmapImageRep?
    private let windowSnapshot: WindowUnderMouseSnapshot?
    private let windowOrigin: CGPoint
    private var autoSelectedRect: CGRect?
    private var mousePosition: NSPoint = .zero
    private var hasMagnifier: Bool { screenSnapshot != nil }

    init(
        frame frameRect: NSRect,
        shape: RegionSelectionShape,
        screenSnapshot: CGImage?,
        windowSnapshot: WindowUnderMouseSnapshot?,
        initialWindowRect: CGRect?,
        windowOrigin: CGPoint,
        initialDragStartLocal: NSPoint?,
        onFinish: @escaping (CGRect) -> Void,
        onAbort: @escaping () -> Void
    ) {
        self.shape = shape
        self.screenSnapshot = screenSnapshot
        self.snapshotBitmapRep = screenSnapshot.map { NSBitmapImageRep(cgImage: $0) }
        self.windowSnapshot = windowSnapshot
        self.windowOrigin = windowOrigin
        self.autoSelectedRect = initialWindowRect
        self.initialDragStartLocal = initialDragStartLocal
        self.onFinish = onFinish
        self.onAbort = onAbort
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)

        if hasMagnifier {
            let trackingArea = NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)

            if let window = window {
                let mouse = NSEvent.mouseLocation
                mousePosition = NSPoint(
                    x: mouse.x - window.frame.origin.x,
                    y: mouse.y - window.frame.origin.y
                )
            }

            // 遮罩刚出现时立即同步一次鼠标下的窗口，恢复默认高亮。
            updateWindowUnderMouse()
        }

        needsDisplay = true

        guard let initialDragStartLocal else { return }
        startPoint = initialDragStartLocal
        currentPoint = initialDragStartLocal
        needsDisplay = true
        beginExternalDragTracking()
    }

    // MARK: – Mouse events

    override func mouseMoved(with event: NSEvent) {
        mousePosition = convert(event.locationInWindow, from: nil)
        if hasMagnifier && startPoint == nil {
            updateWindowUnderMouse()
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        stopExternalDragTracking()
        let p = convert(event.locationInWindow, from: nil)
        mousePosition = p
        startPoint = p
        currentPoint = p
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        onAbort()
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber != 0 {
            onAbort()
        } else {
            super.otherMouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mousePosition = p
        currentPoint = p
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        stopExternalDragTracking()
        let p = convert(event.locationInWindow, from: nil)
        mousePosition = p
        currentPoint = p
        defer { startPoint = nil; currentPoint = nil; needsDisplay = true }

        guard let s = startPoint, let e = currentPoint else { return }
        let r = normalizedRect(from: s, to: e)
        if r.width >= 4, r.height >= 4 {
            onFinish(r)
        } else if hasMagnifier,
                  let autoRect = autoSelectedRect,
                  autoRect.width >= 4, autoRect.height >= 4 {
            // 小范围点击 → 确认自动选中的窗口
            onFinish(autoRect)
        } else {
            onAbort()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onAbort()
        } else if hasMagnifier,
                  event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "c" {
            copyColorToClipboard()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: – Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.42).setFill()
        NSBezierPath(rect: bounds).fill()

        // Determine active selection rect
        let selectionRect: CGRect?
        if let s = startPoint, let c = currentPoint {
            let r = normalizedRect(from: s, to: c)
            selectionRect = (r.width >= 2 && r.height >= 2) ? r : autoSelectedRect
        } else {
            selectionRect = autoSelectedRect
        }

        if let r = selectionRect {
            // Clear hole
            NSGraphicsContext.saveGraphicsState()
            if shape == .circle {
                NSBezierPath(ovalIn: r).addClip()
            } else {
                NSBezierPath(rect: r).addClip()
            }
            NSGraphicsContext.current?.compositingOperation = .clear
            NSColor.clear.setFill()
            NSBezierPath(rect: bounds).fill()
            NSGraphicsContext.restoreGraphicsState()

            // Border
            NSGraphicsContext.saveGraphicsState()
            let path: NSBezierPath
            if shape == .circle {
                path = NSBezierPath(ovalIn: r)
            } else {
                path = NSBezierPath(rect: r)
            }
            path.lineWidth = 2
            NSColor.systemBlue.withAlphaComponent(0.95).setStroke()
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()

            // Dimension label (top-left of selection)
            if hasMagnifier {
                drawDimensionLabel(for: r)
            }
        }

        // Magnifier
        if hasMagnifier {
            drawMagnifier()
        }
    }

    // MARK: – Dimension label

    private func drawDimensionLabel(for rect: CGRect) {
        let w = Int(rect.width)
        let h = Int(rect.height)
        let text = "\(w) × \(h)"

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let hPad: CGFloat = 6
        let vPad: CGFloat = 3
        let bgRect = CGRect(
            x: rect.minX,
            y: rect.maxY + 4,
            width: textSize.width + hPad * 2,
            height: textSize.height + vPad * 2
        )
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(
            at: NSPoint(x: bgRect.minX + hPad, y: bgRect.minY + vPad),
            withAttributes: attrs
        )
    }

    // MARK: – Magnifier

    private func drawMagnifier() {
        guard let snapshot = screenSnapshot else { return }

        let zoomSize: CGFloat = 130
        let pixelCount = 15
        let cellSize = zoomSize / CGFloat(pixelCount)
        let padding: CGFloat = 12
        let infoLineH: CGFloat = 18
        let panelWidth = zoomSize + padding * 2
        let panelHeight = zoomSize + padding + 10 + infoLineH * 3 + padding

        // Position: bottom-right of cursor
        var origin = CGPoint(
            x: mousePosition.x + 24,
            y: mousePosition.y - panelHeight - 24
        )
        if origin.x + panelWidth > bounds.maxX - 10 {
            origin.x = mousePosition.x - panelWidth - 24
        }
        if origin.y < bounds.minY + 10 {
            origin.y = mousePosition.y + 24
        }
        if origin.x < bounds.minX + 10 {
            origin.x = bounds.minX + 10
        }

        let panelRect = CGRect(origin: origin, size: CGSize(width: panelWidth, height: panelHeight))

        // Background
        let bgPath = NSBezierPath(roundedRect: panelRect, xRadius: 10, yRadius: 10)
        NSColor.black.withAlphaComponent(0.82).setFill()
        bgPath.fill()

        // Zoom area (top of panel)
        let zoomRect = CGRect(
            x: panelRect.minX + padding,
            y: panelRect.maxY - padding - zoomSize,
            width: zoomSize,
            height: zoomSize
        )

        // Map mouse → snapshot pixel coordinates
        let scaleX = CGFloat(snapshot.width) / bounds.width
        let scaleY = CGFloat(snapshot.height) / bounds.height
        let pixelCenterX = min(max(Int(round(mousePosition.x * scaleX)), 0), snapshot.width - 1)
        let pixelCenterY = min(max(Int(round((bounds.height - mousePosition.y) * scaleY)), 0), snapshot.height - 1)
        let sampleSize = min(pixelCount, min(snapshot.width, snapshot.height))
        let halfPixels = sampleSize / 2
        let originX = min(max(pixelCenterX - halfPixels, 0), snapshot.width - sampleSize)
        let originY = min(max(pixelCenterY - halfPixels, 0), snapshot.height - sampleSize)
        let srcRect = CGRect(
            x: originX,
            y: originY,
            width: sampleSize,
            height: sampleSize
        )

        // Draw zoomed pixels (nearest-neighbor for pixel-art effect)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: zoomRect, xRadius: 6, yRadius: 6).addClip()

        if let subImage = snapshot.cropping(to: srcRect) {
            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.interpolationQuality = .none
            ctx?.draw(subImage, in: zoomRect)
        }

        // Crosshair
        let centerX = zoomRect.midX
        let centerY = zoomRect.midY
        NSColor.green.withAlphaComponent(0.85).setStroke()

        let vLine = NSBezierPath()
        vLine.move(to: NSPoint(x: centerX, y: zoomRect.minY))
        vLine.line(to: NSPoint(x: centerX, y: zoomRect.maxY))
        vLine.lineWidth = 1.5
        vLine.stroke()

        let hLine = NSBezierPath()
        hLine.move(to: NSPoint(x: zoomRect.minX, y: centerY))
        hLine.line(to: NSPoint(x: zoomRect.maxX, y: centerY))
        hLine.lineWidth = 1.5
        hLine.stroke()

        // Center pixel outline
        let cellRect = CGRect(
            x: centerX - cellSize / 2,
            y: centerY - cellSize / 2,
            width: cellSize,
            height: cellSize
        )
        let cellPath = NSBezierPath(rect: cellRect)
        cellPath.lineWidth = 1.5
        cellPath.stroke()

        NSGraphicsContext.restoreGraphicsState()

        // Color at cursor
        var hexColor = "#000000"
                if let rep = snapshotBitmapRep,
                     let color = rep.colorAt(x: pixelCenterX, y: pixelCenterY)?.usingColorSpace(.sRGB) {
            let r = Int(color.redComponent * 255)
            let g = Int(color.greenComponent * 255)
            let b = Int(color.blueComponent * 255)
            hexColor = String(format: "#%02X%02X%02X", r, g, b)
        }

        // Screen coordinates (Quartz: origin at top-left)
        let desktopBounds = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
                let globalX = Int(round(mousePosition.x + windowOrigin.x))
                let globalY = Int(round(desktopBounds.maxY - (mousePosition.y + windowOrigin.y)))

        // Text attributes
        let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let valueFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let hintFont = NSFont.systemFont(ofSize: 10, weight: .regular)
        let dimWhite = NSColor.white.withAlphaComponent(0.55)
        let brightWhite = NSColor.white

        let labelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: dimWhite]
        let valueAttrs: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: brightWhite]
        let hintAttrs: [NSAttributedString.Key: Any] = [.font: hintFont, .foregroundColor: dimWhite]

        let textX = panelRect.minX + padding
        let valueX = textX + 38
        var textY = zoomRect.minY - 10 - infoLineH + 4

        // Coordinates
        let coordLabel = L10n.tr("magnifier.coordinates")
        (coordLabel as NSString).draw(at: NSPoint(x: textX, y: textY), withAttributes: labelAttrs)
        ("\(globalX), \(globalY)" as NSString).draw(at: NSPoint(x: valueX, y: textY), withAttributes: valueAttrs)

        textY -= infoLineH

        // Color value
        let colorLabel = L10n.tr("magnifier.color")
        (colorLabel as NSString).draw(at: NSPoint(x: textX, y: textY), withAttributes: labelAttrs)
        (hexColor as NSString).draw(at: NSPoint(x: valueX, y: textY), withAttributes: valueAttrs)

        textY -= infoLineH

        // Copy hint
        let hintText = L10n.tr("magnifier.copy_hint")
        (hintText as NSString).draw(at: NSPoint(x: textX, y: textY), withAttributes: hintAttrs)
    }

    // MARK: – Window tracking

    private func updateWindowUnderMouse() {
        let globalPoint = CGPoint(x: mousePosition.x + windowOrigin.x, y: mousePosition.y + windowOrigin.y)
        let info = WindowUnderMouseService.window(at: globalPoint, snapshot: windowSnapshot)
        if let b = info?.bounds {
            autoSelectedRect = CGRect(
                x: b.origin.x - windowOrigin.x,
                y: b.origin.y - windowOrigin.y,
                width: b.width,
                height: b.height
            )
        } else {
            autoSelectedRect = nil
        }
    }

    // MARK: – Color copy

    private func copyColorToClipboard() {
        guard let snapshot = screenSnapshot, let rep = snapshotBitmapRep else { return }

        let scaleX = CGFloat(snapshot.width) / bounds.width
        let scaleY = CGFloat(snapshot.height) / bounds.height
        let px = Int(mousePosition.x * scaleX)
        let py = Int((bounds.height - mousePosition.y) * scaleY)

        guard px >= 0, px < snapshot.width, py >= 0, py < snapshot.height,
              let color = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { return }

        let r = Int(color.redComponent * 255)
        let g = Int(color.greenComponent * 255)
        let b = Int(color.blueComponent * 255)
        let hex = String(format: "#%02X%02X%02X", r, g, b)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
    }

    // MARK: – Helpers

    private func normalizedRect(from a: NSPoint, to b: NSPoint) -> CGRect {
        let x = min(a.x, b.x)
        let y = min(a.y, b.y)
        let w = abs(b.x - a.x)
        let h = abs(b.y - a.y)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    deinit {
        stopExternalDragTracking()
    }

    private func beginExternalDragTracking() {
        stopExternalDragTracking()
        externalDragTimer = Timer.scheduledTimer(withTimeInterval: 1 / 120, repeats: true) { [weak self] _ in
            self?.trackExternalDragTick()
        }
    }

    private func stopExternalDragTracking() {
        externalDragTimer?.invalidate()
        externalDragTimer = nil
    }

    private func trackExternalDragTick() {
        guard let window else { return }

        let mouse = NSEvent.mouseLocation
        let p = NSPoint(x: mouse.x - window.frame.origin.x, y: mouse.y - window.frame.origin.y)
        mousePosition = p
        currentPoint = p
        needsDisplay = true

        let leftPressed = (NSEvent.pressedMouseButtons & 1) == 1
        guard !leftPressed else { return }

        stopExternalDragTracking()
        defer { startPoint = nil; currentPoint = nil; needsDisplay = true }

        guard let s = startPoint, let e = currentPoint else {
            onAbort()
            return
        }

        let r = normalizedRect(from: s, to: e)
        if r.width >= 4, r.height >= 4 {
            onFinish(r)
        } else {
            onAbort()
        }
    }
}
