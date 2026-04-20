//
//  ScrollCaptureSession.swift
//  StackShot
//
//  Scroll-capture: overlay a capture region on screen, let the user
//  scroll / interact with the underlying app, and continuously stitch
//  captured frames into a long screenshot.
//
//  Architecture:
//    ScrollCaptureSession  – top-level coordinator; owned by AnnotationEditorPanel.
//    ScrollCaptureOverlay  – borderless full-screen window with a
//                            translucent mask and a bright cut-out.
//    ScrollCapturePreview  – floating panel on the right showing the
//                            growing stitched image.
//    ScrollImageStitcher   – pure-image logic that detects overlap
//                            between the previous tail and a new frame,
//                            then appends the non-redundant slice.
//
//  Coordinate systems:
//    • The `captureRect` given to ScrollCaptureSession is in AppKit
//      screen coordinates (origin bottom-left).
//    • CGWindowListCreateImage uses Quartz coordinates (origin top-left).
//      We convert with `quartzRect(from:)`.
//

import AppKit
import CoreGraphics
import QuartzCore

// MARK: - Session coordinator

final class ScrollCaptureSession {

    /// Called when the user finishes (clicks Done or presses Enter/Esc).
    /// Passes the stitched long image, or `nil` if cancelled / empty.
    var onFinish: ((NSImage?) -> Void)?

    /// The capture region in AppKit screen coordinates.
    private let captureRect: CGRect
    /// Pixel-snapped Quartz rect used by CGWindowListCreateImage.
    private let quartzCaptureRect: CGRect
    private let backingScale: CGFloat

    private var overlay: ScrollCaptureOverlay?
    private var preview: ScrollCapturePreview?
    private var stitcher = ScrollImageStitcher()
    private var captureTimer: Timer?
    private var isRunning = false

    /// IDs of our own windows – excluded from captures so they never
    /// appear in the stitched result.
    private var ownWindowIDs: Set<CGWindowID> = []

    init(captureRect: CGRect) {
        self.captureRect = captureRect
        self.backingScale = NSScreen.screens
            .first(where: { $0.frame.contains(captureRect.center) })?
            .backingScaleFactor ?? 2.0
        self.quartzCaptureRect = Self.quartzRect(from: captureRect, scale: backingScale)
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // 1. Create overlay (dimmed region with bright cut-out).
        let ov = ScrollCaptureOverlay(captureRect: captureRect)
        ov.onDone = { [weak self] in self?.finish() }
        ov.onCancel = { [weak self] in self?.cancel() }
        ov.orderFrontRegardless()
        overlay = ov

        // 2. Preview panel to the right of the capture rect.
        let pv = ScrollCapturePreview(anchorRect: captureRect)
        pv.orderFrontRegardless()
        preview = pv

        // Record our own window IDs so we can exclude them.
        ownWindowIDs = []
        if let ovNum = ov.windowNumber as? Int, ovNum > 0 {
            ownWindowIDs.insert(CGWindowID(ovNum))
        }
        if let pvNum = pv.windowNumber as? Int, pvNum > 0 {
            ownWindowIDs.insert(CGWindowID(pvNum))
        }

        // 3. Capture the initial frame immediately, then start a timer.
        captureFrame()
        captureTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.captureFrame()
        }
    }

    func finish() {
        guard isRunning else { return }
        isRunning = false
        captureTimer?.invalidate()
        captureTimer = nil
        overlay?.orderOut(nil); overlay = nil
        preview?.orderOut(nil); preview = nil

        let image = stitcher.result
        onFinish?(image)
    }

    func cancel() {
        guard isRunning else { return }
        isRunning = false
        captureTimer?.invalidate()
        captureTimer = nil
        overlay?.orderOut(nil); overlay = nil
        preview?.orderOut(nil); preview = nil
        onFinish?(nil)
    }

    // MARK: Frame capture

    private func captureFrame() {
        guard isRunning else { return }

        // Capture only windows that are *not* ours, so the overlay /
        // preview never leak into the long image.
        //
        // Strategy: capture the region "on screen below" our overlay by
        // using .optionOnScreenBelowWindow with the overlay's windowID.
        // This gives us exactly what the user sees underneath.
        let listOption: CGWindowListOption
        let relativeToWID: CGWindowID
        if let ovNum = overlay?.windowNumber, ovNum > 0 {
            listOption = [.optionOnScreenBelowWindow, .excludeDesktopElements]
            relativeToWID = CGWindowID(ovNum)
        } else {
            listOption = .optionOnScreenOnly
            relativeToWID = kCGNullWindowID
        }

        guard let cgImage = CGWindowListCreateImage(
            quartzCaptureRect,
            listOption,
            relativeToWID,
            .bestResolution
        ) else { return }

        guard cgImage.width > 1, cgImage.height > 1 else { return }

        let changed = stitcher.appendFrame(cgImage)
        if changed, let result = stitcher.result {
            preview?.updateImage(result)
        }
    }

    // MARK: Coordinate conversion

    /// Convert an AppKit screen rect (origin bottom-left) to a Quartz
    /// rect (origin top-left) used by CGWindowListCreateImage.
    private static func quartzRect(from appKitRect: CGRect, scale: CGFloat) -> CGRect {
        let desktopBounds = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        guard !desktopBounds.isNull else { return appKitRect }

        // Snap to device pixels.
        let x = floor(appKitRect.origin.x * scale) / scale
        let w = ceil(appKitRect.width * scale) / scale
        let h = ceil(appKitRect.height * scale) / scale
        let y = floor((desktopBounds.maxY - appKitRect.maxY) * scale) / scale

        return CGRect(x: x, y: y, width: w, height: h)
    }
}

// MARK: - Overlay window

/// Full-screen borderless overlay: everything dimmed except the capture
/// rectangle, which is punched out (fully transparent) so the user sees
/// the underlying app at normal brightness and can interact with it
/// (scroll, click, etc.).
///
/// A small "Done" / "Cancel" control strip is drawn just below the
/// cut-out region.
private final class ScrollCaptureOverlay: NSPanel {

    var onDone:   (() -> Void)?
    var onCancel: (() -> Void)?

    private let captureRect: CGRect // AppKit screen coords

    init(captureRect: CGRect) {
        self.captureRect = captureRect
        let unionFrame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        super.init(
            contentRect: unionFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        worksWhenModal = true
        // The overlay lets mouse events pass through the bright region.
        ignoresMouseEvents = false

        let overlayView = ScrollCaptureOverlayView(
            frame: NSRect(origin: .zero, size: unionFrame.size),
            captureRect: captureRect.offsetBy(
                dx: -unionFrame.origin.x,
                dy: -unionFrame.origin.y
            ),
            onDone: { [weak self] in self?.onDone?() },
            onCancel: { [weak self] in self?.onCancel?() }
        )
        contentView = overlayView
    }
}

/// Custom view that draws a dimmed overlay with a punched-out bright
/// rectangle and a control strip.
private final class ScrollCaptureOverlayView: NSView {
    private let captureRect: CGRect   // in view-local coords
    private let onDone:   () -> Void
    private let onCancel: () -> Void
    private var doneButton: NSButton?
    private var cancelButton: NSButton?
    private var controlStrip: NSView?

    init(frame: NSRect,
         captureRect: CGRect,
         onDone: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.captureRect = captureRect
        self.onDone = onDone
        self.onCancel = onCancel
        super.init(frame: frame)
        wantsLayer = true
        setupControls()
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        // 1. Dim the entire screen.
        NSColor.black.withAlphaComponent(0.35).setFill()
        NSBezierPath(rect: bounds).fill()

        // 2. Punch out the capture region (clear).
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(rect: captureRect).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        // 3. Draw a thin blue border around the capture region.
        let borderPath = NSBezierPath(rect: captureRect.insetBy(dx: -1.5, dy: -1.5))
        borderPath.lineWidth = 2
        NSColor.systemBlue.withAlphaComponent(0.8).setStroke()
        borderPath.stroke()
    }

    // Mouse events: forward clicks inside the capture region to the
    // underlying app. Block clicks outside (they land on our overlay).
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let buttons handle their own hits.
        if let btn = doneButton, btn.frame.contains(point) { return btn }
        if let btn = cancelButton, btn.frame.contains(point) { return btn }
        // Inside the capture rect → pass through.
        if captureRect.contains(point) { return nil }
        // Outside → absorb (don't forward).
        return self
    }

    override func mouseDown(with event: NSEvent) {
        // Absorb clicks on the dimmed area – do nothing.
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return, Enter
            onDone()
        case 53:     // Escape
            onCancel()
        default:
            super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Control strip

    private func setupControls() {
        let strip = NSView(frame: .zero)
        strip.wantsLayer = true
        strip.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        strip.layer?.cornerRadius = 8

        let done = makeButton(
            title: ScrollCaptureL10n.tr(.done),
            color: .systemBlue,
            action: #selector(doneTapped)
        )
        let cancel = makeButton(
            title: ScrollCaptureL10n.tr(.cancel),
            color: .systemRed,
            action: #selector(cancelTapped)
        )

        let stack = NSStackView(views: [cancel, done])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        strip.addSubview(stack)
        strip.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: strip.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: strip.bottomAnchor, constant: -6),
        ])

        addSubview(strip)
        NSLayoutConstraint.activate([
            strip.centerXAnchor.constraint(equalTo: leadingAnchor, constant: captureRect.midX),
            strip.topAnchor.constraint(equalTo: bottomAnchor,
                                       constant: -(captureRect.minY - 12)),
        ])

        // The strip sits just below the capture rect in flipped-ish layout.
        // Since NSView is not flipped, captureRect.minY is the bottom edge.
        let stripY = captureRect.minY - 48
        strip.frame = CGRect(x: captureRect.midX - 80, y: stripY, width: 160, height: 36)

        self.doneButton = done
        self.cancelButton = cancel
        self.controlStrip = strip
    }

    override func layout() {
        super.layout()
        // Re-position the strip below the capture rect.
        if let strip = controlStrip {
            let fitted = strip.fittingSize
            let w = max(fitted.width + 24, 160)
            let h = max(fitted.height + 12, 36)
            strip.frame = CGRect(
                x: captureRect.midX - w / 2,
                y: captureRect.minY - h - 10,
                width: w,
                height: h
            )
        }
    }

    private func makeButton(title: String, color: NSColor, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .rounded
        btn.controlSize = .regular
        btn.contentTintColor = color
        btn.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        return btn
    }

    @objc private func doneTapped()   { onDone() }
    @objc private func cancelTapped() { onCancel() }
}

// MARK: - Preview panel

/// Floating preview of the growing long screenshot, displayed to the
/// right of the capture region.
private final class ScrollCapturePreview: NSPanel {

    private let imageView: NSImageView
    private let scrollView: NSScrollView
    private let anchorRect: CGRect
    private static let previewWidth: CGFloat = 180
    private static let maxHeight: CGFloat = 600

    init(anchorRect: CGRect) {
        self.anchorRect = anchorRect

        let previewFrame = Self.previewFrame(for: anchorRect, imageAspect: 1)

        imageView = NSImageView(frame: NSRect(origin: .zero, size: previewFrame.size))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        scrollView = NSScrollView(frame: NSRect(origin: .zero, size: previewFrame.size))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = imageView
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false

        super.init(
            contentRect: previewFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.65)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        isFloatingPanel = true
        worksWhenModal = true

        contentView = scrollView
    }

    func updateImage(_ image: NSImage) {
        imageView.image = image

        // Resize so the preview stays within bounds.
        let aspect = image.size.height / max(1, image.size.width)
        let newFrame = Self.previewFrame(for: anchorRect, imageAspect: aspect)
        setFrame(newFrame, display: true, animate: false)

        // Update document view size so scrolling works.
        let docW = newFrame.width
        let docH = docW * aspect
        imageView.frame = NSRect(x: 0, y: 0, width: docW, height: docH)
        scrollView.documentView?.frame = imageView.frame

        // Auto-scroll to the bottom to show the latest content.
        if let docView = scrollView.documentView {
            let bottomPoint = NSPoint(x: 0, y: docView.frame.height - scrollView.contentSize.height)
            scrollView.contentView.scroll(to: bottomPoint)
        }
    }

    private static func previewFrame(for anchor: CGRect, imageAspect: CGFloat) -> CGRect {
        let pw = previewWidth
        let ph = min(maxHeight, max(120, pw * imageAspect))
        let x = anchor.maxX + 16
        let y = anchor.midY - ph / 2
        return CGRect(x: x, y: y, width: pw, height: ph)
    }
}

// MARK: - Image stitcher

/// Detects overlap between consecutive frames of the same region and
/// builds a growing "long screenshot" by appending only the new
/// (non-overlapping) portion of each new frame.
///
/// **Algorithm overview** (vertical scrolling, the common case):
///
/// 1. Compare the bottom `N` rows of the **accumulated image** with
///    the top `N` rows of the **new frame** to find the best-matching
///    vertical offset. A row is compared by a fast "signature" (sample
///    ~40 evenly-spaced pixel luminances, pack into [UInt8]).
/// 2. If the best match score exceeds a threshold, treat the
///    corresponding offset as the overlap amount.
/// 3. Slice the new frame below the overlap and append it to the
///    accumulated image.
///
/// All work happens on the **caller's thread** (synchronous). The
/// capture timer fires on the main thread at ~3 fps, which is fast
/// enough for a smooth experience and light enough to avoid frame drops.
struct ScrollImageStitcher {

    /// The accumulated long image so far.
    private(set) var result: NSImage?

    /// Raw accumulated CGImage (for pixel comparison).
    private var accumulatedCG: CGImage?

    /// Signature of the bottom rows of the accumulated image, cached to
    /// avoid re-computing every frame.
    private var tailSignatures: [RowSignature] = []

    /// How many rows at the bottom of the accumulated image / top of a
    /// new frame to compare.
    private let overlapSearchRows = 200

    /// Minimum match score (0-1) to accept an overlap. Below this the
    /// frame is either identical or completely different.
    private let matchThreshold: Double = 0.92

    /// Number of sample pixels per row for the signature.
    private let samplesPerRow = 40

    /// Returns `true` if the result changed (i.e. new content was
    /// appended).
    @discardableResult
    mutating func appendFrame(_ frame: CGImage) -> Bool {
        guard let accumulated = accumulatedCG else {
            // First frame – just store it.
            accumulatedCG = frame
            result = nsImage(from: frame)
            tailSignatures = bottomSignatures(of: frame, rows: overlapSearchRows)
            return true
        }

        // Width must match (we're capturing the same region).
        guard frame.width == accumulated.width else { return false }

        let newTopSigs = topSignatures(of: frame, rows: overlapSearchRows)

        // Find the overlap: compare tail of accumulated with top of new.
        let overlap = findOverlap(tailSigs: tailSignatures, newTopSigs: newTopSigs)

        if let overlap, overlap >= frame.height {
            // Completely duplicate frame.
            return false
        }

        let newRows: Int
        if let overlap {
            newRows = frame.height - overlap
        } else {
            // No overlap detected – append entirely (user might have
            // scrolled a full page or more in one go).
            newRows = frame.height
        }

        guard newRows > 0 else { return false }

        // Crop the new slice from the bottom of the frame.
        let sliceRect = CGRect(x: 0, y: frame.height - newRows, width: frame.width, height: newRows)
        guard let slice = frame.cropping(to: sliceRect) else { return false }

        // Append slice below the accumulated image.
        let totalHeight = accumulated.height + newRows
        let width = accumulated.width
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: totalHeight,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return false }

        // CGContext has bottom-left origin. The accumulated image goes
        // at the top (i.e. at y = newRows), the new slice at y = 0.
        ctx.draw(accumulated, in: CGRect(x: 0, y: newRows, width: width, height: accumulated.height))
        ctx.draw(slice, in: CGRect(x: 0, y: 0, width: width, height: newRows))

        guard let combined = ctx.makeImage() else { return false }
        accumulatedCG = combined
        result = nsImage(from: combined)
        tailSignatures = bottomSignatures(of: combined, rows: overlapSearchRows)
        return true
    }

    // MARK: Row signatures

    private typealias RowSignature = [UInt8]

    /// Generate signatures for the bottom `rows` of an image.
    private func bottomSignatures(of image: CGImage, rows: Int) -> [RowSignature] {
        guard let data = pixelData(of: image) else { return [] }
        let h = image.height
        let w = image.width
        let startRow = max(0, h - rows)
        return (startRow..<h).map { row in
            rowSignature(data: data, row: row, width: w)
        }
    }

    /// Generate signatures for the top `rows` of an image.
    private func topSignatures(of image: CGImage, rows: Int) -> [RowSignature] {
        guard let data = pixelData(of: image) else { return [] }
        let w = image.width
        let endRow = min(image.height, rows)
        return (0..<endRow).map { row in
            rowSignature(data: data, row: row, width: w)
        }
    }

    /// Sample ~`samplesPerRow` evenly-spaced pixel luminances from one
    /// row, producing a lightweight "fingerprint".
    private func rowSignature(data: UnsafePointer<UInt8>, row: Int, width: Int) -> RowSignature {
        let bpp = 4 // RGBA
        let rowOffset = row * width * bpp
        let step = max(1, width / samplesPerRow)
        var sig = RowSignature()
        sig.reserveCapacity(samplesPerRow)
        var x = 0
        while x < width, sig.count < samplesPerRow {
            let idx = rowOffset + x * bpp
            // Luminance ≈ 0.299R + 0.587G + 0.114B, quantised to UInt8.
            let r = Int(data[idx])
            let g = Int(data[idx + 1])
            let b = Int(data[idx + 2])
            let lum = UInt8(clamping: (r * 77 + g * 150 + b * 29) >> 8)
            sig.append(lum)
            x += step
        }
        return sig
    }

    /// Find the vertical overlap between the tail of the accumulated
    /// image (bottom N rows) and the top of a new frame.
    ///
    /// Returns `nil` if no confident match is found.
    private func findOverlap(
        tailSigs: [RowSignature],
        newTopSigs: [RowSignature]
    ) -> Int? {
        // `tailSigs` is bottom rows of accumulated (index 0 = topmost of those rows).
        // `newTopSigs` is top rows of new frame   (index 0 = topmost row of new frame).
        //
        // An overlap of `k` means: tail's last `k` rows match new's first `k` rows.
        // That is: tailSigs[tailSigs.count - k ..< tailSigs.count] ≈ newTopSigs[0 ..< k].

        let maxOverlap = min(tailSigs.count, newTopSigs.count)
        guard maxOverlap > 0 else { return nil }

        var bestOverlap = 0
        var bestScore: Double = 0

        // Start from larger overlaps (more reliable) and short-circuit.
        let minOverlap = max(4, maxOverlap / 20) // need at least a few rows
        for k in stride(from: maxOverlap, through: minOverlap, by: -1) {
            let score = compareRows(
                a: tailSigs, aStart: tailSigs.count - k,
                b: newTopSigs, bStart: 0,
                count: k
            )
            if score > bestScore {
                bestScore = score
                bestOverlap = k
            }
            // Early exit: a very high score at a large overlap is
            // almost certainly the correct one.
            if bestScore > 0.97 { break }
        }

        return bestScore >= matchThreshold ? bestOverlap : nil
    }

    /// Average row-level similarity score for `count` pairs of rows.
    private func compareRows(
        a: [RowSignature], aStart: Int,
        b: [RowSignature], bStart: Int,
        count: Int
    ) -> Double {
        guard count > 0 else { return 0 }
        var total: Double = 0
        for i in 0..<count {
            total += rowSimilarity(a[aStart + i], b[bStart + i])
        }
        return total / Double(count)
    }

    /// Similarity of two row signatures. Returns 1.0 for identical, 0.0
    /// for maximally different.
    private func rowSimilarity(_ a: RowSignature, _ b: RowSignature) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var sumDiff = 0
        for i in 0..<n {
            sumDiff += abs(Int(a[i]) - Int(b[i]))
        }
        let avgDiff = Double(sumDiff) / Double(n)
        return max(0, 1.0 - avgDiff / 255.0)
    }

    // MARK: Helpers

    /// Read raw RGBA pixel data from a CGImage. The returned pointer is
    /// only valid for the duration of the enclosing scope (backed by a
    /// `CFData` we retain as long as the caller holds the reference).
    private func pixelData(of image: CGImage) -> UnsafePointer<UInt8>? {
        // Render into a known RGBA layout.
        let w = image.width
        let h = image.height
        let bpr = w * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: bpr,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        return UnsafePointer(data.assumingMemoryBound(to: UInt8.self))
    }

    private func nsImage(from cg: CGImage) -> NSImage {
        NSImage(
            cgImage: cg,
            size: NSSize(width: cg.width, height: cg.height)
        )
    }
}

// MARK: - Localization

fileprivate enum ScrollCaptureL10nKey {
    case done
    case cancel
    case toolScrollCapture
}

enum ScrollCaptureL10n {
    fileprivate static func tr(_ key: ScrollCaptureL10nKey) -> String {
        let locale = L10n.currentSelectionCode()
        switch locale {
        case "zh-Hans": return zhHans[key] ?? en[key] ?? ""
        case "zh-Hant": return zhHant[key] ?? en[key] ?? ""
        case "ja":      return ja[key] ?? en[key] ?? ""
        default:        return en[key] ?? ""
        }
    }

    private static let zhHans: [ScrollCaptureL10nKey: String] = [
        .done: "完成",
        .cancel: "取消",
        .toolScrollCapture: "滚动截图",
    ]
    private static let zhHant: [ScrollCaptureL10nKey: String] = [
        .done: "完成",
        .cancel: "取消",
        .toolScrollCapture: "捲動截圖",
    ]
    private static let en: [ScrollCaptureL10nKey: String] = [
        .done: "Done",
        .cancel: "Cancel",
        .toolScrollCapture: "Scroll Capture",
    ]
    private static let ja: [ScrollCaptureL10nKey: String] = [
        .done: "完了",
        .cancel: "キャンセル",
        .toolScrollCapture: "スクロールキャプチャ",
    ]
}

// MARK: - Helpers

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
