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
    var currentTool: AnnotationTool = .rectangle
    var strokeColor: NSColor   = .systemRed
    var strokeWidth: CGFloat   = 3

    /// Called when a crop operation completes – supplies the new logical size.
    var onCropCompleted: ((NSSize) -> Void)?

    // MARK: – Private drawing state

    private var dragStart:   NSPoint?
    private var dragCurrent: NSPoint?
    private var penPoints:   [CGPoint] = []

    private weak var activeTextField: TextInputField?

    // MARK: – Init

    init(frame: NSRect, screenshot: NSImage) {
        self.screenshot = screenshot
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }  // standard AppKit: (0,0) = bottom-left

    // MARK: – Mouse handling

    override func mouseDown(with event: NSEvent) {
        commitActiveTextField()
        let p = convert(event.locationInWindow, from: nil)

        switch currentTool {
        case .emoji:
            NSApp.orderFrontCharacterPalette(nil)
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
        let p = convert(event.locationInWindow, from: nil)
        if currentTool == .pen {
            penPoints.append(p)
        } else {
            dragCurrent = p
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer {
            dragStart   = nil
            dragCurrent = nil
            penPoints   = []
            needsDisplay = true
        }

        switch currentTool {
        case .rectangle:
            guard let s = dragStart else { return }
            let r = normalizedRect(from: s, to: p)
            guard r.width > 2, r.height > 2 else { return }
            annotations.append(.rectangle(rect: r, color: strokeColor, lineWidth: strokeWidth))

        case .circle:
            guard let s = dragStart else { return }
            let r = normalizedRect(from: s, to: p)
            guard r.width > 2, r.height > 2 else { return }
            annotations.append(.circle(rect: r, color: strokeColor, lineWidth: strokeWidth))

        case .arrow:
            guard let s = dragStart else { return }
            guard hypot(p.x - s.x, p.y - s.y) > 4 else { return }
            annotations.append(.arrow(from: s, to: p, color: strokeColor, lineWidth: strokeWidth))

        case .pen:
            guard penPoints.count > 1 else { return }
            annotations.append(.pen(points: penPoints, color: strokeColor, lineWidth: strokeWidth))

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
        for item in annotations {
            drawAnnotation(item)
        }

        // In-progress preview
        drawInProgress()
    }

    private var screenshotDrawRect: CGRect {
        // Centre the screenshot inside the canvas bounds (no upscaling)
        let s = screenshot.size
        let scale = min(1, bounds.width / s.width, bounds.height / s.height)
        let w = s.width  * scale
        let h = s.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    // MARK: – Annotation rendering

    private func drawAnnotation(_ item: AnnotationItem) {
        switch item {
        case let .rectangle(r, c, lw):
            let path = NSBezierPath(rect: r)
            path.lineWidth = lw
            c.setStroke()
            path.stroke()

        case let .circle(r, c, lw):
            let path = NSBezierPath(ovalIn: r)
            path.lineWidth = lw
            c.setStroke()
            path.stroke()

        case let .arrow(from, to, c, lw):
            drawArrow(from: from, to: to, color: c, lineWidth: lw)

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
        }
    }

    private func drawArrow(from: CGPoint, to: CGPoint, color: NSColor, lineWidth: CGFloat) {
        let path  = NSBezierPath()
        path.move(to: from)
        path.line(to: to)
        path.lineWidth = lineWidth

        let angle: CGFloat = atan2(to.y - from.y, to.x - from.x)
        let len:   CGFloat = min(18, hypot(to.x - from.x, to.y - from.y) * 0.4)
        let spread: CGFloat = 0.45

        let p1 = CGPoint(x: to.x - len * cos(angle - spread), y: to.y - len * sin(angle - spread))
        let p2 = CGPoint(x: to.x - len * cos(angle + spread), y: to.y - len * sin(angle + spread))

        path.move(to: to); path.line(to: p1)
        path.move(to: to); path.line(to: p2)

        color.setStroke()
        path.stroke()
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
        // Pen path
        if currentTool == .pen, penPoints.count > 1 {
            let path = NSBezierPath()
            path.move(to: penPoints[0])
            penPoints.dropFirst().forEach { path.line(to: $0) }
            path.lineWidth     = strokeWidth
            path.lineCapStyle  = .round
            path.lineJoinStyle = .round
            strokeColor.setStroke()
            path.stroke()
            return
        }

        guard let s = dragStart, let c = dragCurrent else { return }

        switch currentTool {
        case .rectangle:
            let path = NSBezierPath(rect: normalizedRect(from: s, to: c))
            path.lineWidth = strokeWidth
            strokeColor.setStroke()
            path.stroke()

        case .circle:
            let path = NSBezierPath(ovalIn: normalizedRect(from: s, to: c))
            path.lineWidth = strokeWidth
            strokeColor.setStroke()
            path.stroke()

        case .arrow:
            drawArrow(from: s, to: c, color: strokeColor, lineWidth: strokeWidth)

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
        tf.textColor           = strokeColor
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
                color: tf.textColor ?? self.strokeColor
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
