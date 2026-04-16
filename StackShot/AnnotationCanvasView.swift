import AppKit
import CoreImage

/// Custom NSView that renders a screenshot and interactive annotation layer.
final class AnnotationCanvasView: NSView {

    // MARK: – Public state

    var screenshot: NSImage {
        didSet { needsDisplay = true }
    }
    var annotations: [AnnotationItem] = [] {
        didSet { needsDisplay = true }
    }
    var currentTool: AnnotationTool?
    var styleProvider: ((AnnotationTool) -> AnnotationToolStyle)?

    /// Called when a crop operation completes – supplies the new logical size.
    var onCropCompleted: ((NSSize) -> Void)?

    // MARK: – Private drawing state

    private var dragStart:   NSPoint?
    private var dragCurrent: NSPoint?
    private var penPoints:   [CGPoint] = []
    private var activeEmojiIndex: Int?
    private var selectedEmojiIndex: Int?
    private var emojiGestureStartPoint: CGPoint?
    private var emojiInitialSticker: EmojiSticker?
    private var emojiGestureMode: EmojiGestureMode = .move
    private var emojiInitialAngle: CGFloat = 0
    private var emojiInitialDistance: CGFloat = 0
    private var trackingAreaRef: NSTrackingArea?

    private weak var activeTextField: TextInputField?
    private var currentStyle: AnnotationToolStyle {
        guard let currentTool else { return .default(for: .rectangle) }
        return styleProvider?(currentTool) ?? .default(for: currentTool)
    }

    // MARK: – Init

    init(frame: NSRect, screenshot: NSImage) {
        self.screenshot = screenshot
        super.init(frame: frame)
        updateTrackingAreas()
    }
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }  // standard AppKit: (0,0) = bottom-left

    override func updateTrackingAreas() {
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        updateEmojiCursor(at: convert(event.locationInWindow, from: nil))
        super.mouseMoved(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        updateEmojiCursor(at: convert(event.locationInWindow, from: nil))
    }

    // MARK: – Mouse handling

    override func mouseDown(with event: NSEvent) {
        commitActiveTextField()
        let p = convert(event.locationInWindow, from: nil)

        if beginEmojiInteraction(at: p, event: event) {
            needsDisplay = true
            return
        }

        if selectedEmojiIndex != nil {
            selectedEmojiIndex = nil
        }

        guard let tool = currentTool else { return }

        switch tool {
        case .emoji:
            break
        case .text:
            presentTextInput(at: p)
        case .pen:
            penPoints = [p]
            dragStart  = p
        default:
            dragStart   = p
            dragCurrent = p
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if updateEmojiInteraction(with: event) {
            needsDisplay = true
            return
        }

        guard let tool = currentTool else { return }
        let p = convert(event.locationInWindow, from: nil)
        if tool == .pen {
            penPoints.append(p)
        } else {
            dragCurrent = p
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if endEmojiInteraction(with: event) {
            needsDisplay = true
            return
        }

        guard let tool = currentTool else { return }
        let p = convert(event.locationInWindow, from: nil)
        defer {
            dragStart   = nil
            dragCurrent = nil
            penPoints   = []
            needsDisplay = true
        }

        switch tool {
        case .rectangle:
            guard let s = dragStart else { return }
            let r = normalizedRect(from: s, to: p)
            guard r.width > 2, r.height > 2 else { return }
            let style = currentStyle
            annotations.append(.rectangle(rect: r, color: style.color, lineWidth: style.lineWidth, isFilled: style.isFilled))

        case .circle:
            guard let s = dragStart else { return }
            let r = normalizedRect(from: s, to: p)
            guard r.width > 2, r.height > 2 else { return }
            let style = currentStyle
            annotations.append(.circle(rect: r, color: style.color, lineWidth: style.lineWidth, isFilled: style.isFilled))

        case .arrow:
            guard let s = dragStart else { return }
            guard hypot(p.x - s.x, p.y - s.y) > 4 else { return }
            let style = currentStyle
            annotations.append(.arrow(from: s, to: p, color: style.color, lineWidth: style.lineWidth, isFilled: style.isFilled))

        case .pen:
            guard penPoints.count > 1 else { return }
            let style = currentStyle
            let color = style.isFilled ? style.color : style.color.withAlphaComponent(0.35)
            annotations.append(.pen(points: penPoints, color: color, lineWidth: style.lineWidth))

        case .mosaic:
            guard let s = dragStart else { return }
            let r = normalizedRect(from: s, to: p)
            guard r.width > 4, r.height > 4 else { return }
            annotations.append(.mosaic(rect: r))

        case .crop:
            guard let s = dragStart else { return }
            let r = normalizedRect(from: s, to: p)
            guard r.width > 10, r.height > 10 else { return }
            cropCanvas(to: r)

        default:
            break
        }
    }

    // MARK: – Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Background
        NSColor(white: 0.15, alpha: 1).setFill()
        bounds.fill()

        // Screenshot
        screenshot.draw(in: screenshotDrawRect)

        // Committed annotations
        for (idx, item) in annotations.enumerated() {
            drawAnnotation(item, index: idx)
        }

        // In-progress preview
        drawInProgress()
    }

    private var screenshotDrawRect: CGRect {
        // 按比例铺满可用画布，并顶对齐显示（顶部贴齐）。
        let s = screenshot.size
        guard s.width > 0, s.height > 0 else { return .zero }
        let scale = min(bounds.width / s.width, bounds.height / s.height)
        let w = s.width  * scale
        let h = s.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: bounds.height - h, width: w, height: h)
    }

    // MARK: – Annotation rendering

    private func drawAnnotation(_ item: AnnotationItem, index: Int) {
        switch item {
        case let .rectangle(r, c, lw, isFilled):
            let path = NSBezierPath(rect: r)
            path.lineWidth = lw
            if isFilled {
                c.withAlphaComponent(0.22).setFill()
                path.fill()
            }
            c.setStroke()
            path.stroke()

        case let .circle(r, c, lw, isFilled):
            let path = NSBezierPath(ovalIn: r)
            path.lineWidth = lw
            if isFilled {
                c.withAlphaComponent(0.22).setFill()
                path.fill()
            }
            c.setStroke()
            path.stroke()

        case let .arrow(from, to, c, lw, isFilled):
            drawArrow(from: from, to: to, color: c, lineWidth: lw, isFilled: isFilled)

        case let .pen(pts, c, lw):
            guard pts.count > 1 else { return }
            let path = NSBezierPath()
            path.move(to: pts[0])
            pts.dropFirst().forEach { path.line(to: $0) }
            path.lineWidth    = lw
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            c.setStroke()
            path.stroke()

        case let .mosaic(r):
            drawMosaic(in: r)

        case let .text(origin, content, font, color):
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            (content as NSString).draw(at: origin, withAttributes: attrs)

        case let .emojiSticker(sticker):
            drawEmojiSticker(sticker, isSelected: index == selectedEmojiIndex)
        }
    }

    private func drawEmojiSticker(_ sticker: EmojiSticker, isSelected: Bool) {
        let size = max(8, sticker.baseSize * sticker.scale)
        let font = NSFont.systemFont(ofSize: size)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let text = sticker.content as NSString
        let textSize = text.size(withAttributes: attrs)

        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        cg.translateBy(x: sticker.center.x, y: sticker.center.y)
        cg.rotate(by: sticker.rotation)
        if sticker.isMirrored {
            cg.scaleBy(x: -1, y: 1)
        }
        text.draw(
            at: CGPoint(x: -textSize.width / 2, y: -textSize.height / 2),
            withAttributes: attrs
        )
        cg.restoreGState()

        if isSelected {
            let highlightRect = emojiSelectionRect(for: sticker)
            let path = NSBezierPath(roundedRect: highlightRect, xRadius: 10, yRadius: 10)
            NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 2
            let dash: [CGFloat] = [5, 4]
            path.setLineDash(dash, count: dash.count, phase: 0)
            path.stroke()

            drawEmojiControls(for: highlightRect)
        }
    }

    private func drawArrow(from: CGPoint, to: CGPoint, color: NSColor, lineWidth: CGFloat, isFilled: Bool) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let distance = hypot(to.x - from.x, to.y - from.y)
        let headLength = min(max(18, lineWidth * 4.2), distance * 0.55)
        let headHalfWidth = max(headLength * 0.62, lineWidth * 2.6)

        // Arrowhead base center sits behind the tip; this lets the triangle fully
        // cover the stem end, avoiding the two exposed corners at the tip.
        let baseCenter = CGPoint(
            x: to.x - headLength * cos(angle),
            y: to.y - headLength * sin(angle)
        )
        let perpendicular = angle + .pi / 2
        let p1 = CGPoint(
            x: baseCenter.x + headHalfWidth * cos(perpendicular),
            y: baseCenter.y + headHalfWidth * sin(perpendicular)
        )
        let p2 = CGPoint(
            x: baseCenter.x - headHalfWidth * cos(perpendicular),
            y: baseCenter.y - headHalfWidth * sin(perpendicular)
        )

        let stemEnd = CGPoint(
            x: baseCenter.x - lineWidth * 0.35 * cos(angle),
            y: baseCenter.y - lineWidth * 0.35 * sin(angle)
        )

        let stem = NSBezierPath()
        stem.move(to: from)
        stem.line(to: stemEnd)
        stem.lineWidth = lineWidth
        stem.lineCapStyle = .round
        stem.lineJoinStyle = .round
        color.setStroke()
        stem.stroke()

        let head = NSBezierPath()
        head.move(to: to)
        head.line(to: p1)
        head.line(to: p2)
        head.close()

        if isFilled {
            color.setFill()
            head.fill()
        } else {
            head.lineWidth = max(1.5, lineWidth)
            color.setStroke()
            head.stroke()
        }
    }

    private func drawMosaic(in rect: CGRect) {
        guard let cgImage = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let drawRect = screenshotDrawRect
        guard drawRect.width > 0, drawRect.height > 0 else { return }

        // Map view-space rect → screenshot pixel rect (CGImage coordinates: 0,0 top-left)
        let sx = CGFloat(cgImage.width)  / drawRect.width
        let sy = CGFloat(cgImage.height) / drawRect.height

        // Clamp to drawRect
        let clipped = rect.intersection(drawRect)
        guard !clipped.isNull else { return }

        // Offset relative to the screenshot draw rect origin
        let localX = clipped.origin.x - drawRect.origin.x
        let localY = clipped.origin.y - drawRect.origin.y  // NSView Y (bottom=0)

        // In CGImage Y (top=0): top of the clipped rect is at (drawRect.height - localY - clipped.height)
        let imgX = localX * sx
        let imgY = (drawRect.height - localY - clipped.height) * sy
        let imgW = clipped.width  * sx
        let imgH = clipped.height * sy
        let cropRect = CGRect(x: imgX, y: imgY, width: imgW, height: imgH)

        guard let crop = cgImage.cropping(to: cropRect) else { return }

        let ci     = CIImage(cgImage: crop)
        let filter = CIFilter(name: "CIPixellate")!
        let scale  = max(clipped.width, clipped.height) / 12
        filter.setValue(ci,    forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)

        guard let outCI = filter.outputImage else { return }
        let ctx = CIContext()
        guard let outCG = ctx.createCGImage(outCI, from: outCI.extent) else { return }

        let mosaicImage = NSImage(cgImage: outCG, size: clipped.size)
        mosaicImage.draw(in: clipped)
    }

    // MARK: – In-progress preview

    private func drawInProgress() {
        guard let tool = currentTool else { return }
        // Pen path
        if tool == .pen, penPoints.count > 1 {
            let style = currentStyle
            let path = NSBezierPath()
            path.move(to: penPoints[0])
            penPoints.dropFirst().forEach { path.line(to: $0) }
            path.lineWidth     = style.lineWidth
            path.lineCapStyle  = .round
            path.lineJoinStyle = .round
            let previewColor = style.isFilled ? style.color : style.color.withAlphaComponent(0.35)
            previewColor.setStroke()
            path.stroke()
            return
        }

        guard let s = dragStart, let c = dragCurrent else { return }

        switch tool {
        case .rectangle:
            let style = currentStyle
            let path = NSBezierPath(rect: normalizedRect(from: s, to: c))
            path.lineWidth = style.lineWidth
            if style.isFilled {
                style.color.withAlphaComponent(0.22).setFill()
                path.fill()
            }
            style.color.setStroke()
            path.stroke()

        case .circle:
            let style = currentStyle
            let path = NSBezierPath(ovalIn: normalizedRect(from: s, to: c))
            path.lineWidth = style.lineWidth
            if style.isFilled {
                style.color.withAlphaComponent(0.22).setFill()
                path.fill()
            }
            style.color.setStroke()
            path.stroke()

        case .arrow:
            let style = currentStyle
            drawArrow(from: s, to: c, color: style.color, lineWidth: style.lineWidth, isFilled: style.isFilled)

        case .mosaic:
            let r = normalizedRect(from: s, to: c)
            NSColor.black.withAlphaComponent(0.25).setFill()
            NSBezierPath(rect: r).fill()
            NSColor.white.withAlphaComponent(0.6).setStroke()
            let border = NSBezierPath(rect: r)
            border.lineWidth = 1
            border.stroke()

        case .crop:
            let r = normalizedRect(from: s, to: c)
            // Darken outside
            NSColor.black.withAlphaComponent(0.5).setFill()
            let outer = NSBezierPath(rect: bounds)
            let inner = NSBezierPath(rect: r)
            outer.append(inner)
            outer.windingRule = .evenOdd
            outer.fill()
            // Selection border
            let border = NSBezierPath(rect: r)
            border.lineWidth = 1.5
            NSColor.white.withAlphaComponent(0.85).setStroke()
            border.stroke()

        default:
            break
        }
    }

    // MARK: – Crop

    private func cropCanvas(to rect: CGRect) {
        let drawRect = screenshotDrawRect
        guard !drawRect.isNull, drawRect.width > 0 else { return }

        // Clamp to the screenshot area
        let clipped = rect.intersection(drawRect)
        guard !clipped.isNull else { return }

        // Offset inside the screenshot
        let localRect = CGRect(
            x: clipped.origin.x - drawRect.origin.x,
            y: clipped.origin.y - drawRect.origin.y,
            width: clipped.width,
            height: clipped.height
        )

        // Build new screenshot from cropped region
        // NSImage draw: from: uses image-space rect (origin = bottom-left of image)
        let imgW = screenshot.size.width
        let imgH = screenshot.size.height
        let scaleX = imgW / drawRect.width
        let scaleY = imgH / drawRect.height

        // Convert localRect (NSView bottom-left) → image space (bottom-left of NSImage = bottom of image)
        let fromRect = CGRect(
            x: localRect.origin.x * scaleX,
            y: localRect.origin.y * scaleY,
            width: localRect.width  * scaleX,
            height: localRect.height * scaleY
        )

        let newSize = CGSize(width: fromRect.width, height: fromRect.height)
        let cropped = NSImage(size: newSize)
        cropped.lockFocus()
        screenshot.draw(
            in: CGRect(origin: .zero, size: newSize),
            from: fromRect,
            operation: .copy,
            fraction: 1
        )
        cropped.unlockFocus()

        screenshot  = cropped
        annotations = []
        frame       = CGRect(origin: frame.origin, size: newSize)
        onCropCompleted?(newSize)
    }

    // MARK: – Text input

    private func presentTextInput(at point: CGPoint) {
        let tf = TextInputField(
            frame: CGRect(x: point.x, y: point.y - 20, width: 200, height: 32)
        )
        tf.isBezeled           = false
        tf.drawsBackground     = false
        tf.textColor           = currentStyle.color
        tf.font                = NSFont.systemFont(ofSize: 18, weight: .semibold)
        tf.placeholderString   = "输入文字…"
        tf.onCommit = { [weak self, weak tf] text in
            guard let self, let tf, !text.isEmpty else {
                tf?.removeFromSuperview()
                self?.activeTextField = nil
                return
            }
            let origin = CGPoint(x: tf.frame.origin.x, y: tf.frame.origin.y + 4)
            self.annotations.append(.text(
                origin: origin,
                content: text,
                font: tf.font ?? NSFont.systemFont(ofSize: 18),
                color: tf.textColor ?? self.currentStyle.color
            ))
            tf.removeFromSuperview()
            self.activeTextField = nil
            self.needsDisplay = true
        }
        tf.onCancel = { [weak self, weak tf] in
            tf?.removeFromSuperview()
            self?.activeTextField = nil
        }
        addSubview(tf)
        window?.makeFirstResponder(tf)
        activeTextField = tf
    }

    private func commitActiveTextField() {
        activeTextField?.commit()
    }

    // MARK: – Undo

    func undo() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        if let selectedEmojiIndex, !annotations.indices.contains(selectedEmojiIndex) {
            self.selectedEmojiIndex = nil
        }
        needsDisplay = true
    }

    func insertEmojiSticker(_ emoji: String) {
        let rect = screenshotDrawRect
        guard !rect.isNull else { return }
        let sticker = EmojiSticker(
            content: emoji,
            center: CGPoint(x: rect.midX, y: rect.midY),
            baseSize: max(24, min(rect.width, rect.height) * 0.12),
            scale: 1,
            rotation: 0,
            isMirrored: false
        )
        annotations.append(.emojiSticker(sticker: sticker))
        selectedEmojiIndex = annotations.indices.last
        needsDisplay = true
    }

    func rotateSelectedEmoji(by delta: CGFloat) {
        guard let idx = selectedEmojiIndex,
              case var .emojiSticker(sticker) = annotations[idx] else { return }
        sticker.rotation += delta
        annotations[idx] = .emojiSticker(sticker: sticker)
        needsDisplay = true
    }

    func scaleSelectedEmoji(by factor: CGFloat) {
        guard let idx = selectedEmojiIndex,
              case var .emojiSticker(sticker) = annotations[idx] else { return }
        sticker.scale = max(0.25, min(6.0, sticker.scale * factor))
        annotations[idx] = .emojiSticker(sticker: sticker)
        needsDisplay = true
    }

    func mirrorSelectedEmoji() {
        guard let idx = selectedEmojiIndex,
              case var .emojiSticker(sticker) = annotations[idx] else { return }
        sticker.isMirrored.toggle()
        annotations[idx] = .emojiSticker(sticker: sticker)
        needsDisplay = true
    }

    // MARK: – Export

    /// Renders the current canvas (screenshot + all annotations) to a new NSImage.
    func renderToImage() -> NSImage {
        let img = NSImage(size: bounds.size)
        img.lockFocusFlipped(false)
        draw(bounds)
        img.unlockFocus()
        return img
    }

    // MARK: – Helpers

    private func normalizedRect(from a: NSPoint, to b: NSPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width:  abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    private func beginEmojiInteraction(at point: CGPoint, event: NSEvent) -> Bool {
        if let selectedEmojiIndex,
           annotations.indices.contains(selectedEmojiIndex),
           case let .emojiSticker(sticker) = annotations[selectedEmojiIndex] {
            switch emojiControlHitTest(point, sticker: sticker) {
            case .rotateLeftButton:
                rotateSelectedEmoji(by: .pi / 2)
                return true
            case .rotateRightButton:
                rotateSelectedEmoji(by: -.pi / 2)
                return true
            case .mirrorButton:
                mirrorSelectedEmoji()
                return true
            case .cornerHandle:
                activeEmojiIndex = selectedEmojiIndex
                emojiGestureMode = .rotate
                emojiGestureStartPoint = point
                emojiInitialSticker = sticker
                emojiInitialAngle = angle(from: sticker.center, to: point)
                return true
            case .edgeHandle:
                activeEmojiIndex = selectedEmojiIndex
                emojiGestureMode = .scale
                emojiGestureStartPoint = point
                emojiInitialSticker = sticker
                emojiInitialDistance = max(1, distance(from: sticker.center, to: point))
                return true
            case .body:
                activeEmojiIndex = selectedEmojiIndex
                emojiGestureMode = .move
                emojiGestureStartPoint = point
                emojiInitialSticker = sticker
                return true
            case .none:
                break
            }
        }

        guard let idx = topEmojiIndex(at: point),
              case let .emojiSticker(sticker) = annotations[idx] else {
            return false
        }

        activeEmojiIndex = idx
        selectedEmojiIndex = idx
        emojiGestureStartPoint = point
        emojiInitialSticker = sticker
        emojiGestureMode = .move
        return true
    }

    private func updateEmojiInteraction(with event: NSEvent) -> Bool {
        guard
            let idx = activeEmojiIndex,
            let start = emojiGestureStartPoint,
            var sticker = emojiInitialSticker
        else {
            return false
        }

        let p = convert(event.locationInWindow, from: nil)
        let dx = p.x - start.x
        let dy = p.y - start.y

        switch emojiGestureMode {
        case .move:
            sticker.center = CGPoint(x: sticker.center.x + dx, y: sticker.center.y + dy)
        case .scale:
            let currentDistance = max(1, distance(from: sticker.center, to: p))
            let factor = currentDistance / max(1, emojiInitialDistance)
            sticker.scale = max(0.25, min(6.0, sticker.scale * factor))
        case .rotate:
            let currentAngle = angle(from: sticker.center, to: p)
            sticker.rotation += currentAngle - emojiInitialAngle
        }

        annotations[idx] = .emojiSticker(sticker: sticker)
        if emojiGestureMode == .rotate {
            emojiInitialAngle = angle(from: sticker.center, to: p)
        } else if emojiGestureMode == .scale {
            emojiInitialDistance = max(1, distance(from: sticker.center, to: p))
        } else {
            emojiGestureStartPoint = p
        }
        return true
    }

    private func endEmojiInteraction(with event: NSEvent) -> Bool {
        if updateEmojiInteraction(with: event) {
            resetEmojiInteraction()
            return true
        }
        resetEmojiInteraction()
        return false
    }

    private func resetEmojiInteraction() {
        activeEmojiIndex = nil
        emojiGestureStartPoint = nil
        emojiInitialSticker = nil
        emojiGestureMode = .move
        emojiInitialAngle = 0
        emojiInitialDistance = 0
    }

    private func topEmojiIndex(at point: CGPoint) -> Int? {
        for idx in annotations.indices.reversed() {
            guard case let .emojiSticker(sticker) = annotations[idx] else { continue }
            let radius = max(16, sticker.baseSize * sticker.scale * 0.65)
            let dist = hypot(point.x - sticker.center.x, point.y - sticker.center.y)
            if dist <= radius {
                return idx
            }
        }
        return nil
    }

    private func emojiBounds(for sticker: EmojiSticker) -> CGRect {
        let size = max(8, sticker.baseSize * sticker.scale)
        let font = NSFont.systemFont(ofSize: size)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let text = sticker.content as NSString
        let textSize = text.size(withAttributes: attrs)
        let side = max(textSize.width, textSize.height)
        let radius = max(16, side * 0.72)
        return CGRect(
            x: sticker.center.x - radius,
            y: sticker.center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
    }

    private func emojiSelectionRect(for sticker: EmojiSticker) -> CGRect {
        emojiBounds(for: sticker).insetBy(dx: -8, dy: -8)
    }

    private func drawEmojiControls(for selectionRect: CGRect) {
        for action in EmojiControlAction.allCases {
            let rect = emojiControlRect(for: action, selectionRect: selectionRect)
            let bg = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
            NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
            bg.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.35).setStroke()
            bg.lineWidth = 1
            bg.stroke()

            if let image = NSImage(systemSymbolName: action.systemName, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)) {
                let imageRect = CGRect(x: rect.midX - 7, y: rect.midY - 7, width: 14, height: 14)
                image.draw(in: imageRect)
            }
        }
    }

    private func emojiControlRect(for action: EmojiControlAction, selectionRect: CGRect) -> CGRect {
        let size = CGSize(width: 28, height: 24)
        let spacing: CGFloat = 8
        let totalWidth = size.width * 3 + spacing * 2
        let originX = selectionRect.midX - totalWidth / 2
        let y = selectionRect.minY - size.height - 10
        let index: CGFloat
        switch action {
        case .rotateLeftButton: index = 0
        case .mirrorButton: index = 1
        case .rotateRightButton: index = 2
        }
        return CGRect(
            x: originX + index * (size.width + spacing),
            y: y,
            width: size.width,
            height: size.height
        )
    }

    private func emojiControlHitTest(_ point: CGPoint, sticker: EmojiSticker) -> EmojiHitZone {
        let selectionRect = emojiSelectionRect(for: sticker)
        let cornerSize: CGFloat = 18
        let edgeInset: CGFloat = 20

        let corners = [
            CGRect(x: selectionRect.minX - cornerSize / 2, y: selectionRect.maxY - cornerSize / 2, width: cornerSize, height: cornerSize),
            CGRect(x: selectionRect.maxX - cornerSize / 2, y: selectionRect.maxY - cornerSize / 2, width: cornerSize, height: cornerSize),
            CGRect(x: selectionRect.minX - cornerSize / 2, y: selectionRect.minY - cornerSize / 2, width: cornerSize, height: cornerSize),
            CGRect(x: selectionRect.maxX - cornerSize / 2, y: selectionRect.minY - cornerSize / 2, width: cornerSize, height: cornerSize)
        ]
        if corners.contains(where: { $0.contains(point) }) {
            return .cornerHandle
        }

        let topEdge = CGRect(x: selectionRect.minX + edgeInset, y: selectionRect.maxY - 6, width: selectionRect.width - edgeInset * 2, height: 12)
        let bottomEdge = CGRect(x: selectionRect.minX + edgeInset, y: selectionRect.minY - 6, width: selectionRect.width - edgeInset * 2, height: 12)
        let leftEdge = CGRect(x: selectionRect.minX - 6, y: selectionRect.minY + edgeInset, width: 12, height: selectionRect.height - edgeInset * 2)
        let rightEdge = CGRect(x: selectionRect.maxX - 6, y: selectionRect.minY + edgeInset, width: 12, height: selectionRect.height - edgeInset * 2)
        if [topEdge, bottomEdge, leftEdge, rightEdge].contains(where: { $0.contains(point) }) {
            return .edgeHandle
        }

        for action in EmojiControlAction.allCases {
            if emojiControlRect(for: action, selectionRect: selectionRect).contains(point) {
                switch action {
                case .rotateLeftButton: return .rotateLeftButton
                case .mirrorButton: return .mirrorButton
                case .rotateRightButton: return .rotateRightButton
                }
            }
        }

        if selectionRect.contains(point) {
            return .body
        }

        return .none
    }

    private func updateEmojiCursor(at point: CGPoint) {
        guard let selectedEmojiIndex,
              annotations.indices.contains(selectedEmojiIndex),
              case let .emojiSticker(sticker) = annotations[selectedEmojiIndex] else {
            NSCursor.arrow.set()
            return
        }

        switch emojiControlHitTest(point, sticker: sticker) {
        case .cornerHandle:
            NSCursor.crosshair.set()
        case .edgeHandle:
            NSCursor.resizeLeftRight.set()
        case .body:
            NSCursor.openHand.set()
        case .rotateLeftButton, .rotateRightButton, .mirrorButton, .none:
            NSCursor.arrow.set()
        }
    }

    private func angle(from center: CGPoint, to point: CGPoint) -> CGFloat {
        atan2(point.y - center.y, point.x - center.x)
    }

    private func distance(from a: CGPoint, to b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }
}

private enum EmojiGestureMode {
    case move
    case scale
    case rotate
}

private enum EmojiHitZone {
    case none
    case body
    case cornerHandle
    case edgeHandle
    case rotateLeftButton
    case rotateRightButton
    case mirrorButton
}

private enum EmojiControlAction: CaseIterable {
    case rotateLeftButton
    case mirrorButton
    case rotateRightButton

    var systemName: String {
        switch self {
        case .rotateLeftButton:
            return "rotate.left"
        case .mirrorButton:
            return "arrow.left.and.right"
        case .rotateRightButton:
            return "rotate.right"
        }
    }
}

// MARK: – Text input field helper

private final class TextInputField: NSTextField {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    func commit() {
        onCommit?(stringValue)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return / numpad Enter
            commit()
        case 53: // Escape
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }
}
