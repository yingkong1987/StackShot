//
//  ImageTextTranslationService.swift
//  StackShot
//
//  Modular pipeline that performs "seamless image text translation":
//      NSImage  ─►  Vision OCR  ─►  Style/Background extraction
//               ─►  Inpainting (erase original text)
//               ─►  Translation (async)
//               ─►  Core Text rendering of translated string
//               ─►  NSImage (translated)
//
//  Coordinate system note
//  ──────────────────────
//  • Vision returns normalized rects in a *bottom-left* origin
//    coordinate system (0,0 = bottom-left, 1,1 = top-right).
//  • CGContext used here is created with a flipped (top-left)
//    origin via `NSGraphicsContext(bitmapImageRep:)` so that
//    NSImage drawing matches what we see on screen.
//  • Therefore, when projecting a Vision rect onto our CGContext
//    we convert with:
//        x = bbox.minX * W
//        y = (1 - bbox.maxY) * H        // <- flip Y
//        w = bbox.width  * W
//        h = bbox.height * H
//

import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import Vision

#if canImport(Translation)
import Translation
#endif

// MARK: - Public models

/// A single text region detected in the source image, expressed in
/// *image pixel* coordinates with a top-left origin (matches NSImage
/// drawing once the context is flipped).
public struct TextElement: Sendable, Hashable {
    public let id: UUID
    public let string: String
    /// Bounding box in image pixel space, top-left origin.
    public let pixelRect: CGRect
    /// Original normalized Vision rect, bottom-left origin. Kept for
    /// debugging / advanced consumers.
    public let visionRect: CGRect
    /// Vision confidence 0...1.
    public let confidence: Float

    public init(
        id: UUID = UUID(),
        string: String,
        pixelRect: CGRect,
        visionRect: CGRect,
        confidence: Float
    ) {
        self.id = id
        self.string = string
        self.pixelRect = pixelRect
        self.visionRect = visionRect
        self.confidence = confidence
    }
}

/// Visual style sampled from the area around a `TextElement`.
public struct TextStyle: Sendable, Hashable {
    public var foreground: CGColorWrapper
    public var background: CGColorWrapper
    /// Estimated point size based on the bounding box height.
    public var pointSize: CGFloat
    /// Estimated weight (regular/medium/bold) — best effort.
    public var weight: NSFont.Weight

    public init(
        foreground: CGColor,
        background: CGColor,
        pointSize: CGFloat,
        weight: NSFont.Weight
    ) {
        self.foreground = CGColorWrapper(foreground)
        self.background = CGColorWrapper(background)
        self.pointSize = pointSize
        self.weight = weight
    }
}

/// `CGColor` is not `Hashable`/`Sendable`. Wrap it so the public model
/// types can adopt those conformances.
public struct CGColorWrapper: @unchecked Sendable, Hashable {
    public let cgColor: CGColor
    public init(_ cgColor: CGColor) { self.cgColor = cgColor }

    public static func == (lhs: CGColorWrapper, rhs: CGColorWrapper) -> Bool {
        lhs.cgColor == rhs.cgColor
    }

    public func hash(into hasher: inout Hasher) {
        if let comps = cgColor.components {
            for c in comps { hasher.combine(c) }
        }
    }
}

/// The pairing of an original `TextElement`, the translated string,
/// and the style used to render it.
public struct TranslatedTextElement: Sendable, Hashable {
    public let element: TextElement
    public let translation: String
    public let style: TextStyle
}

/// The end-to-end result of the pipeline.
public struct ImageTextTranslationResult: @unchecked Sendable {
    public let translatedImage: NSImage
    public let elements: [TranslatedTextElement]
}

// MARK: - Errors

public enum ImageTextTranslationError: Error, LocalizedError {
    case invalidImage
    case visionFailed(underlying: Error)
    case contextCreationFailed
    case renderingFailed
    case translationFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .invalidImage: return "The provided image could not be decoded."
        case .visionFailed(let e): return "Vision text recognition failed: \(e.localizedDescription)"
        case .contextCreationFailed: return "Could not create a drawing context."
        case .renderingFailed: return "Failed to render the translated image."
        case .translationFailed(let e): return "Translation failed: \(e.localizedDescription)"
        }
    }
}

// MARK: - Service protocols

/// Translates a batch of strings. Implementations may call into Apple's
/// Translation framework, an HTTP API, or a static dictionary (tests).
public protocol TranslationService: Sendable {
    /// Translate `strings` from `source` (nil = auto-detect) into `target`.
    /// The returned array MUST be the same length and order as the input.
    func translate(
        _ strings: [String],
        from source: Locale.Language?,
        to target: Locale.Language
    ) async throws -> [String]
}

/// Erases the text at `regions` from `image`, returning a clean
/// background-only image. The MVP implementation samples surrounding
/// pixels; a future Core ML / LaMa-based implementation can drop in
/// without changing the rest of the pipeline.
public protocol InpaintingService: Sendable {
    func inpaint(
        image: CGImage,
        removing regions: [CGRect]
    ) async throws -> CGImage
}

// MARK: - Default translation services

/// Returns the input strings unchanged. Useful as a placeholder.
public struct IdentityTranslationService: TranslationService {
    public init() {}
    public func translate(
        _ strings: [String],
        from _: Locale.Language?,
        to _: Locale.Language
    ) async throws -> [String] { strings }
}

/// Backed by an in-memory dictionary. Helpful for unit tests / previews.
public struct DictionaryTranslationService: TranslationService {
    public let table: [String: String]
    public init(table: [String: String]) { self.table = table }
    public func translate(
        _ strings: [String],
        from _: Locale.Language?,
        to _: Locale.Language
    ) async throws -> [String] {
        strings.map { table[$0] ?? $0 }
    }
}

// MARK: - Default inpainting service

/// MVP inpainter: for each rect, sample the median color of a thin
/// border just outside the rect and fill the rect with that color.
/// Reasonably good for solid-color UI screenshots, posters, badges, etc.
public struct EdgeSampleInpaintingService: InpaintingService {
    /// How many pixels outside the rect to sample for the border colour.
    public var sampleInset: Int

    public init(sampleInset: Int = 4) { self.sampleInset = sampleInset }

    public func inpaint(image: CGImage, removing regions: [CGRect]) async throws -> CGImage {
        try await Task.detached(priority: .userInitiated) {
            try Self.fill(image: image, regions: regions, sampleInset: sampleInset)
        }.value
    }

    private static func fill(
        image: CGImage,
        regions: [CGRect],
        sampleInset: Int
    ) throws -> CGImage {
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { throw ImageTextTranslationError.contextCreationFailed }

        // Important: this CGContext has a bottom-left origin. The
        // `regions` we receive are in *top-left* image-pixel space, so
        // we flip them when filling.
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let sampler = ImagePixelSampler(cgImage: image)

        for rect in regions {
            let pixelRect = rect.integral
            let color = sampler?.borderMedianColor(
                around: pixelRect,
                inset: sampleInset
            ) ?? CGColor(red: 1, green: 1, blue: 1, alpha: 1)

            // Flip Y for the bottom-left origin context.
            let flippedY = CGFloat(height) - pixelRect.maxY
            let drawRect = CGRect(
                x: pixelRect.origin.x,
                y: flippedY,
                width: pixelRect.width,
                height: pixelRect.height
            )
            context.setFillColor(color)
            context.fill(drawRect)
        }

        guard let output = context.makeImage() else {
            throw ImageTextTranslationError.renderingFailed
        }
        return output
    }
}

// MARK: - Coordinator

/// Orchestrates OCR → style extraction → inpainting → translation →
/// re-rendering. Use `process(_:)` to run the whole pipeline.
public final class ImageTextTranslator: @unchecked Sendable {

    public struct Configuration: Sendable {
        public var recognitionLanguages: [String]
        public var targetLanguage: Locale.Language
        public var sourceLanguage: Locale.Language?
        public var minimumConfidence: Float
        public var preferredFontFamily: String?

        public init(
            recognitionLanguages: [String] = [
                "zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR",
                "fr-FR", "de-DE", "es-ES", "ru-RU"
            ],
            targetLanguage: Locale.Language = Locale.Language(identifier: "zh-Hans"),
            sourceLanguage: Locale.Language? = nil,
            minimumConfidence: Float = 0.3,
            preferredFontFamily: String? = nil
        ) {
            self.recognitionLanguages = recognitionLanguages
            self.targetLanguage = targetLanguage
            self.sourceLanguage = sourceLanguage
            self.minimumConfidence = minimumConfidence
            self.preferredFontFamily = preferredFontFamily
        }
    }

    public let configuration: Configuration
    public let translator: TranslationService
    public let inpainter: InpaintingService

    public init(
        configuration: Configuration = .init(),
        translator: TranslationService = IdentityTranslationService(),
        inpainter: InpaintingService = EdgeSampleInpaintingService()
    ) {
        self.configuration = configuration
        self.translator = translator
        self.inpainter = inpainter
    }

    // MARK: Public entry point

    /// Run the full pipeline on a background priority. The returned
    /// `NSImage` matches the original pixel size.
    public func process(_ image: NSImage) async throws -> ImageTextTranslationResult {
        guard
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw ImageTextTranslationError.invalidImage }

        // Step 1: detect.
        let elements = try await detectText(in: cgImage)

        guard !elements.isEmpty else {
            return ImageTextTranslationResult(
                translatedImage: image,
                elements: []
            )
        }

        // Step 2 + 4 in parallel: style extraction is CPU-bound on the
        // image, translation is typically I/O-bound.
        async let stylesTask = extractStyles(from: cgImage, elements: elements)
        async let translationsTask: [String] = {
            do {
                return try await translator.translate(
                    elements.map(\.string),
                    from: configuration.sourceLanguage,
                    to: configuration.targetLanguage
                )
            } catch {
                throw ImageTextTranslationError.translationFailed(underlying: error)
            }
        }()

        let styles = try await stylesTask
        let translations = try await translationsTask

        // Step 3: inpaint the original text rectangles.
        let cleaned = try await inpainter.inpaint(
            image: cgImage,
            removing: elements.map(\.pixelRect)
        )

        // Step 5: render translations into the cleaned image.
        let translated = try await render(
            base: cleaned,
            elements: elements,
            styles: styles,
            translations: translations
        )

        let nsImage = NSImage(
            cgImage: translated,
            size: NSSize(width: translated.width, height: translated.height)
        )

        let pairs = zip(zip(elements, styles), translations).map { pair, t in
            TranslatedTextElement(element: pair.0, translation: t, style: pair.1)
        }

        return ImageTextTranslationResult(translatedImage: nsImage, elements: pairs)
    }

    // MARK: Step 1 — Vision text recognition

    private func detectText(in cgImage: CGImage) async throws -> [TextElement] {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let languages = configuration.recognitionLanguages
        let minConfidence = configuration.minimumConfidence

        return try await withCheckedThrowingContinuation { cont in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    cont.resume(
                        throwing: ImageTextTranslationError.visionFailed(underlying: error)
                    )
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let elements = observations.compactMap { obs -> TextElement? in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    guard candidate.confidence >= minConfidence else { return nil }
                    let trimmed = candidate.string
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return nil }

                    let bb = obs.boundingBox  // bottom-left, normalized
                    let pixelRect = CGRect(
                        x: bb.origin.x * width,
                        y: (1 - bb.origin.y - bb.height) * height,
                        width: bb.width * width,
                        height: bb.height * height
                    ).integral

                    return TextElement(
                        string: candidate.string,
                        pixelRect: pixelRect,
                        visionRect: bb,
                        confidence: candidate.confidence
                    )
                }
                cont.resume(returning: elements)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    cont.resume(
                        throwing: ImageTextTranslationError.visionFailed(underlying: error)
                    )
                }
            }
        }
    }

    // MARK: Step 2 — Style & background extraction

    private func extractStyles(
        from cgImage: CGImage,
        elements: [TextElement]
    ) async throws -> [TextStyle] {
        try await Task.detached(priority: .userInitiated) {
            guard let sampler = ImagePixelSampler(cgImage: cgImage) else {
                let fallback = TextStyle(
                    foreground: CGColor(gray: 0, alpha: 1),
                    background: CGColor(gray: 1, alpha: 1),
                    pointSize: 16,
                    weight: .regular
                )
                return Array(repeating: fallback, count: elements.count)
            }
            return elements.map { el in
                let (fg, bg) = sampler.foregroundBackground(in: el.pixelRect.integral)
                // Heuristic: cap height affects point size. Vision rects
                // are tight to glyph extents, so use ~0.8 of rect height.
                let point = max(8, el.pixelRect.height * 0.8)
                let weight = Self.estimateWeight(for: el.pixelRect.height)
                return TextStyle(
                    foreground: fg,
                    background: bg,
                    pointSize: point,
                    weight: weight
                )
            }
        }.value
    }

    private static func estimateWeight(for height: CGFloat) -> NSFont.Weight {
        // Without stroke-width analysis we just default to regular.
        // Hook for future improvement.
        _ = height
        return .regular
    }

    // MARK: Step 5 — Core Text rendering

    private func render(
        base: CGImage,
        elements: [TextElement],
        styles: [TextStyle],
        translations: [String]
    ) async throws -> CGImage {
        let preferredFamily = configuration.preferredFontFamily
        return try await Task.detached(priority: .userInitiated) {
            try Self.draw(
                base: base,
                elements: elements,
                styles: styles,
                translations: translations,
                preferredFamily: preferredFamily
            )
        }.value
    }

    private static func draw(
        base: CGImage,
        elements: [TextElement],
        styles: [TextStyle],
        translations: [String],
        preferredFamily: String?
    ) throws -> CGImage {
        let width = base.width
        let height = base.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { throw ImageTextTranslationError.contextCreationFailed }

        // CGContext native origin = bottom-left. We flip the CTM so we
        // can think in top-left coords, matching NSImage / pixelRect.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        // Draw the cleaned base image (also using top-left coords now).
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))

        for (index, element) in elements.enumerated() {
            let style = styles[index]
            let text = translations[index]
            guard !text.isEmpty else { continue }

            drawCenteredText(
                text,
                in: element.pixelRect,
                style: style,
                preferredFamily: preferredFamily,
                in: context
            )
        }

        guard let output = context.makeImage() else {
            throw ImageTextTranslationError.renderingFailed
        }
        return output
    }

    private static func drawCenteredText(
        _ text: String,
        in rect: CGRect,
        style: TextStyle,
        preferredFamily: String?,
        in context: CGContext
    ) {
        // Build the font, shrinking until the line fits horizontally.
        let baseFont: NSFont = {
            if let family = preferredFamily,
               let font = NSFont(name: family, size: style.pointSize) {
                return font
            }
            return NSFont.systemFont(ofSize: style.pointSize, weight: style.weight)
        }()

        var pointSize = baseFont.pointSize
        let minPointSize: CGFloat = 6
        var attributedString = makeAttributed(
            text: text,
            font: baseFont,
            color: style.foreground.cgColor
        )
        var line = CTLineCreateWithAttributedString(attributedString)
        var bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

        while bounds.width > rect.width && pointSize > minPointSize {
            pointSize = max(minPointSize, pointSize - 1)
            let resized: NSFont
            if let family = preferredFamily,
               let f = NSFont(name: family, size: pointSize) {
                resized = f
            } else {
                resized = NSFont.systemFont(ofSize: pointSize, weight: style.weight)
            }
            attributedString = makeAttributed(
                text: text,
                font: resized,
                color: style.foreground.cgColor
            )
            line = CTLineCreateWithAttributedString(attributedString)
            bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        }

        // Center the line in `rect`. Our context is flipped to top-left
        // origin, but Core Text always draws upward from the text
        // baseline in *its own* coordinate system. To compensate, save,
        // re-flip locally, draw, restore.
        context.saveGState()

        let centerX = rect.midX - bounds.width / 2 - bounds.origin.x
        let centerY = rect.midY - bounds.height / 2 - bounds.origin.y

        // Re-flip so Core Text draws right-side-up.
        context.translateBy(x: 0, y: rect.midY * 2)
        context.scaleBy(x: 1, y: -1)

        context.textPosition = CGPoint(x: centerX, y: centerY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func makeAttributed(
        text: String,
        font: NSFont,
        color: CGColor
    ) -> CFAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? NSColor.labelColor
        ]
        return NSAttributedString(string: text, attributes: attrs) as CFAttributedString
    }
}

// MARK: - Optional: Apple Translation framework adapter (macOS 15+)

#if canImport(Translation)
/// Wraps Apple's on-device `Translation` framework. Requires the host
/// view to present a `.translationTask` modifier; for a non-UI service
/// you typically use `TranslationSession.translate(_:)` from a
/// SwiftUI bridge. This is provided as a sketch — Apple's API requires
/// a SwiftUI `TranslationSession.Configuration`, so production code
/// should drive it from the view layer.
@available(macOS 15.0, *)
public struct AppleTranslationServiceStub: TranslationService {
    public init() {}
    public func translate(
        _ strings: [String],
        from _: Locale.Language?,
        to _: Locale.Language
    ) async throws -> [String] {
        // Real integration: the Translation framework requires a
        // `TranslationSession` provided by SwiftUI's `.translationTask`
        // modifier. Bridge it from your view and inject the session
        // into a custom TranslationService implementation instead of
        // calling this stub.
        return strings
    }
}
#endif

// MARK: - Pixel sampler

/// Minimal pixel sampler used by both inpainting and style extraction.
/// Uses a single ARGB premultiplied buffer drawn once, then random-
/// access reads via byte offsets.
final class ImagePixelSampler {
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int
    private let buffer: [UInt8]

    init?(cgImage: CGImage) {
        let w = cgImage.width
        let h = cgImage.height
        let bpr = w * 4
        var data = [UInt8](repeating: 0, count: bpr * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = data.withUnsafeMutableBytes({ ptr -> CGContext? in
            CGContext(
                data: ptr.baseAddress,
                width: w, height: h,
                bitsPerComponent: 8,
                bytesPerRow: bpr,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        self.width = w
        self.height = h
        self.bytesPerRow = bpr
        self.buffer = data
    }

    /// Returns the pixel at (x, y) using *top-left* coordinates.
    func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        // Our buffer was filled by a CGContext, which has bottom-left
        // origin. Flip y for top-left lookup.
        let by = height - 1 - y
        let offset = by * bytesPerRow + x * 4
        return (buffer[offset], buffer[offset + 1], buffer[offset + 2], buffer[offset + 3])
    }

    /// Median border colour just outside `rect` (top-left coords).
    func borderMedianColor(around rect: CGRect, inset: Int) -> CGColor? {
        let r = rect.integral
        let xs = stride(
            from: max(0, Int(r.minX) - inset),
            to: min(width, Int(r.maxX) + inset),
            by: max(1, inset)
        )
        let ys = stride(
            from: max(0, Int(r.minY) - inset),
            to: min(height, Int(r.maxY) + inset),
            by: max(1, inset)
        )

        var samples: [(UInt8, UInt8, UInt8)] = []
        samples.reserveCapacity(2 * (xs.underestimatedCount + ys.underestimatedCount))

        // Top + bottom strips
        for x in xs {
            for offset in [-inset, inset] {
                if let p = pixel(x: x, y: Int(r.minY) + offset) {
                    samples.append((p.r, p.g, p.b))
                }
                if let p = pixel(x: x, y: Int(r.maxY) + offset) {
                    samples.append((p.r, p.g, p.b))
                }
            }
        }
        // Left + right strips
        for y in ys {
            for offset in [-inset, inset] {
                if let p = pixel(x: Int(r.minX) + offset, y: y) {
                    samples.append((p.r, p.g, p.b))
                }
                if let p = pixel(x: Int(r.maxX) + offset, y: y) {
                    samples.append((p.r, p.g, p.b))
                }
            }
        }

        guard !samples.isEmpty else { return nil }
        let r2 = median(samples.map { CGFloat($0.0) }) / 255.0
        let g2 = median(samples.map { CGFloat($0.1) }) / 255.0
        let b2 = median(samples.map { CGFloat($0.2) }) / 255.0
        return CGColor(red: r2, green: g2, blue: b2, alpha: 1)
    }

    /// Foreground / background pair for `rect` (top-left coords).
    /// Background = median border colour. Foreground = most-distant
    /// inner colour from background.
    func foregroundBackground(in rect: CGRect) -> (fg: CGColor, bg: CGColor) {
        let bg = borderMedianColor(around: rect, inset: 2)
            ?? CGColor(gray: 1, alpha: 1)

        let r = rect.integral
        var farthest: (dist: CGFloat, rgb: (CGFloat, CGFloat, CGFloat)) = (
            -1, (0, 0, 0)
        )
        let bgComps = bg.components ?? [1, 1, 1, 1]
        let bgR = bgComps[0], bgG = bgComps[1], bgB = bgComps[2]

        let step = max(1, Int(min(r.width, r.height) / 12))
        var x = Int(r.minX)
        while x < Int(r.maxX) {
            var y = Int(r.minY)
            while y < Int(r.maxY) {
                if let p = pixel(x: x, y: y) {
                    let pr = CGFloat(p.r) / 255.0
                    let pg = CGFloat(p.g) / 255.0
                    let pb = CGFloat(p.b) / 255.0
                    let dr = pr - bgR, dg = pg - bgG, db = pb - bgB
                    let d = dr * dr + dg * dg + db * db
                    if d > farthest.dist {
                        farthest = (d, (pr, pg, pb))
                    }
                }
                y += step
            }
            x += step
        }

        let fg = CGColor(
            red: farthest.rgb.0,
            green: farthest.rgb.1,
            blue: farthest.rgb.2,
            alpha: 1
        )
        return (fg, bg)
    }

    private func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
