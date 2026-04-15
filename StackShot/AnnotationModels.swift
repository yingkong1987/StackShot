import AppKit

/// Drawing / interaction mode of the annotation canvas.
enum AnnotationTool: Hashable {
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

struct AnnotationToolStyle {
    var lineWidth: CGFloat
    var isFilled: Bool
    var color: NSColor

    static func `default`(for tool: AnnotationTool) -> AnnotationToolStyle {
        switch tool {
        case .rectangle, .circle:
            return AnnotationToolStyle(lineWidth: 3, isFilled: false, color: .systemRed)
        case .arrow:
            return AnnotationToolStyle(lineWidth: 4, isFilled: true, color: .systemRed)
        case .pen:
            return AnnotationToolStyle(lineWidth: 4, isFilled: true, color: .systemRed)
        default:
            return AnnotationToolStyle(lineWidth: 3, isFilled: false, color: .systemRed)
        }
    }
}

/// A single committed annotation on the canvas.
enum AnnotationItem {
    case rectangle(rect: CGRect, color: NSColor, lineWidth: CGFloat, isFilled: Bool)
    case circle(rect: CGRect, color: NSColor, lineWidth: CGFloat, isFilled: Bool)
    case arrow(from: CGPoint, to: CGPoint, color: NSColor, lineWidth: CGFloat, isFilled: Bool)
    case pen(points: [CGPoint], color: NSColor, lineWidth: CGFloat)
    case mosaic(rect: CGRect)
    case text(origin: CGPoint, content: String, font: NSFont, color: NSColor)
}
