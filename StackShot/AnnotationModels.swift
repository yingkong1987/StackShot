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

struct EmojiSticker {
    var content: String
    var center: CGPoint
    var baseSize: CGFloat
    var scale: CGFloat
    var rotation: CGFloat
    var isMirrored: Bool
}

struct AnnotationToolStyle {
    var lineWidth: CGFloat
    var isFilled: Bool
    var color: NSColor
    var textFontName: String
    var textFontSize: CGFloat
    var mosaicRadius: CGFloat

    static func `default`(for tool: AnnotationTool) -> AnnotationToolStyle {
        let defaultTextFont = NSFont.systemFont(ofSize: 20, weight: .semibold)
        let defaultTextFontName = defaultTextFont.fontName
        let defaultTextFontSize = defaultTextFont.pointSize

        switch tool {
        case .rectangle, .circle:
            return AnnotationToolStyle(
                lineWidth: 3,
                isFilled: false,
                color: .systemRed,
                textFontName: defaultTextFontName,
                textFontSize: defaultTextFontSize,
                mosaicRadius: 18
            )
        case .arrow:
            return AnnotationToolStyle(
                lineWidth: 4,
                isFilled: true,
                color: .systemRed,
                textFontName: defaultTextFontName,
                textFontSize: defaultTextFontSize,
                mosaicRadius: 18
            )
        case .pen:
            return AnnotationToolStyle(
                lineWidth: 4,
                isFilled: true,
                color: .systemRed,
                textFontName: defaultTextFontName,
                textFontSize: defaultTextFontSize,
                mosaicRadius: 18
            )
        case .mosaic:
            return AnnotationToolStyle(
                lineWidth: 3,
                isFilled: false,
                color: .systemRed,
                textFontName: defaultTextFontName,
                textFontSize: defaultTextFontSize,
                mosaicRadius: 18
            )
        default:
            return AnnotationToolStyle(
                lineWidth: 3,
                isFilled: false,
                color: .systemRed,
                textFontName: defaultTextFontName,
                textFontSize: defaultTextFontSize,
                mosaicRadius: 18
            )
        }
    }
}

/// A single committed annotation on the canvas.
enum AnnotationItem {
    case rectangle(rect: CGRect, color: NSColor, lineWidth: CGFloat, isFilled: Bool)
    case circle(rect: CGRect, color: NSColor, lineWidth: CGFloat, isFilled: Bool)
    case arrow(from: CGPoint, to: CGPoint, color: NSColor, lineWidth: CGFloat, isFilled: Bool)
    case pen(points: [CGPoint], color: NSColor, lineWidth: CGFloat)
    case mosaicStroke(points: [CGPoint], radius: CGFloat)
    case text(origin: CGPoint, content: String, font: NSFont, color: NSColor)
    case emojiSticker(sticker: EmojiSticker)
}
