import AppKit

/// 在目标窗口周围绘制高亮描边；不接收鼠标事件。
final class HighlightBorderWindow: NSWindow {
    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = true
        hasShadow = false
        contentView = HighlightBorderView(frame: NSRect(origin: .zero, size: frame.size))
    }
}

private final class HighlightBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        NSBezierPath(rect: bounds).fill()
        let inset: CGFloat = 3
        let stroke: CGFloat = 4
        let r = bounds.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        path.lineWidth = stroke
        NSColor.systemBlue.withAlphaComponent(0.95).setStroke()
        path.stroke()
    }
}
