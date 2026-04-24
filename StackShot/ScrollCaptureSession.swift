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
    private var controls: ScrollCaptureControlPanel?
    private var stitcher: ScrollImageStitcher
    private var captureTimer: Timer?
    private var isRunning = false
    private var keyMonitor: Any?

    /// IDs of our own windows – excluded from captures so they never
    /// appear in the stitched result.
    private var ownWindowIDs: Set<CGWindowID> = []

    init(captureRect: CGRect) {
        self.captureRect = captureRect
        self.backingScale = NSScreen.screens
            .first(where: { $0.frame.contains(captureRect.center) })?
            .backingScaleFactor ?? 2.0
        self.quartzCaptureRect = Self.quartzRect(from: captureRect, scale: backingScale)
        self.stitcher = ScrollImageStitcher(backingScale: backingScale)
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // 1. Visual-only overlay (mouse events pass through entirely so
        //    the user can click / scroll the underlying app naturally).
        let ov = ScrollCaptureOverlay(captureRect: captureRect)
        ov.orderFrontRegardless()
        overlay = ov

        // 2. Preview panel beside the capture rect.
        let pv = ScrollCapturePreview(anchorRect: captureRect)
        pv.orderFrontRegardless()
        preview = pv

        // 3. Floating Done / Cancel controls. This is a separate
        //    `nonactivatingPanel` so it can receive its own clicks
        //    without stealing focus from the underlying app being
        //    scrolled.
        let ctl = ScrollCaptureControlPanel(
            anchorRect: captureRect,
            onDone:   { [weak self] in self?.finish() },
            onCancel: { [weak self] in self?.cancel() }
        )
        ctl.orderFrontRegardless()
        controls = ctl

        // Local key monitor (Esc → cancel, Return → finish) – only
        // fires when our app happens to be active. We deliberately
        // don't register a global monitor because that would require
        // the user to grant Accessibility permission.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isRunning else { return event }
            switch event.keyCode {
            case 36, 76: self.finish();  return nil
            case 53:     self.cancel();  return nil
            default:     return event
            }
        }

        // Record our own window IDs so we can exclude them.
        ownWindowIDs = []
        for win in [ov, pv, ctl] {
            let num = win.windowNumber
            if num > 0 { ownWindowIDs.insert(CGWindowID(num)) }
        }

        // 4. Capture the initial frame immediately, then start a timer.
        captureFrame()
        captureTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.captureFrame()
        }
    }

    func finish() {
        guard isRunning else { return }
        isRunning = false
        teardownSessionWindows()
        let image = stitcher.result
        onFinish?(image)
    }

    func cancel() {
        guard isRunning else { return }
        isRunning = false
        teardownSessionWindows()
        onFinish?(nil)
    }

    private func teardownSessionWindows() {
        captureTimer?.invalidate()
        captureTimer = nil
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        overlay?.orderOut(nil);  overlay  = nil
        preview?.orderOut(nil);  preview  = nil
        controls?.orderOut(nil); controls = nil
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

        let outcome = stitcher.appendFrame(cgImage)
        if outcome == .appended, let result = stitcher.result {
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

/// Full-screen borderless overlay drawn purely for visual feedback:
/// dims everything except the capture rectangle so the user can see
/// exactly which region is being captured.
///
/// The window is **completely transparent to mouse events** – it does
/// not interfere with clicking, dragging or scrolling any underlying
/// app. The Done / Cancel controls live in a separate
/// `ScrollCaptureControlPanel`.
private final class ScrollCaptureOverlay: NSPanel {

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
        worksWhenModal = false
        // Crucial: every mouse event flows straight through to whatever
        // is underneath, so the user can scroll / click target windows.
        ignoresMouseEvents = true

        let view = ScrollCaptureOverlayView(
            frame: NSRect(origin: .zero, size: unionFrame.size),
            captureRect: captureRect.offsetBy(
                dx: -unionFrame.origin.x,
                dy: -unionFrame.origin.y
            )
        )
        contentView = view
    }
}

/// Static visual: dimmed area + bright cut-out + thin blue border.
private final class ScrollCaptureOverlayView: NSView {
    private let captureRect: CGRect

    init(frame: NSRect, captureRect: CGRect) {
        self.captureRect = captureRect
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        // 1. Dim the entire screen.
        NSColor.black.withAlphaComponent(0.30).setFill()
        NSBezierPath(rect: bounds).fill()

        // 2. Punch out the capture region (clear).
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(rect: captureRect).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        // 3. Draw a thin blue border around the capture region.
        let borderPath = NSBezierPath(rect: captureRect.insetBy(dx: -1.5, dy: -1.5))
        borderPath.lineWidth = 2
        NSColor.systemBlue.withAlphaComponent(0.85).setStroke()
        borderPath.stroke()
    }

    // We never want this view (or its window) to absorb anything.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Control panel (Done / Cancel)

/// Small floating panel, positioned just outside the capture rect,
/// containing the Done / Cancel buttons. Lives in a separate window
/// from the overlay so the overlay can be 100% mouse-transparent.
private final class ScrollCaptureControlPanel: NSPanel {

    private let onDone:   () -> Void
    private let onCancel: () -> Void

    init(anchorRect: CGRect,
         onDone:   @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.onDone = onDone
        self.onCancel = onCancel

        let frame = Self.frame(for: anchorRect)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        ignoresMouseEvents = false
        worksWhenModal = false

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        container.layer?.cornerRadius = 10

        let cancelBtn = makeButton(
            title: ScrollCaptureL10n.tr(.cancel),
            color: .systemRed,
            action: #selector(cancelTapped)
        )
        let doneBtn = makeButton(
            title: ScrollCaptureL10n.tr(.done),
            color: .systemBlue,
            action: #selector(doneTapped)
        )
        let stack = NSStackView(views: [cancelBtn, doneBtn])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        contentView = container
    }

    /// Compute the on-screen frame for the control bar: directly under
    /// the capture rect, falling back to above when there's no room.
    private static func frame(for anchor: CGRect) -> CGRect {
        let w: CGFloat = 200
        let h: CGFloat = 40
        let screenFrame = NSScreen.screens
            .first(where: { $0.frame.intersects(anchor) })?
            .visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? anchor
        var x = anchor.midX - w / 2
        x = max(screenFrame.minX + 8, min(x, screenFrame.maxX - w - 8))
        var y = anchor.minY - h - 12
        if y < screenFrame.minY + 8 {
            y = anchor.maxY + 12
        }
        if y + h > screenFrame.maxY - 8 {
            y = screenFrame.maxY - h - 8
        }
        return CGRect(x: x, y: y, width: w, height: h)
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

    // Never become key – we don't want to steal focus from the app the
    // user is actively scrolling.
    override var canBecomeKey: Bool  { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Preview panel

/// Floating preview of the growing long screenshot. Tries to sit to the
/// right of the capture rect; falls back to the left side if that goes
/// off-screen.
private final class ScrollCapturePreview: NSPanel {

    private let imageView: NSImageView
    private let scrollView: NSScrollView
    private let titleLabel: NSTextField
    private let containerView: NSView
    private let anchorRect: CGRect

    private static let previewWidth: CGFloat = 200
    private static let titleBarHeight: CGFloat = 22
    private static let maxHeight: CGFloat = 640
    private static let minHeight: CGFloat = 140
    private static let spacing: CGFloat = 16

    init(anchorRect: CGRect) {
        self.anchorRect = anchorRect

        let initial = Self.previewFrame(for: anchorRect, imageAspect: 1)
        let contentSize = initial.size
        let scrollHeight = max(0, contentSize.height - Self.titleBarHeight)
        let scrollFrame = NSRect(x: 0, y: 0,
                                 width: contentSize.width,
                                 height: scrollHeight)

        imageView = NSImageView(frame: scrollFrame)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignTop
        imageView.translatesAutoresizingMaskIntoConstraints = false

        scrollView = NSScrollView(frame: scrollFrame)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = imageView
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]

        titleLabel = NSTextField(labelWithString: ScrollCaptureL10n.tr(.previewTitle))
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        titleLabel.alignment = .center
        titleLabel.backgroundColor = .clear
        titleLabel.drawsBackground = false
        titleLabel.frame = NSRect(
            x: 0, y: contentSize.height - Self.titleBarHeight,
            width: contentSize.width, height: Self.titleBarHeight
        )
        titleLabel.autoresizingMask = [.width, .minYMargin]

        containerView = NSView(frame: NSRect(origin: .zero, size: contentSize))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        containerView.layer?.cornerRadius = 10
        containerView.addSubview(scrollView)
        containerView.addSubview(titleLabel)

        super.init(
            contentRect: initial,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        isFloatingPanel = true
        worksWhenModal = false

        contentView = containerView
    }

    func updateImage(_ image: NSImage) {
        imageView.image = image

        let aspect = image.size.height / max(1, image.size.width)
        let newFrame = Self.previewFrame(for: anchorRect, imageAspect: aspect)
        setFrame(newFrame, display: true, animate: false)

        // Re-layout sub-views for the new size.
        containerView.frame = NSRect(origin: .zero, size: newFrame.size)
        let scrollH = max(0, newFrame.height - Self.titleBarHeight)
        scrollView.frame = NSRect(x: 0, y: 0, width: newFrame.width, height: scrollH)
        titleLabel.frame = NSRect(x: 0, y: scrollH,
                                  width: newFrame.width,
                                  height: Self.titleBarHeight)

        let docW = newFrame.width
        let docH = docW * aspect
        imageView.frame = NSRect(x: 0, y: 0, width: docW, height: docH)

        // Auto-scroll to the bottom so the latest content stays visible.
        if let docView = scrollView.documentView {
            let bottomPoint = NSPoint(
                x: 0,
                y: max(0, docView.frame.height - scrollView.contentSize.height)
            )
            scrollView.contentView.scroll(to: bottomPoint)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// Try right-of-anchor first; if it would leave the visible frame
    /// of any screen, place it to the left instead. As a last resort,
    /// dock it inside the right edge of the screen the anchor lives on.
    private static func previewFrame(for anchor: CGRect, imageAspect: CGFloat) -> CGRect {
        let pw = previewWidth
        let imgH = pw * max(0.1, imageAspect)
        let ph = min(maxHeight, max(minHeight, imgH + titleBarHeight))

        let screenFrame = NSScreen.screens
            .first(where: { $0.frame.intersects(anchor) })?
            .visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)

        var y = anchor.midY - ph / 2
        y = max(screenFrame.minY + 8, min(y, screenFrame.maxY - ph - 8))

        let rightX = anchor.maxX + spacing
        let leftX  = anchor.minX - spacing - pw
        let x: CGFloat
        if rightX + pw <= screenFrame.maxX - 8 {
            x = rightX
        } else if leftX >= screenFrame.minX + 8 {
            x = leftX
        } else {
            // No room either side — pin to the inside of the right edge.
            x = screenFrame.maxX - pw - 8
        }
        return CGRect(x: x, y: y, width: pw, height: ph)
    }

    override var canBecomeKey: Bool  { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Image stitcher

/// Outcome of `appendFrame`.
enum ScrollStitchOutcome {
    /// New content was appended below the current accumulation
    /// (downward scrolling).
    case appended
    /// New content was prepended above the current accumulation
    /// (upward scrolling – user scrolled back up to a new region).
    case prepended
    /// Frame is essentially identical to the current edge — no motion.
    case duplicate
    /// Match was ambiguous; frame intentionally dropped to avoid
    /// inserting duplicated/misaligned content.
    case skipped
}

/// Two-stage stitcher:
///
/// 1. **Coarse pass** — compares lightweight per-row luminance
///    "fingerprints" between the cached edge of the accumulated image
///    and the new frame, producing the *top few* candidate overlaps.
/// 2. **Fine pass** — for each top candidate, performs pixel-precise
///    mean-absolute-difference on the actual RGBA bytes of the overlap
///    region. Only accepts when fine MAD ≤ `pixelMADThreshold`.
///
/// **Properties:**
/// - Detects both downward and upward scrolling. The new frame is
///   compared against both the cached bottom (scroll-down) and cached
///   top (scroll-up) strips of the accumulation; whichever side
///   produces the higher fine-verified score wins.
/// - **Never** falls back to "append the whole frame" when no overlap
///   is found. That branch was the source of duplicated regions in
///   the previous implementation; missing a frame is always preferable.
/// - O(W · stripRows) per frame — independent of the accumulated long
///   image height. Cached edges are updated from the new frame after
///   every append/prepend, so the accumulated image is never
///   re-rasterised.
struct ScrollImageStitcher {

    private var accumulatedCG: CGImage?
    /// The immediately previous captured frame. We compare against this full
    /// frame first so a static page is recognized as "no motion" instead of
    /// being misread as a large append from a short edge overlap.
    private var previousFrame: RGBAFrameBuffer?
    private var previousFrameSigs: [RowSignature] = []

    /// Mean-absolute-difference threshold (per channel, 0–255) for
    /// accepting a fine-verified overlap. Empirically ~6 captures
    /// anti-aliased text scrolling cleanly while rejecting unrelated
    /// content (which typically shows MAD > 30).
    private let pixelMADThreshold: Double = 6.0
    /// Static-frame precheck: when the whole frame is this similar we treat it
    /// as "no motion" and skip stitching entirely.
    private let duplicateScoreThreshold: Double = 0.985
    private let duplicateMADThreshold: Double = 4.0

    /// Coarse-pass score below which we don't even bother running the
    /// fine pass (saves work on completely unrelated frames).
    private let coarseGate: Double = 0.55
    /// Ignore tiny dy jitter from inertial scrolling / font antialiasing.
    private let minMotionRows = 3
    /// Search only plausible per-frame motion deltas. This keeps runtime
    /// bounded and matches the faster capture cadence in the new coordinator.
    private let maxShiftRows = 420

    /// Number of evenly-spaced sample columns per row used for the
    /// coarse signature.
    private let samplesPerRow = 64

    /// Practical CGContext height ceiling.
    private let maxStitchedHeight = 16_000

    let backingScale: CGFloat

    var result: NSImage? {
        guard let accumulatedCG else { return nil }
        return makeNSImage(accumulatedCG)
    }

    var resultCGImage: CGImage? { accumulatedCG }
    var canvasPixelHeight: Int { accumulatedCG?.height ?? 0 }

    init(backingScale: CGFloat = 2.0) {
        self.backingScale = max(1, backingScale)
    }

    @discardableResult
    mutating func appendFrame(_ frame: CGImage) -> ScrollStitchOutcome {
        let frameW = frame.width
        let frameH = frame.height
        guard frameW > 1, frameH > 1 else { return .skipped }

        // Render the new frame into RGBA exactly once.
        guard let newBuffer = RGBAFrameBuffer.render(frame) else { return .skipped }
        let newFullSigs = signatures(in: newBuffer, rowRange: 0..<frameH)

        // First frame – seed the accumulation.
        guard let accumulated = accumulatedCG else {
            accumulatedCG = frame
            previousFrame = newBuffer
            previousFrameSigs = newFullSigs
            return .appended
        }
        guard frameW == accumulated.width else { return .skipped }
        if accumulated.height >= maxStitchedHeight { return .skipped }

        guard let previousFrameBuffer = previousFrame else {
            previousFrame = newBuffer
            previousFrameSigs = newFullSigs
            return .skipped
        }

        switch detectMotion(
            previousFrame: previousFrameBuffer,
            previousFrameSigs: previousFrameSigs,
            newBuffer: newBuffer,
            newFullSigs: newFullSigs
        ) {
        case .duplicate:
            previousFrame = newBuffer
            previousFrameSigs = newFullSigs
            return .duplicate
        case .none:
            previousFrame = newBuffer
            previousFrameSigs = newFullSigs
            return .skipped
        case let .moved(direction, shift):
            switch direction {
        case .down:
            // Current frame content moved upward by `shift`, so the newly
            // revealed rows live at the bottom.
            let newRows = shift
            let outcome = appendBelow(
                frame: frame,
                newRows: newRows,
                accumulated: accumulated
            )
            previousFrame = newBuffer
            previousFrameSigs = newFullSigs
            return outcome
        case .up:
            // Current frame content moved downward by `shift`, so the newly
            // revealed rows live at the top.
            let newRows = shift
            let outcome = prependAbove(
                frame: frame,
                newRows: newRows,
                accumulated: accumulated
            )
            previousFrame = newBuffer
            previousFrameSigs = newFullSigs
            return outcome
        }
        }
    }

    // MARK: Append / Prepend

    private mutating func appendBelow(
        frame: CGImage,
        newRows: Int,
        accumulated: CGImage
    ) -> ScrollStitchOutcome {
        guard newRows > 0 else { return .skipped }
        let frameW = frame.width
        let frameH = frame.height
        let totalH = accumulated.height + newRows
        if totalH > maxStitchedHeight { return .skipped }

        let sliceRect = CGRect(x: 0, y: frameH - newRows,
                               width: frameW, height: newRows)
        guard let slice = frame.cropping(to: sliceRect) else { return .skipped }

        guard let combined = composite(
            width: frameW, totalHeight: totalH,
            top: accumulated, topY: newRows,
            bottom: slice,    bottomY: 0
        ) else { return .skipped }

        accumulatedCG = combined
        return .appended
    }

    private mutating func prependAbove(
        frame: CGImage,
        newRows: Int,
        accumulated: CGImage
    ) -> ScrollStitchOutcome {
        guard newRows > 0 else { return .skipped }
        let frameW = frame.width
        let totalH = accumulated.height + newRows
        if totalH > maxStitchedHeight { return .skipped }

        // The new top rows (above the overlap) are at the TOP of the new
        // frame, i.e. y in [0, newRows).
        let sliceRect = CGRect(x: 0, y: 0, width: frameW, height: newRows)
        guard let slice = frame.cropping(to: sliceRect) else { return .skipped }

        // Composite: new slice at the top, existing accumulation below.
        guard let combined = composite(
            width: frameW, totalHeight: totalH,
            top: slice,        topY: accumulated.height,
            bottom: accumulated, bottomY: 0
        ) else { return .skipped }

        accumulatedCG = combined
        return .prepended
    }

    private func composite(
        width: Int, totalHeight: Int,
        top: CGImage, topY: Int,
        bottom: CGImage, bottomY: Int
    ) -> CGImage? {
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
        ) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(top,    in: CGRect(x: 0, y: topY,
                                    width: width, height: top.height))
        ctx.draw(bottom, in: CGRect(x: 0, y: bottomY,
                                    width: width, height: bottom.height))
        return ctx.makeImage()
    }

    // MARK: Match search

    private enum MotionResult {
        case duplicate
        case moved(ScrollStitchOutcome.Direction, shift: Int)
        case none
    }

    private struct MotionCandidate {
        let direction: ScrollStitchOutcome.Direction
        let shift: Int
        let score: Double
    }

    private func detectMotion(
        previousFrame: RGBAFrameBuffer,
        previousFrameSigs: [RowSignature],
        newBuffer: RGBAFrameBuffer,
        newFullSigs: [RowSignature]
    ) -> MotionResult {
        let fullCount = min(previousFrame.height, newBuffer.height,
                            previousFrameSigs.count, newFullSigs.count)
        guard fullCount > 0 else { return .none }

        let staticRowStride = max(1, fullCount / 180)
        let fullFrameScore = compareRows(
            a: previousFrameSigs, aStart: 0,
            b: newFullSigs, bStart: 0,
            count: fullCount,
            rowStride: staticRowStride
        )
        let fullFrameMAD = pixelMAD(
            refStrip: previousFrame,
            refStartRow: 0,
            newBuffer: newBuffer,
            newStartRow: 0,
            overlap: fullCount,
            rowStep: staticRowStride
        )
        if fullFrameScore >= duplicateScoreThreshold, fullFrameMAD <= duplicateMADThreshold {
            return .duplicate
        }

        let minOverlap = max(80, fullCount / 5)
        let maxShift = min(maxShiftRows, fullCount - minOverlap)
        guard maxShift >= minMotionRows else { return .none }

        var bestDown: MotionCandidate?
        var bestUp: MotionCandidate?
        for shift in minMotionRows...maxShift {
            let overlap = fullCount - shift
            let rowStride = max(1, overlap / 120)

            let downScore = compareRows(
                a: previousFrameSigs, aStart: shift,
                b: newFullSigs, bStart: 0,
                count: overlap,
                rowStride: rowStride
            )
            if downScore >= coarseGate, downScore > (bestDown?.score ?? 0) {
                bestDown = MotionCandidate(direction: .down, shift: shift, score: downScore)
            }

            let upScore = compareRows(
                a: previousFrameSigs, aStart: 0,
                b: newFullSigs, bStart: shift,
                count: overlap,
                rowStride: rowStride
            )
            if upScore >= coarseGate, upScore > (bestUp?.score ?? 0) {
                bestUp = MotionCandidate(direction: .up, shift: shift, score: upScore)
            }
        }

        let verified = [bestDown, bestUp]
            .compactMap { $0 }
            .compactMap { candidate -> (MotionCandidate, Double)? in
                let overlap = fullCount - candidate.shift
                let rowStep = max(1, overlap / 160)
                let mad: Double
                switch candidate.direction {
                case .down:
                    mad = pixelMAD(
                        refStrip: previousFrame,
                        refStartRow: candidate.shift,
                        newBuffer: newBuffer,
                        newStartRow: 0,
                        overlap: overlap,
                        rowStep: rowStep
                    )
                case .up:
                    mad = pixelMAD(
                        refStrip: previousFrame,
                        refStartRow: 0,
                        newBuffer: newBuffer,
                        newStartRow: candidate.shift,
                        overlap: overlap,
                        rowStep: rowStep
                    )
                }
                return mad <= pixelMADThreshold ? (candidate, mad) : nil
            }

        guard let best = verified.min(by: { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.0.score > rhs.0.score
        }) else {
            return .none
        }
        return .moved(best.0.direction, shift: best.0.shift)
    }

    /// Compute mean absolute pixel difference (RGB averaged) over the
    /// `overlap` rows starting at the provided row offsets.
    private func pixelMAD(
        refStrip: RGBAFrameBuffer,
        refStartRow: Int,
        newBuffer: RGBAFrameBuffer,
        newStartRow: Int,
        overlap: Int,
        rowStep: Int = 1
    ) -> Double {
        let w = refStrip.width
        guard newBuffer.width == w, overlap > 0 else { return .infinity }

        // Subsample columns for speed (every ~4 px). For 1200-px-wide
        // frames this is ~300 columns × overlap rows of work, which on
        // a Retina capture takes well under a millisecond.
        let colStep = max(1, w / 256)

        var total: UInt64 = 0
        var samples: UInt64 = 0
        for r in stride(from: 0, to: overlap, by: max(1, rowStep)) {
            let refBase = (refStartRow + r) * refStrip.bytesPerRow
            let newBase = (newStartRow + r) * newBuffer.bytesPerRow
            var x = 0
            while x < w {
                let ri = refBase + x * 4
                let ni = newBase + x * 4
                let dr = abs(Int(refStrip.data[ri])     - Int(newBuffer.data[ni]))
                let dg = abs(Int(refStrip.data[ri + 1]) - Int(newBuffer.data[ni + 1]))
                let db = abs(Int(refStrip.data[ri + 2]) - Int(newBuffer.data[ni + 2]))
                total &+= UInt64(dr + dg + db)
                samples &+= 3
                x += colStep
            }
        }
        guard samples > 0 else { return .infinity }
        return Double(total) / Double(samples)
    }

    // MARK: Row signatures

    private typealias RowSignature = [UInt8]

    private func signatures(in buf: RGBAFrameBuffer, rowRange: Range<Int>) -> [RowSignature] {
        let w = buf.width
        let bpr = buf.bytesPerRow
        let step = max(1, w / samplesPerRow)
        var sigs: [RowSignature] = []
        sigs.reserveCapacity(rowRange.count)
        for row in rowRange {
            var sig = RowSignature()
            sig.reserveCapacity(samplesPerRow)
            let base = row * bpr
            var x = 0
            while x < w, sig.count < samplesPerRow {
                let idx = base + x * 4
                let r = Int(buf.data[idx])
                let g = Int(buf.data[idx + 1])
                let b = Int(buf.data[idx + 2])
                sig.append(UInt8(clamping: (r * 77 + g * 150 + b * 29) >> 8))
                x += step
            }
            sigs.append(sig)
        }
        return sigs
    }

    private func compareRows(
        a: [RowSignature], aStart: Int,
        b: [RowSignature], bStart: Int,
        count: Int,
        rowStride: Int = 1
    ) -> Double {
        guard count > 0 else { return 0 }
        var total = 0.0
        var samples = 0
        for i in stride(from: 0, to: count, by: max(1, rowStride)) {
            total += rowSimilarity(a[aStart + i], b[bStart + i])
            samples += 1
        }
        guard samples > 0 else { return 0 }
        return total / Double(samples)
    }

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

    private func makeNSImage(_ cg: CGImage) -> NSImage {
        let pointSize = NSSize(
            width:  CGFloat(cg.width)  / backingScale,
            height: CGFloat(cg.height) / backingScale
        )
        return NSImage(cgImage: cg, size: pointSize)
    }
}

extension ScrollStitchOutcome {
    fileprivate enum Direction { case down, up }
}

/// RAII wrapper around a manually-allocated RGBA pixel buffer so the
/// memory is freed automatically when the buffer goes out of scope.
private final class RGBAFrameBuffer {
    let data: UnsafeMutablePointer<UInt8>
    let width: Int
    let height: Int
    let bytesPerRow: Int

    init(data: UnsafeMutablePointer<UInt8>,
         width: Int, height: Int, bytesPerRow: Int) {
        self.data = data
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
    }

    deinit { data.deallocate() }

    /// Render a CGImage into a freshly-allocated RGBA buffer.
    static func render(_ image: CGImage) -> RGBAFrameBuffer? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }
        let bpr = w * 4
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: h * bpr)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: buffer,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: bpr,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            buffer.deallocate()
            return nil
        }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return RGBAFrameBuffer(
            data: buffer, width: w, height: h, bytesPerRow: bpr
        )
    }

    /// Copy a contiguous range of rows into a new standalone buffer.
    func copy(rowRange: Range<Int>) -> RGBAFrameBuffer {
        let lo = max(0, rowRange.lowerBound)
        let hi = min(height, rowRange.upperBound)
        let h = max(0, hi - lo)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: h * bytesPerRow)
        if h > 0 {
            buffer.update(from: data.advanced(by: lo * bytesPerRow),
                          count: h * bytesPerRow)
        }
        return RGBAFrameBuffer(
            data: buffer, width: width, height: h, bytesPerRow: bytesPerRow
        )
    }
}

// MARK: - Localization

fileprivate enum ScrollCaptureL10nKey {
    case done
    case cancel
    case toolScrollCapture
    case previewTitle
}

enum ScrollCaptureL10n {
    fileprivate static func tr(_ key: ScrollCaptureL10nKey) -> String {
        switch key {
        case .done:
            return L10n.tr("common.done")
        case .cancel:
            return L10n.tr("toolbar.action.cancel")
        case .toolScrollCapture:
            return L10n.tr("editor.tool.scroll_capture")
        case .previewTitle:
            return L10n.tr("common.live_preview")
        }
    }
}

// MARK: - Helpers

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
