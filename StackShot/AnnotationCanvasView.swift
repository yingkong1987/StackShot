import AppKit
import CoreImage

/// Custom NSView that renders a screenshot and interactive annotation layer.
final class AnnotationCanvasView: NSView {

    // MARK: – Public state

    var screenshot: NSImage {
        didSet {
            blurredScreenshotCache = nil
            needsDisplay = true
        }
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
    private var mosaicPoints: [CGPoint] = []
    private var mosaicCursorPoint: CGPoint?
    private var activeEmojiIndex: Int?
    private var selectedEmojiIndex: Int?
    private var emojiGestureStartPoint: CGPoint?
    private var emojiInitialSticker: EmojiSticker?
    private var emojiGestureMode: EmojiGestureMode = .move
    private var emojiInitialAngle: CGFloat = 0
    private var emojiInitialDistance: CGFloat = 0
    private var trackingAreaRef: NSTrackingArea?

    private weak var activeTextField: TextInputField?
    private var activeTextEditingIndex: Int?
    private var selectedTextIndex: Int?
    private var activeTextDragIndex: Int?
    private var textDragStartPoint: CGPoint?
    private var textDragInitialOrigin: CGPoint?
    private var blurredScreenshotCache: NSImage?
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
        let point = convert(event.locationInWindow, from: nil)
        if currentTool == .mosaic {
            mosaicCursorPoint = point
        }
        updateEmojiCursor(at: point)
        if currentTool != .emoji {
            NSCursor.arrow.set()
        }
        needsDisplay = true
        super.mouseMoved(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if currentTool == .mosaic {
            mosaicCursorPoint = point
        }
        updateEmojiCursor(at: point)
        if currentTool != .emoji {
            NSCursor.arrow.set()
        }
    }

    // MARK: – Mouse handling

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        if let activeTextField, activeTextField.frame.insetBy(dx: -8, dy: -8).contains(p) {
            window?.makeFirstResponder(activeTextField)
            return
        }

        if activeTextField != nil {
            commitActiveTextField()
        }

        if beginEmojiInteraction(at: p, event: event) {
            needsDisplay = true
            return
        }

        if selectedEmojiIndex != nil {
            selectedEmojiIndex = nil
        }

        if let textIndex = topTextIndex(at: p) {
            selectedTextIndex = textIndex
            if event.clickCount >= 2,
               case let .text(origin, content, font, color) = annotations[textIndex] {
                presentTextInput(
                    at: CGPoint(x: origin.x, y: origin.y - 4),
                    editingIndex: textIndex,
                    initialText: content,
                    initialFont: font,
                    initialColor: color
                )
            } else if case let .text(origin, _, _, _) = annotations[textIndex] {
                activeTextDragIndex = textIndex
                textDragStartPoint = p
                textDragInitialOrigin = origin
            }
            needsDisplay = true
            return
        } else if selectedTextIndex != nil {
            selectedTextIndex = nil
        }

        guard let tool = currentTool else { return }

        switch tool {
        case .emoji:
            break
        case .text:
            activeTextEditingIndex = nil
            presentTextInput(at: p)
        case .mosaic:
            mosaicPoints = [p]
            mosaicCursorPoint = p
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

        if let dragIndex = activeTextDragIndex,
           let start = textDragStartPoint,
           let initialOrigin = textDragInitialOrigin,
           annotations.indices.contains(dragIndex),
           case .text = annotations[dragIndex] {
            let p = convert(event.locationInWindow, from: nil)
            let dx = p.x - start.x
            let dy = p.y - start.y
            if case let .text(_, content, font, color) = annotations[dragIndex] {
                annotations[dragIndex] = .text(
                    origin: CGPoint(x: initialOrigin.x + dx, y: initialOrigin.y + dy),
                    content: content,
                    font: font,
                    color: color
                )
            }
            selectedTextIndex = dragIndex
            needsDisplay = true
            return
        }

        guard let tool = currentTool else { return }
        let p = convert(event.locationInWindow, from: nil)
        if tool == .pen {
            penPoints.append(p)
        } else if tool == .mosaic {
            mosaicPoints.append(p)
            mosaicCursorPoint = p
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

        if activeTextDragIndex != nil {
            activeTextDragIndex = nil
            textDragStartPoint = nil
            textDragInitialOrigin = nil
            needsDisplay = true
            return
        }

        guard let tool = currentTool else { return }
        let p = convert(event.locationInWindow, from: nil)
        defer {
            dragStart   = nil
            dragCurrent = nil
            penPoints   = []
            mosaicPoints = []
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
            guard !mosaicPoints.isEmpty else { return }
            let radius = max(4, currentStyle.mosaicRadius)
            annotations.append(.mosaicStroke(points: mosaicPoints, radius: radius))

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
        drawCanvas(includeInteractionGuides: true)
    }

    private func drawCanvas(includeInteractionGuides: Bool) {
        // Background
        NSColor(white: 0.15, alpha: 1).setFill()
        bounds.fill()

        // Screenshot
        screenshot.draw(in: screenshotDrawRect)

        // Committed annotations
        for (idx, item) in annotations.enumerated() {
            drawAnnotation(item, index: idx, includeInteractionGuides: includeInteractionGuides)
        }

        // In-progress preview
        if includeInteractionGuides {
            drawInProgress()
        }
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

    private func drawAnnotation(_ item: AnnotationItem, index: Int, includeInteractionGuides: Bool) {
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

        case let .mosaicStroke(points, radius):
            drawMosaicStroke(points: points, radius: radius)

        case let .text(origin, content, font, color):
            if index == activeTextEditingIndex {
                break
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            (content as NSString).draw(at: origin, withAttributes: attrs)
            if includeInteractionGuides, index == selectedTextIndex {
                let rect = textRect(origin: origin, content: content, font: font)
                    .insetBy(dx: -6, dy: -5)
                let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
                NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
                path.lineWidth = 1.4
                let dash: [CGFloat] = [4, 3]
                path.setLineDash(dash, count: dash.count, phase: 0)
                path.stroke()
            }

        case let .emojiSticker(sticker):
            drawEmojiSticker(
                sticker,
                isSelected: includeInteractionGuides && index == selectedEmojiIndex
            )
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

            drawEmojiRotateHandle(for: highlightRect)
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

    private func drawMosaicStroke(points: [CGPoint], radius: CGFloat) {
        guard points.isEmpty == false else { return }
        guard let blurred = blurredScreenshotImage() else { return }

        let drawRect = screenshotDrawRect
        guard drawRect.width > 0, drawRect.height > 0 else { return }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: drawRect).addClip()

        let clipPath = NSBezierPath()
        for point in points {
            let clamped = CGPoint(
                x: min(max(point.x, drawRect.minX), drawRect.maxX),
                y: min(max(point.y, drawRect.minY), drawRect.maxY)
            )
            let circle = CGRect(
                x: clamped.x - radius,
                y: clamped.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            clipPath.appendOval(in: circle)
        }
        clipPath.addClip()
        blurred.draw(in: drawRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func blurredScreenshotImage() -> NSImage? {
        if let blurredScreenshotCache {
            return blurredScreenshotCache
        }

        guard let cgImage = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let ciImage = CIImage(cgImage: cgImage)
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else {
            return nil
        }
        blurFilter.setValue(ciImage, forKey: kCIInputImageKey)
        blurFilter.setValue(10.0, forKey: kCIInputRadiusKey)
        guard let blurred = blurFilter.outputImage else {
            return nil
        }

        let cropped = blurred.cropped(to: ciImage.extent)
        let context = CIContext()
        guard let outCG = context.createCGImage(cropped, from: ciImage.extent) else {
            return nil
        }

        let image = NSImage(cgImage: outCG, size: screenshot.size)
        blurredScreenshotCache = image
        return image
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

        if tool == .mosaic {
            if !mosaicPoints.isEmpty {
                let radius = max(4, currentStyle.mosaicRadius)
                drawMosaicStroke(points: mosaicPoints, radius: radius)
            }
            if let cursorPoint = mosaicCursorPoint {
                let radius = max(4, currentStyle.mosaicRadius)
                let cursorRect = CGRect(
                    x: cursorPoint.x - radius,
                    y: cursorPoint.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                let cursorPath = NSBezierPath(ovalIn: cursorRect)
                NSColor.white.withAlphaComponent(0.9).setStroke()
                cursorPath.lineWidth = 1.4
                cursorPath.stroke()
            }
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
        selectedTextIndex = nil
        activeTextEditingIndex = nil
        activeTextDragIndex = nil
        textDragStartPoint = nil
        textDragInitialOrigin = nil
        frame       = CGRect(origin: frame.origin, size: newSize)
        onCropCompleted?(newSize)
    }

    // MARK: – Text input

    private func presentTextInput(
        at point: CGPoint,
        editingIndex: Int? = nil,
        initialText: String = "",
        initialFont: NSFont? = nil,
        initialColor: NSColor? = nil
    ) {
        activeTextField?.removeFromSuperview()
        let style = currentStyle
        let resolvedFont = initialFont
            ?? NSFont(name: style.textFontName, size: style.textFontSize)
            ?? NSFont.systemFont(ofSize: style.textFontSize, weight: .semibold)
        let resolvedColor = initialColor ?? style.color
        let idealWidth = max(
            200,
            (initialText as NSString).size(withAttributes: [.font: resolvedFont]).width + 44
        )
        let tf = TextInputField(
            frame: CGRect(x: point.x, y: point.y - 20, width: idealWidth, height: 32)
        )
        tf.isBezeled           = false
        tf.drawsBackground     = false
        tf.textColor           = resolvedColor
        tf.font                = resolvedFont
        tf.placeholderString   = "输入文字…"
        tf.stringValue         = initialText
        activeTextEditingIndex = editingIndex
        tf.onCommit = { [weak self, weak tf] text in
            guard let self, let tf else {
                return
            }
            guard !text.isEmpty else {
                if let idx = editingIndex, self.annotations.indices.contains(idx) {
                    self.annotations.remove(at: idx)
                }
                tf.removeFromSuperview()
                self.activeTextField = nil
                self.activeTextEditingIndex = nil
                return
            }
            let origin = CGPoint(x: tf.frame.origin.x, y: tf.frame.origin.y + 4)
            let item: AnnotationItem = .text(
                origin: origin,
                content: text,
                font: tf.font ?? resolvedFont,
                color: tf.textColor ?? resolvedColor
            )
            if let idx = editingIndex, self.annotations.indices.contains(idx) {
                self.annotations[idx] = item
                self.selectedTextIndex = idx
            } else {
                self.annotations.append(item)
                self.selectedTextIndex = self.annotations.indices.last
            }
            tf.removeFromSuperview()
            self.activeTextField = nil
            self.activeTextEditingIndex = nil
            self.needsDisplay = true
        }
        tf.onCancel = { [weak self] in
            self?.discardActiveTextEditing()
        }
        addSubview(tf)
        window?.makeFirstResponder(tf)
        activeTextField = tf
        applyCurrentTextStyleIfNeeded()
    }

    private func commitActiveTextField() {
        activeTextField?.commit()
    }

    @discardableResult
    func commitActiveTextEditingIfNeeded() -> Bool {
        guard activeTextField != nil else { return false }
        commitActiveTextField()
        return true
    }

    @discardableResult
    func cancelActiveTextEditingIfNeeded() -> Bool {
        guard activeTextField != nil else { return false }
        discardActiveTextEditing()
        return true
    }

    func applyCurrentTextStyleIfNeeded() {
        guard currentTool == .text, let textField = activeTextField else { return }
        let style = currentStyle
        let font = NSFont(name: style.textFontName, size: style.textFontSize)
            ?? NSFont.systemFont(ofSize: style.textFontSize, weight: .semibold)
        textField.textColor = style.color
        textField.font = font

        if let editor = window?.fieldEditor(false, for: textField) as? NSTextView {
            editor.font = font
            editor.textColor = style.color
            editor.insertionPointColor = style.color
            var attributes = editor.typingAttributes
            attributes[.font] = font
            attributes[.foregroundColor] = style.color
            editor.typingAttributes = attributes
        }
    }

    private func discardActiveTextEditing() {
        activeTextField?.removeFromSuperview()
        activeTextField = nil
        activeTextEditingIndex = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: – Undo

    func undo() {
        guard !annotations.isEmpty else { return }
        commitActiveTextField()
        annotations.removeLast()
        if let selectedEmojiIndex, !annotations.indices.contains(selectedEmojiIndex) {
            self.selectedEmojiIndex = nil
        }
        if let selectedTextIndex, !annotations.indices.contains(selectedTextIndex) {
            self.selectedTextIndex = nil
        }
        if let activeTextEditingIndex, !annotations.indices.contains(activeTextEditingIndex) {
            self.activeTextEditingIndex = nil
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

    func deleteSelectedEmoji() {
        guard let idx = selectedEmojiIndex,
              annotations.indices.contains(idx) else { return }
        annotations.remove(at: idx)
        selectedEmojiIndex = nil
        resetEmojiInteraction()
        needsDisplay = true
    }

    // MARK: – Export

    /// Renders the current canvas (screenshot + all annotations) to a new NSImage.
    func renderToImage() -> NSImage {
        let img = NSImage(size: bounds.size)
        img.lockFocusFlipped(false)
        drawCanvas(includeInteractionGuides: false)
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

    private func textRect(origin: CGPoint, content: String, font: NSFont) -> CGRect {
        let text = content as NSString
        let size = text.size(withAttributes: [.font: font])
        return CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    private func topTextIndex(at point: CGPoint) -> Int? {
        for idx in annotations.indices.reversed() {
            guard case let .text(origin, content, font, _) = annotations[idx] else { continue }
            let hitRect = textRect(origin: origin, content: content, font: font)
                .insetBy(dx: -8, dy: -8)
            if hitRect.contains(point) {
                return idx
            }
        }
        return nil
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
            case .deleteButton:
                deleteSelectedEmoji()
                return true
            case .rotateHandle:
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
        emojiInitialSticker = sticker
        if emojiGestureMode == .rotate {
            emojiInitialAngle = angle(from: sticker.center, to: p)
            emojiGestureStartPoint = p
        } else if emojiGestureMode == .scale {
            emojiInitialDistance = max(1, distance(from: sticker.center, to: p))
            emojiGestureStartPoint = p
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
            let fillColor: NSColor = NSColor(calibratedWhite: 1.0, alpha: 0.94)
            fillColor.setFill()
            bg.fill()
            let strokeColor: NSColor = NSColor(calibratedWhite: 0.72, alpha: 0.9)
            strokeColor.setStroke()
            bg.lineWidth = 1
            bg.stroke()

            if let image = NSImage(systemSymbolName: action.systemName, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)) {
                let imageRect = CGRect(x: rect.midX - 8, y: rect.midY - 8, width: 16, height: 16)
                NSColor(calibratedWhite: 0.12, alpha: 1).set()
                image.draw(in: imageRect)
            }
        }
    }

    private func drawEmojiRotateHandle(for selectionRect: CGRect) {
        let handleRect = emojiRotateHandleRect(selectionRect: selectionRect)
        let path = NSBezierPath(ovalIn: handleRect)
        NSColor(calibratedWhite: 1.0, alpha: 0.96).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.75).setStroke()
        path.lineWidth = 1.2
        path.stroke()
    }

    private func emojiControlRect(for action: EmojiControlAction, selectionRect: CGRect) -> CGRect {
        if action == .deleteButton {
            return CGRect(
                x: selectionRect.maxX - 14,
                y: selectionRect.maxY - 14,
                width: 28,
                height: 28
            )
        }
        let size = CGSize(width: 34, height: 28)
        let spacing: CGFloat = 10
        let totalWidth = size.width * 3 + spacing * 2
        let originX = selectionRect.midX - totalWidth / 2
        let y = selectionRect.minY - size.height - 12
        let index: CGFloat
        switch action {
        case .rotateLeftButton: index = 0
        case .mirrorButton: index = 1
        case .rotateRightButton: index = 2
        case .deleteButton: index = 0
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
        let edgeInset: CGFloat = 20

        for action in EmojiControlAction.allCases {
            if emojiControlRect(for: action, selectionRect: selectionRect).contains(point) {
                switch action {
                case .rotateLeftButton: return .rotateLeftButton
                case .mirrorButton: return .mirrorButton
                case .rotateRightButton: return .rotateRightButton
                case .deleteButton: return .deleteButton
                }
            }
        }

        if emojiRotateHandleRect(selectionRect: selectionRect).contains(point) {
            return .rotateHandle
        }

        let topEdge = CGRect(x: selectionRect.minX + edgeInset, y: selectionRect.maxY - 6, width: selectionRect.width - edgeInset * 2, height: 12)
        let bottomEdge = CGRect(x: selectionRect.minX + edgeInset, y: selectionRect.minY - 6, width: selectionRect.width - edgeInset * 2, height: 12)
        let leftEdge = CGRect(x: selectionRect.minX - 6, y: selectionRect.minY + edgeInset, width: 12, height: selectionRect.height - edgeInset * 2)
        let rightEdge = CGRect(x: selectionRect.maxX - 6, y: selectionRect.minY + edgeInset, width: 12, height: selectionRect.height - edgeInset * 2)
        if [topEdge, bottomEdge, leftEdge, rightEdge].contains(where: { $0.contains(point) }) {
            return .edgeHandle
        }

        if selectionRect.contains(point) {
            return .body
        }

        return .none
    }

    private func emojiRotateHandleRect(selectionRect: CGRect) -> CGRect {
        let size: CGFloat = 18
        return CGRect(
            x: selectionRect.maxX - size / 2,
            y: selectionRect.minY - size / 2,
            width: size,
            height: size
        )
    }

    private func updateEmojiCursor(at point: CGPoint) {
        guard let selectedEmojiIndex,
              annotations.indices.contains(selectedEmojiIndex),
              case let .emojiSticker(sticker) = annotations[selectedEmojiIndex] else {
            NSCursor.arrow.set()
            return
        }

        switch emojiControlHitTest(point, sticker: sticker) {
        case .rotateHandle:
            NSCursor.emojiRotate.set()
        case .edgeHandle:
            NSCursor.resizeLeftRight.set()
        case .body:
            NSCursor.openHand.set()
        case .rotateLeftButton, .rotateRightButton, .mirrorButton, .deleteButton, .none:
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
    case rotateHandle
    case edgeHandle
    case rotateLeftButton
    case rotateRightButton
    case mirrorButton
    case deleteButton
}

private enum EmojiControlAction: CaseIterable {
    case rotateLeftButton
    case mirrorButton
    case rotateRightButton
    case deleteButton

    var systemName: String {
        switch self {
        case .rotateLeftButton:
            return "rotate.left"
        case .mirrorButton:
            return "arrow.left.and.right"
        case .rotateRightButton:
            return "rotate.right"
        case .deleteButton:
            return "xmark"
        }
    }
}

private extension NSCursor {
    static let emojiRotate: NSCursor = {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        let buttonRect = NSRect(x: 2.5, y: 2.5, width: 19, height: 19)
        let buttonPath = NSBezierPath(ovalIn: buttonRect)
        NSColor(calibratedWhite: 1.0, alpha: 0.96).setFill()
        buttonPath.fill()
        NSColor(calibratedWhite: 0.72, alpha: 0.9).setStroke()
        buttonPath.lineWidth = 1
        buttonPath.stroke()

        let symbolRect = NSRect(x: 4, y: 4, width: 16, height: 16)
        let symbolName = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil) != nil
            ? "arrow.triangle.2.circlepath"
            : "rotate.right"
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)) {
            NSColor(calibratedWhite: 0.12, alpha: 1).set()
            symbol.draw(in: symbolRect)
        }
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }()
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
