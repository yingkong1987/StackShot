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
        commitSelectionImmediately: Bool = false,
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
            commitSelectionImmediately: commitSelectionImmediately,
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
    private enum DragMode {
        case creating
        case moving
        case resizing(SelectionEdge)
    }

    private enum SelectionEdge {
        case left
        case right
        case top
        case bottom

        var cursor: NSCursor {
            switch self {
            case .left, .right:
                return .resizeLeftRight
            case .top, .bottom:
                return .resizeUpDown
            }
        }
    }

    private let shape: RegionSelectionShape
    private let onFinish: (CGRect) -> Void
    private let onAbort: () -> Void
    private let commitSelectionImmediately: Bool

    private var dragMode: DragMode?
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var selectionRect: CGRect?
    private var selectionRectAtDragStart: CGRect?
    private var selectionRectBeforeCreating: CGRect?
    private var didDragCurrentGesture = false
    private let initialDragStartLocal: NSPoint?
    private var externalDragTimer: Timer?
    private var trackingArea: NSTrackingArea?

    private let minimumSelectionSize: CGFloat = 12
    private let committedSelectionThreshold: CGFloat = 4
    private let edgeHitInset: CGFloat = 8
    private let handleSize: CGFloat = 8
    private let controlButtonSize: CGFloat = 32
    private let controlStripPadding: CGFloat = 5
    private let controlStripGap: CGFloat = 10
    private let controlButtonSpacing: CGFloat = 8

    // Magnifier & auto-window-selection
    private let screenSnapshot: CGImage?
    private let snapshotBitmapRep: NSBitmapImageRep?
    private let windowSnapshot: WindowUnderMouseSnapshot?
    private let windowOrigin: CGPoint
    private var autoSelectedRect: CGRect?
    private var mousePosition: NSPoint = .zero
    private var hasMagnifier: Bool { screenSnapshot != nil }

    private let selectionControls = NSView(frame: .zero)
    private let cancelButton = NSButton(frame: .zero)
    private let confirmButton = NSButton(frame: .zero)

    init(
        frame frameRect: NSRect,
        shape: RegionSelectionShape,
        screenSnapshot: CGImage?,
        windowSnapshot: WindowUnderMouseSnapshot?,
        initialWindowRect: CGRect?,
        windowOrigin: CGPoint,
        initialDragStartLocal: NSPoint?,
        commitSelectionImmediately: Bool,
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
        self.commitSelectionImmediately = commitSelectionImmediately
        self.onFinish = onFinish
        self.onAbort = onAbort
        super.init(frame: frameRect)
        setupSelectionControls()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area

        super.updateTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)

        if let window = window {
            let mouse = NSEvent.mouseLocation
            mousePosition = clampedPoint(
                NSPoint(
                    x: mouse.x - window.frame.origin.x,
                    y: mouse.y - window.frame.origin.y
                )
            )
        }

        if hasMagnifier {
            updateWindowUnderMouse()
        }

        updateSelectionControls()
        updateCursorAppearance(at: mousePosition)
        needsDisplay = true

        guard let initialDragStartLocal else { return }
        beginCreatingSelection(at: clampedPoint(initialDragStartLocal), restoring: nil)
        beginExternalDragTracking()
    }

    // MARK: – Mouse events

    override func mouseMoved(with event: NSEvent) {
        mousePosition = clampedPoint(convert(event.locationInWindow, from: nil))
        if hasMagnifier, selectionRect == nil, dragMode == nil {
            updateWindowUnderMouse()
        }
        updateCursorAppearance(at: mousePosition)
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = clampedPoint(convert(event.locationInWindow, from: nil))
        updateCursorAppearance(at: point)
    }

    override func mouseDown(with event: NSEvent) {
        stopExternalDragTracking()
        window?.makeFirstResponder(self)
        let p = clampedPoint(convert(event.locationInWindow, from: nil))
        mousePosition = p
        didDragCurrentGesture = false

        if let selectionRect {
            if let edge = resizeEdge(at: p, in: selectionRect) {
                dragMode = .resizing(edge)
                startPoint = p
                currentPoint = p
                selectionRectAtDragStart = selectionRect
                updateCursorAppearance(at: p)
                needsDisplay = true
                return
            }

            if selectionRect.contains(p) {
                dragMode = .moving
                startPoint = p
                currentPoint = p
                selectionRectAtDragStart = selectionRect
                updateCursorAppearance(at: p)
                needsDisplay = true
                return
            }
        }

        beginCreatingSelection(at: p, restoring: selectionRect)
        if hasMagnifier {
            updateWindowUnderMouse()
        }
        updateCursorAppearance(at: p)
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
        let p = clampedPoint(convert(event.locationInWindow, from: nil))
        mousePosition = p
        currentPoint = p

        switch dragMode {
        case .creating:
            if let startPoint {
                let delta = CGPoint(x: p.x - startPoint.x, y: p.y - startPoint.y)
                didDragCurrentGesture = didDragCurrentGesture || hypot(delta.x, delta.y) >= 1
            }
        case .moving:
            guard let startPoint, let baseRect = selectionRectAtDragStart else { break }
            let deltaX = p.x - startPoint.x
            let deltaY = p.y - startPoint.y
            didDragCurrentGesture = didDragCurrentGesture || abs(deltaX) >= 0.5 || abs(deltaY) >= 0.5
            selectionRect = moveSelectionRect(baseRect, by: CGPoint(x: deltaX, y: deltaY))
            updateSelectionControls()
        case .resizing(let edge):
            guard let baseRect = selectionRectAtDragStart else { break }
            let resized = resizeSelectionRect(baseRect, edge: edge, to: p)
            didDragCurrentGesture = didDragCurrentGesture || resized != baseRect
            selectionRect = resized
            updateSelectionControls()
        case nil:
            break
        }

        updateCursorAppearance(at: p)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        stopExternalDragTracking()
        let p = clampedPoint(convert(event.locationInWindow, from: nil))
        mousePosition = p
        currentPoint = p

        let activeDragMode = dragMode
        dragMode = nil

        switch activeDragMode {
        case .creating:
            finalizeCreatedSelection(orRestorePrevious: true)
        case .moving:
            if !didDragCurrentGesture,
               let selectionRect,
               selectionRect.contains(p),
               event.clickCount >= 2 {
                confirmCurrentSelection()
                return
            }
            completeInteraction(at: p)
        case .resizing:
            completeInteraction(at: p)
        case nil:
            if let selectionRect,
               selectionRect.contains(p),
               event.clickCount >= 2 {
                confirmCurrentSelection()
                return
            }
        }

        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onAbort()
        } else if event.keyCode == 36 || event.keyCode == 76 {
            if selectionRect == nil,
               let autoRect = autoSelectedRect,
               autoRect.width >= committedSelectionThreshold,
               autoRect.height >= committedSelectionThreshold {
                selectionRect = autoRect
                updateSelectionControls()
                updateCursorAppearance(at: mousePosition)
                needsDisplay = true
            } else {
                confirmCurrentSelection()
            }
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
        let activeSelectionRect = currentDisplaySelectionRect()

        if let r = activeSelectionRect {
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

            if selectionRect != nil {
                drawSelectionHandles(for: r)
            }

            // Dimension label (top-left of selection)
            drawDimensionLabel(for: r)
        }

        // Magnifier
        if shouldShowMagnifier {
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
        var bgRect = CGRect(
            x: rect.minX,
            y: rect.maxY + 4,
            width: textSize.width + hPad * 2,
            height: textSize.height + vPad * 2
        )
        if bgRect.maxY > bounds.maxY - 8 {
            bgRect.origin.y = max(bounds.minY + 8, rect.minY - bgRect.height - 4)
        }
        if bgRect.maxX > bounds.maxX - 8 {
            bgRect.origin.x = bounds.maxX - bgRect.width - 8
        }
        if bgRect.minX < bounds.minX + 8 {
            bgRect.origin.x = bounds.minX + 8
        }
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

    // MARK: – Selection handles

    private func drawSelectionHandles(for rect: CGRect) {
        for handleRect in selectionHandleRects(for: rect) {
            let path = NSBezierPath(roundedRect: handleRect, xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            path.fill()

            NSColor.systemBlue.withAlphaComponent(0.95).setStroke()
            path.lineWidth = 1.2
            path.stroke()
        }
    }

    private func selectionHandleRects(for rect: CGRect) -> [CGRect] {
        let half = handleSize / 2
        return [
            CGRect(x: rect.midX - half, y: rect.maxY - half, width: handleSize, height: handleSize),
            CGRect(x: rect.midX - half, y: rect.minY - half, width: handleSize, height: handleSize),
            CGRect(x: rect.minX - half, y: rect.midY - half, width: handleSize, height: handleSize),
            CGRect(x: rect.maxX - half, y: rect.midY - half, width: handleSize, height: handleSize)
        ]
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
        let p = clampedPoint(NSPoint(x: mouse.x - window.frame.origin.x, y: mouse.y - window.frame.origin.y))
        mousePosition = p
        currentPoint = p
        updateCursorAppearance(at: p)
        needsDisplay = true

        let leftPressed = (NSEvent.pressedMouseButtons & 1) == 1
        guard !leftPressed else { return }

        stopExternalDragTracking()
        if case .creating = dragMode {
            finalizeCreatedSelection(orRestorePrevious: false)
        } else {
            completeInteraction(at: p)
        }

        needsDisplay = true
    }

    private var shouldShowMagnifier: Bool {
        hasMagnifier && selectionRect == nil
    }

    private func currentDisplaySelectionRect() -> CGRect? {
        if case .creating = dragMode,
           let startPoint,
           let currentPoint {
            let draftRect = normalizedRect(from: startPoint, to: currentPoint)
            if draftRect.width >= 2, draftRect.height >= 2 {
                return draftRect
            }
        }

        if let selectionRect {
            return selectionRect
        }

        return autoSelectedRect
    }

    private func beginCreatingSelection(at point: NSPoint, restoring previousSelection: CGRect?) {
        dragMode = .creating
        startPoint = point
        currentPoint = point
        selectionRectAtDragStart = nil
        selectionRectBeforeCreating = previousSelection
        selectionRect = nil
        didDragCurrentGesture = false
        updateSelectionControls()
    }

    private func finalizeCreatedSelection(orRestorePrevious: Bool) {
        defer {
            completeInteraction(at: mousePosition)
        }

        if let draftRect = createdSelectionRectIfValid() {
            if commitSelectionImmediately {
                onFinish(draftRect)
                return
            }
            selectionRect = draftRect
            updateSelectionControls()
            return
        }

        if hasMagnifier,
           let autoRect = autoSelectedRect,
           autoRect.width >= committedSelectionThreshold,
           autoRect.height >= committedSelectionThreshold {
            if commitSelectionImmediately {
                onFinish(autoRect)
                return
            }
            selectionRect = autoRect
            updateSelectionControls()
            return
        }

        if orRestorePrevious,
           let previousSelection = selectionRectBeforeCreating {
            selectionRect = previousSelection
            updateSelectionControls()
            return
        }

        selectionRect = nil
        updateSelectionControls()
    }

    private func createdSelectionRectIfValid() -> CGRect? {
        guard let startPoint, let currentPoint else { return nil }
        let rect = normalizedRect(from: startPoint, to: currentPoint)
        guard rect.width >= committedSelectionThreshold, rect.height >= committedSelectionThreshold else {
            return nil
        }
        return rect
    }

    private func completeInteraction(at point: NSPoint) {
        dragMode = nil
        startPoint = nil
        currentPoint = nil
        selectionRectAtDragStart = nil
        selectionRectBeforeCreating = nil
        didDragCurrentGesture = false
        updateSelectionControls()
        updateCursorAppearance(at: point)
    }

    private func confirmCurrentSelection() {
        guard let selectionRect,
              selectionRect.width >= committedSelectionThreshold,
              selectionRect.height >= committedSelectionThreshold else {
            return
        }
        onFinish(selectionRect)
    }

    private func resizeEdge(at point: CGPoint, in rect: CGRect) -> SelectionEdge? {
        guard rect.insetBy(dx: -edgeHitInset, dy: -edgeHitInset).contains(point) else {
            return nil
        }

        var candidates: [(SelectionEdge, CGFloat)] = []
        if point.y >= rect.minY - edgeHitInset, point.y <= rect.maxY + edgeHitInset {
            let leftDistance = abs(point.x - rect.minX)
            if leftDistance <= edgeHitInset {
                candidates.append((.left, leftDistance))
            }

            let rightDistance = abs(point.x - rect.maxX)
            if rightDistance <= edgeHitInset {
                candidates.append((.right, rightDistance))
            }
        }

        if point.x >= rect.minX - edgeHitInset, point.x <= rect.maxX + edgeHitInset {
            let bottomDistance = abs(point.y - rect.minY)
            if bottomDistance <= edgeHitInset {
                candidates.append((.bottom, bottomDistance))
            }

            let topDistance = abs(point.y - rect.maxY)
            if topDistance <= edgeHitInset {
                candidates.append((.top, topDistance))
            }
        }

        return candidates.min(by: { $0.1 < $1.1 })?.0
    }

    private func moveSelectionRect(_ rect: CGRect, by delta: CGPoint) -> CGRect {
        var moved = rect.offsetBy(dx: delta.x, dy: delta.y)

        if moved.minX < bounds.minX {
            moved.origin.x = bounds.minX
        }
        if moved.maxX > bounds.maxX {
            moved.origin.x = bounds.maxX - moved.width
        }
        if moved.minY < bounds.minY {
            moved.origin.y = bounds.minY
        }
        if moved.maxY > bounds.maxY {
            moved.origin.y = bounds.maxY - moved.height
        }

        return moved
    }

    private func resizeSelectionRect(_ rect: CGRect, edge: SelectionEdge, to point: CGPoint) -> CGRect {
        var resized = rect

        switch edge {
        case .left:
            let maxLeft = rect.maxX - minimumSelectionSize
            resized.origin.x = min(max(point.x, bounds.minX), maxLeft)
            resized.size.width = rect.maxX - resized.minX
        case .right:
            let minRight = rect.minX + minimumSelectionSize
            let clampedRight = max(min(point.x, bounds.maxX), minRight)
            resized.size.width = clampedRight - rect.minX
        case .bottom:
            let maxBottom = rect.maxY - minimumSelectionSize
            resized.origin.y = min(max(point.y, bounds.minY), maxBottom)
            resized.size.height = rect.maxY - resized.minY
        case .top:
            let minTop = rect.minY + minimumSelectionSize
            let clampedTop = max(min(point.y, bounds.maxY), minTop)
            resized.size.height = clampedTop - rect.minY
        }

        return resized
    }

    private func clampedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private func updateCursorAppearance(at point: CGPoint) {
        if case .moving = dragMode {
            NSCursor.closedHand.set()
            return
        }

        if case let .resizing(edge) = dragMode {
            edge.cursor.set()
            return
        }

        if let selectionRect,
           let edge = resizeEdge(at: point, in: selectionRect) {
            edge.cursor.set()
            return
        }

        if let selectionRect,
           selectionRect.contains(point) {
            NSCursor.openHand.set()
            return
        }

        NSCursor.crosshair.set()
    }

    private func setupSelectionControls() {
        selectionControls.wantsLayer = true
        selectionControls.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        selectionControls.layer?.cornerRadius = 11
        selectionControls.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        selectionControls.layer?.borderWidth = 1
        selectionControls.isHidden = true

        configureControlButton(
            cancelButton,
            symbolName: "xmark",
            tintColor: .systemRed,
            action: #selector(handleCancelButton)
        )
        configureControlButton(
            confirmButton,
            symbolName: "checkmark",
            tintColor: .systemGreen,
            action: #selector(handleConfirmButton)
        )

        selectionControls.addSubview(cancelButton)
        selectionControls.addSubview(confirmButton)
        addSubview(selectionControls)
    }

    private func configureControlButton(
        _ button: NSButton,
        symbolName: String,
        tintColor: NSColor,
        action: Selector
    ) {
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = tintColor
        button.target = self
        button.action = action
        button.wantsLayer = true
        button.layer?.backgroundColor = tintColor.withAlphaComponent(0.16).cgColor
        button.layer?.cornerRadius = 9
        button.layer?.borderColor = tintColor.withAlphaComponent(0.28).cgColor
        button.layer?.borderWidth = 1
    }

    private func updateSelectionControls() {
        guard let selectionRect else {
            selectionControls.isHidden = true
            return
        }

        selectionControls.isHidden = false
        let stripWidth = controlStripPadding * 2 + controlButtonSize * 2 + controlButtonSpacing
        let stripHeight = controlStripPadding * 2 + controlButtonSize

        let placeBelow = selectionRect.minY - stripHeight - controlStripGap >= bounds.minY + 8
        let preferredY = placeBelow
            ? selectionRect.minY - stripHeight - controlStripGap
            : selectionRect.maxY + controlStripGap
        let minX = bounds.minX + 8
        let maxX = bounds.maxX - stripWidth - 8
        let originX = min(max(selectionRect.midX - stripWidth / 2, minX), maxX)
        let originY = min(max(preferredY, bounds.minY + 8), bounds.maxY - stripHeight - 8)

        selectionControls.frame = CGRect(x: originX, y: originY, width: stripWidth, height: stripHeight)
        cancelButton.frame = CGRect(
            x: controlStripPadding,
            y: controlStripPadding,
            width: controlButtonSize,
            height: controlButtonSize
        )
        confirmButton.frame = CGRect(
            x: cancelButton.frame.maxX + controlButtonSpacing,
            y: controlStripPadding,
            width: controlButtonSize,
            height: controlButtonSize
        )
    }

    @objc private func handleCancelButton() {
        onAbort()
    }

    @objc private func handleConfirmButton() {
        confirmCurrentSelection()
    }
}
