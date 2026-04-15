import AppKit

enum RegionSelectionShape {
    case rectangle
    case circle
}

/// 全屏半透明遮罩 + 拖拽选取；Esc/右键取消。
final class RegionSelectionOverlay: NSWindow {
    init(
        shape: RegionSelectionShape,
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

private final class SelectionOverlayView: NSView {
    private let shape: RegionSelectionShape
    private let onFinish: (CGRect) -> Void
    private let onAbort: () -> Void

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?

    init(frame frameRect: NSRect, shape: RegionSelectionShape, onFinish: @escaping (CGRect) -> Void, onAbort: @escaping () -> Void) {
        self.shape = shape
        self.onFinish = onFinish
        self.onAbort = onAbort
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
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
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { startPoint = nil; currentPoint = nil; needsDisplay = true }
        currentPoint = convert(event.locationInWindow, from: nil)
        guard let s = startPoint, let e = currentPoint else { return }
        let r = normalizedRect(from: s, to: e)
        if r.width >= 4, r.height >= 4 {
            onFinish(r)
        } else {
            onAbort()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onAbort()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.42).setFill()
        NSBezierPath(rect: bounds).fill()

        guard let s = startPoint, let c = currentPoint else { return }
        let r = normalizedRect(from: s, to: c)

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

        NSGraphicsContext.saveGraphicsState()
        if shape == .circle {
            let path = NSBezierPath(ovalIn: r)
            path.lineWidth = 2
            NSColor.white.withAlphaComponent(0.95).setStroke()
            path.stroke()
        } else {
            let path = NSBezierPath(rect: r)
            path.lineWidth = 2
            NSColor.white.withAlphaComponent(0.95).setStroke()
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func normalizedRect(from a: NSPoint, to b: NSPoint) -> CGRect {
        let x = min(a.x, b.x)
        let y = min(a.y, b.y)
        let w = abs(b.x - a.x)
        let h = abs(b.y - a.y)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
