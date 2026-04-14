import AppKit

/// Drawing / interaction mode of the annotation canvas.
enum AnnotationTool: Equatable {
    case rectangle
    case circle
    case emoji
    case arrow
    case pen
    case mosaic
    case text
    case ocr
    case ocrTranslate
    case crop        // "resize / crop" button
}

/// A single committed annotation on the canvas.
enum AnnotationItem {
    case rectangle(rect: CGRect, color: NSColor, lineWidth: CGFloat)
    case circle(rect: CGRect, color: NSColor, lineWidth: CGFloat)
    case arrow(from: CGPoint, to: CGPoint, color: NSColor, lineWidth: CGFloat)
    case pen(points: [CGPoint], color: NSColor, lineWidth: CGFloat)
    case mosaic(rect: CGRect)
    case text(origin: CGPoint, content: String, font: NSFont, color: NSColor)
}
