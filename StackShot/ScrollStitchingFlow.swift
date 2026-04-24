//
//  ScrollStitchingFlow.swift
//  StackShot
//
//  End-to-end SwiftUI/AppKit interaction layer that wires together:
//
//      RegionSelection ──▶ ScrollStitchingCoordinator
//                              │
//                              ├─▶ CGWindowListCreateImage (region capture)
//                              ├─▶ ScrollImageStitcher      (frame stitching)
//                              ├─▶ ScrollStitchingOverlayPanel
//                              ├─▶ ScrollStitchingHUDPanel  ("正在监控滚动…")
//                              └─▶ ScrollStitchingResultWindow (preview / save / copy)
//
//  Trigger from your toolbar:
//
//      ScrollStitchingCoordinator.shared.start(
//          selectedCropRect: rectInAppKitScreenCoords,
//          completion: { /* coordinator already showed the result window */ }
//      )
//
//  Stop conditions (all wired below):
//      • User clicks "完成" on the floating HUD panel
//      • User clicks "取消" or "完成" on the floating HUD panel
//      • Coordinator times out after a hard cap (safety, default 5 minutes)
//
//  This file is intentionally self-contained — it does not modify the
//  existing `ScrollCaptureSession` flow, so you can A/B both pipelines.
//

import AppKit
import SwiftUI
import Combine
import CoreGraphics
import UniformTypeIdentifiers
import OSLog

// MARK: - Localization helper

private enum ScrollFlowL10n {
    static var hudWatching: String {
        L10n.tr("scroll.flow.hud.watching")
    }

    static var hudHint: String {
        L10n.tr("scroll.flow.hud.hint")
    }

    static var hudDone: String {
        L10n.tr("common.done")
    }

    static var hudCancel: String {
        L10n.tr("toolbar.action.cancel")
    }

    static func hudFramesFormat(_ accepted: Int, _ total: Int, _ pixels: Int) -> String {
        let format = L10n.tr("scroll.flow.hud.frames_format")
        return String(format: format, accepted, total, pixels)
    }

    static var previewTitle: String {
        L10n.tr("common.live_preview")
    }

    static var resultTitle: String {
        L10n.tr("scroll.flow.result.title")
    }

    static var resultSave: String {
        L10n.tr("scroll.flow.result.save")
    }

    static var resultCopy: String {
        L10n.tr("scroll.flow.result.copy")
    }

    static var resultCopied: String {
        L10n.tr("scroll.flow.result.copied")
    }

    static var resultClose: String {
        L10n.tr("common.close")
    }

    static var resultEmptyTitle: String {
        L10n.tr("scroll.flow.result.empty.title")
    }

    static var resultEmptyHint: String {
        L10n.tr("scroll.flow.result.empty.hint")
    }

    static var saveDefaultName: String {
        L10n.tr("scroll.flow.save.default_name")
    }
}

// MARK: - Coordinator

@MainActor
final class ScrollStitchingCoordinator: ConsoleTraceLogging {

    static let shared = ScrollStitchingCoordinator()

    private static let hudSpacing: CGFloat = 12
    private static let hudScreenMargin: CGFloat = 8

    private let log = Logger(subsystem: "com.stackshot.capture", category: "ScrollStitchingFlow")
    private let processingQueue = DispatchQueue(label: "com.stackshot.scroll.capture", qos: .userInitiated)
    private var worker: ScrollStitchingWorker?
    private var isProcessingFrame = false
    private var latestStitchedCGImage: CGImage?
    private var lastPreviewRefreshTimestamp: CFTimeInterval = 0
    private let previewRefreshInterval: CFTimeInterval = 0.10
    private var sessionGeneration: Int = 0

    // Live UI surfaces.
    private var hudPanel: ScrollStitchingHUDPanel?
    private var hudViewModel: ScrollStitchingHUDViewModel?
    private var overlayPanel: ScrollStitchingOverlayPanel?
    private var previewPanel: ScrollStitchingPreviewPanel?

    // Region & geometry recorded at start time.
    private var selectedCropRect: CGRect = .zero
    private var screenForCrop: NSScreen?
    private var quartzCaptureRect: CGRect = .zero
    private var backingScale: CGFloat = 2.0
    private var captureFrameLogCount = 0

    private var captureLoopTask: Task<Void, Never>?

    // Hard timeout safety net.
    private var timeoutTask: Task<Void, Never>?
    private var maxCaptureDuration: TimeInterval = 5 * 60
    private var shouldPresentResultWindow = true
    // Slightly faster cadence reduces vertical jumps during quicker scrolls
    // without overwhelming the stitching worker with overlapping frames.
    private let captureInterval: TimeInterval = 0.07

    // Re-entry guard.
    private var isActive = false
    private var completion: ((NSImage?) -> Void)?

    private init() {}

    // MARK: Public entry point

    /// Begin a scroll-stitching session over `selectedCropRect` (in AppKit
    /// screen coordinates — origin bottom-left, the same coord system the
    /// region-selection overlay returns).
    ///
    /// The coordinator handles all UI: HUD, explicit stop controls, and optionally the
    /// result window. `completion` always fires on the main actor with the
    /// stitched image (or `nil` on cancel / empty / failure).
    func start(selectedCropRect rect: CGRect,
               presentResultWindow: Bool = true,
               completion: ((NSImage?) -> Void)? = nil) {

        let normalizedRect = rect.standardized.integral
        debugLog("收到滚动截图请求，区域=\(normalizedRect)，presentResultWindow=\(presentResultWindow)。")

        guard !isActive else {
            debugLog("滚动截图请求被忽略：已有活动会话。")
            log.warning("Ignoring start() — session already active.")
            return
        }
        guard normalizedRect.width >= 8, normalizedRect.height >= 8 else {
            debugLog("滚动截图请求被拒绝：区域过小，原始区域=\(rect)。")
            log.error("Rejecting tiny selectedCropRect: \(String(describing: rect))")
            completion?(nil)
            return
        }

        // Resolve the screen that contains the selection's center.
        let center = CGPoint(x: normalizedRect.midX, y: normalizedRect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
                    ?? NSScreen.main else {
            log.error("No NSScreen contains the selectedCropRect.")
            completion?(nil); return
        }
        self.selectedCropRect = normalizedRect
        self.screenForCrop = screen
        self.backingScale = screen.backingScaleFactor
        self.quartzCaptureRect = Self.quartzRect(from: normalizedRect, scale: backingScale)
        self.shouldPresentResultWindow = presentResultWindow
        self.completion = completion
        self.captureFrameLogCount = 0
        self.latestStitchedCGImage = nil
        self.lastPreviewRefreshTimestamp = 0
        self.isProcessingFrame = false
        self.sessionGeneration &+= 1

        isActive = true
        worker = ScrollStitchingWorker(backingScale: backingScale)
        debugLog("滚动截图会话已启动，selectedCropRect=\(selectedCropRect)，quartzCaptureRect=\(quartzCaptureRect)，backingScale=\(backingScale)。")

        presentOverlay()
        presentPreview()
        presentHUD()
        scheduleTimeout()
        startCaptureLoop()
    }

    // MARK: HUD

    private func presentOverlay() {
        overlayPanel?.orderOut(nil)
        let panel = ScrollStitchingOverlayPanel(captureRect: selectedCropRect)
        panel.orderFrontRegardless()
        self.overlayPanel = panel
        debugLog("已展示滚动截图选区遮罩。")
    }

    private func presentHUD() {
        let viewModel = ScrollStitchingHUDViewModel()
        viewModel.onDone   = { [weak self] in self?.finish(cancelled: false) }
        viewModel.onCancel = { [weak self] in self?.finish(cancelled: true) }
        self.hudViewModel = viewModel

        let panel = ScrollStitchingHUDPanel(viewModel: viewModel)
        panel.setFrameOrigin(hudOrigin(for: panel.frame.size))
        panel.orderFrontRegardless()
        self.hudPanel = panel
        debugLog("已展示滚动截图 HUD。")
    }

    private func presentPreview() {
        previewPanel?.orderOut(nil)
        let panel = ScrollStitchingPreviewPanel(anchorRect: selectedCropRect)
        panel.orderFrontRegardless()
        self.previewPanel = panel
        debugLog("已展示滚动截图预览面板。")
    }

    private func hudOrigin(for panelSize: CGSize) -> NSPoint {
        let visibleFrame = screenForCrop?.visibleFrame
            ?? screenForCrop?.frame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let avoidRect = previewPanel?.frame.insetBy(dx: -Self.hudSpacing, dy: -Self.hudSpacing)

        let bottomY = selectedCropRect.minY - panelSize.height - Self.hudSpacing
        if bottomY >= visibleFrame.minY + Self.hudScreenMargin {
            let bottomCandidates = [
                CGRect(
                    x: selectedCropRect.midX - panelSize.width / 2,
                    y: bottomY,
                    width: panelSize.width,
                    height: panelSize.height
                ),
                CGRect(
                    x: selectedCropRect.minX,
                    y: bottomY,
                    width: panelSize.width,
                    height: panelSize.height
                ),
                CGRect(
                    x: selectedCropRect.maxX - panelSize.width,
                    y: bottomY,
                    width: panelSize.width,
                    height: panelSize.height
                )
            ]

            if let resolved = bottomCandidates
                .map({ clamp($0, to: visibleFrame) })
                .first(where: { candidate in
                    guard let avoidRect else { return true }
                    return !candidate.intersects(avoidRect)
                }) {
                return resolved.origin
            }
        }

        let leftX = selectedCropRect.minX - panelSize.width - Self.hudSpacing
        if leftX >= visibleFrame.minX + Self.hudScreenMargin {
            let centeredY = selectedCropRect.midY - panelSize.height / 2
            let leftCandidate = clamp(
                CGRect(
                    x: leftX,
                    y: centeredY,
                    width: panelSize.width,
                    height: panelSize.height
                ),
                to: visibleFrame
            )
            if avoidRect == nil || !leftCandidate.intersects(avoidRect!) {
                return leftCandidate.origin
            }
        }

        let fallbackCandidates = [
            clamp(
                CGRect(
                    x: selectedCropRect.maxX + Self.hudSpacing,
                    y: selectedCropRect.midY - panelSize.height / 2,
                    width: panelSize.width,
                    height: panelSize.height
                ),
                to: visibleFrame
            ),
            clamp(
                CGRect(
                    x: selectedCropRect.midX - panelSize.width / 2,
                    y: selectedCropRect.maxY + Self.hudSpacing,
                    width: panelSize.width,
                    height: panelSize.height
                ),
                to: visibleFrame
            ),
            clamp(
                CGRect(
                    x: visibleFrame.maxX - panelSize.width - Self.hudScreenMargin,
                    y: visibleFrame.maxY - panelSize.height - Self.hudScreenMargin,
                    width: panelSize.width,
                    height: panelSize.height
                ),
                to: visibleFrame
            )
        ]

        if let resolved = fallbackCandidates.first(where: { candidate in
            guard let avoidRect else { return true }
            return !candidate.intersects(avoidRect)
        }) {
            return resolved.origin
        }

        return clamp(
            CGRect(origin: selectedCropRect.origin, size: panelSize),
            to: visibleFrame
        ).origin
    }

    private func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        CGRect(
            x: min(max(rect.origin.x, bounds.minX + Self.hudScreenMargin),
                   bounds.maxX - rect.width - Self.hudScreenMargin),
            y: min(max(rect.origin.y, bounds.minY + Self.hudScreenMargin),
                   bounds.maxY - rect.height - Self.hudScreenMargin),
            width: rect.width,
            height: rect.height
        )
    }

    private func scheduleTimeout() {
        timeoutTask?.cancel()
        let cap = maxCaptureDuration
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(cap * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.finish(cancelled: false)
            }
        }
    }

    // MARK: Frame capture

    private func startCaptureLoop() {
        captureLoopTask?.cancel()
        let intervalNs = UInt64(captureInterval * 1_000_000_000)
        debugLog("开始滚动截图采样循环，captureInterval=\(String(format: "%.3f", captureInterval)) 秒。")
        captureLoopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            while !Task.isCancelled {
                await MainActor.run {
                    self?.captureFrame()
                }
                try? await Task.sleep(nanoseconds: intervalNs)
            }
        }
    }

    private func captureFrame() {
        guard isActive, !isProcessingFrame, let worker else { return }
        let frameIndex = captureFrameLogCount
        captureFrameLogCount += 1
        isProcessingFrame = true

        let listOption: CGWindowListOption
        let relativeToWindow: CGWindowID
        if let overlayNumber = overlayPanel?.windowNumber, overlayNumber > 0 {
            listOption = [.optionOnScreenBelowWindow, .excludeDesktopElements]
            relativeToWindow = CGWindowID(overlayNumber)
        } else {
            listOption = .optionOnScreenOnly
            relativeToWindow = kCGNullWindowID
        }

        if frameIndex < 3 {
            debugLog("处理滚动截图帧 #\(frameIndex + 1)，selectedCropRect=\(selectedCropRect)，quartzCaptureRect=\(quartzCaptureRect)。")
        }

        let captureRect = quartzCaptureRect
        let generation = sessionGeneration
        processingQueue.async { [weak self] in
            guard let cgImage = CGWindowListCreateImage(
                captureRect,
                listOption,
                relativeToWindow,
                .bestResolution
            ) else {
                DispatchQueue.main.async {
                    guard let self, self.sessionGeneration == generation else { return }
                    self.isProcessingFrame = false
                }
                return
            }

            let update = worker.processFrame(cgImage)
            DispatchQueue.main.async { [weak self] in
                self?.applyFrameUpdate(
                    update,
                    frameIndex: frameIndex,
                    generation: generation
                )
            }
        }
    }

    private func applyFrameUpdate(
        _ update: ScrollStitchingFrameUpdate,
        frameIndex: Int,
        generation: Int
    ) {
        guard sessionGeneration == generation else { return }
        isProcessingFrame = false
        guard isActive else { return }

        if frameIndex < 8 {
            debugLog("帧更新已应用，frameIndex=\(frameIndex)，outcome=\(String(describing: update.outcome))，totalHeightPx=\(update.canvasHeightPx)。")
        }

        hudViewModel?.totalFrames &+= 1
        if update.outcome == .appended || update.outcome == .prepended {
            hudViewModel?.acceptedFrames &+= 1
        }
        hudViewModel?.canvasHeightPx = update.canvasHeightPx

        guard let stitchedCGImage = update.stitchedCGImage else { return }
        latestStitchedCGImage = stitchedCGImage

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPreviewRefreshTimestamp >= previewRefreshInterval else { return }
        lastPreviewRefreshTimestamp = now
        previewPanel?.updateImage(stitchedCGImage)
    }

    // MARK: Finalization

    private func finish(cancelled: Bool) {
        guard isActive else { return }
        debugLog("准备结束滚动截图会话，cancelled=\(cancelled)。")
        isActive = false
        let shouldPresentResultWindow = self.shouldPresentResultWindow
        self.shouldPresentResultWindow = true

        timeoutTask?.cancel(); timeoutTask = nil
        captureLoopTask?.cancel(); captureLoopTask = nil
        isProcessingFrame = false
        overlayPanel?.orderOut(nil); overlayPanel = nil
        previewPanel?.orderOut(nil); previewPanel = nil

        let nsImage = cancelled ? nil : latestStitchedCGImage.map {
            NSImage(
                cgImage: $0,
                size: NSSize(width: CGFloat($0.width) / backingScale,
                             height: CGFloat($0.height) / backingScale)
            )
        }

        // Tear down HUD before showing result so focus shifts cleanly.
        hudPanel?.orderOut(nil); hudPanel = nil; hudViewModel = nil

        if !cancelled, shouldPresentResultWindow {
            if let img = nsImage {
                debugLog("滚动截图结果可用，准备展示结果窗口，尺寸=\(Int(img.size.width))x\(Int(img.size.height))。")
                ScrollStitchingResultWindow.present(image: img)
            } else {
                debugLog("滚动截图结束，但没有生成可展示图像，准备展示空结果页。")
                ScrollStitchingResultWindow.presentEmpty()
            }
        }

        completion?(nsImage)
        completion = nil
        worker = nil
        debugLog("滚动截图会话已结束。")
    }

    private func failAndCleanup() {
        debugLog("滚动截图流程失败，开始清理现场。")
        isActive = false
        shouldPresentResultWindow = true
        captureLoopTask?.cancel(); captureLoopTask = nil
        isProcessingFrame = false
        timeoutTask?.cancel(); timeoutTask = nil
        overlayPanel?.orderOut(nil); overlayPanel = nil
        previewPanel?.orderOut(nil); previewPanel = nil
        hudPanel?.orderOut(nil); hudPanel = nil; hudViewModel = nil
        completion?(nil); completion = nil
        worker = nil
    }

    // MARK: Coordinate math

    private static func quartzRect(from appKitRect: CGRect, scale: CGFloat) -> CGRect {
        let desktopBounds = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        guard !desktopBounds.isNull else { return appKitRect }

        let x = floor(appKitRect.origin.x * scale) / scale
        let w = ceil(appKitRect.width * scale) / scale
        let h = ceil(appKitRect.height * scale) / scale
        let y = floor((desktopBounds.maxY - appKitRect.maxY) * scale) / scale

        return CGRect(x: x, y: y, width: w, height: h)
    }
}

private final class ScrollStitchingOverlayPanel: NSPanel {

    init(captureRect: CGRect) {
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
        ignoresMouseEvents = true

        let view = ScrollStitchingOverlayView(
            frame: NSRect(origin: .zero, size: unionFrame.size),
            captureRect: captureRect.offsetBy(dx: -unionFrame.origin.x, dy: -unionFrame.origin.y)
        )
        contentView = view
    }
}

private final class ScrollStitchingOverlayView: NSView {
    private let captureRect: CGRect

    init(frame: NSRect, captureRect: CGRect) {
        self.captureRect = captureRect
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.30).setFill()
        NSBezierPath(rect: bounds).fill()

        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(rect: captureRect).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        let borderPath = NSBezierPath(rect: captureRect.insetBy(dx: -1.5, dy: -1.5))
        borderPath.lineWidth = 2
        NSColor.systemBlue.withAlphaComponent(0.85).setStroke()
        borderPath.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct ScrollStitchingFrameUpdate {
    let outcome: ScrollStitchOutcome
    let canvasHeightPx: Int
    let stitchedCGImage: CGImage?
}

private final class ScrollStitchingWorker: @unchecked Sendable {
    private var stitcher: ScrollImageStitcher

    init(backingScale: CGFloat) {
        self.stitcher = ScrollImageStitcher(backingScale: backingScale)
    }

    func processFrame(_ cgImage: CGImage) -> ScrollStitchingFrameUpdate {
        let outcome = stitcher.appendFrame(cgImage)
        return ScrollStitchingFrameUpdate(
            outcome: outcome,
            canvasHeightPx: stitcher.canvasPixelHeight,
            stitchedCGImage: stitcher.resultCGImage
        )
    }
}

private final class ScrollStitchingPreviewPanel: NSPanel {

    private final class AspectFitCGImageView: NSView {
        var cgImage: CGImage? {
            didSet { needsDisplay = true }
        }

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)

            NSColor.clear.setFill()
            dirtyRect.fill()

            guard let cgImage,
                  let context = NSGraphicsContext.current?.cgContext else { return }

            let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
            let targetRect = Self.aspectFitRect(for: imageSize, in: bounds)

            context.saveGState()
            let clipPath = NSBezierPath(roundedRect: targetRect, xRadius: 8, yRadius: 8)
            clipPath.addClip()
            context.interpolationQuality = .high
            context.translateBy(x: 0, y: targetRect.minY + targetRect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: targetRect)
            context.restoreGState()
        }

        private static func aspectFitRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
            guard imageSize.width > 0, imageSize.height > 0,
                  bounds.width > 0, bounds.height > 0 else {
                return bounds
            }

            let scale = min(bounds.width / imageSize.width,
                            bounds.height / imageSize.height)
            let fittedSize = CGSize(width: floor(imageSize.width * scale),
                                    height: floor(imageSize.height * scale))
            return CGRect(
                x: bounds.midX - fittedSize.width / 2,
                y: bounds.midY - fittedSize.height / 2,
                width: fittedSize.width,
                height: fittedSize.height
            ).integral
        }
    }

    private let imageView: AspectFitCGImageView
    private let titleLabel: NSTextField
    private let containerView: NSView
    private let anchorRect: CGRect

    private static let maxPreviewWidth: CGFloat = 520
    private static let titleBarHeight: CGFloat = 22
    private static let maxPreviewHeight: CGFloat = 900
    private static let minPreviewWidth: CGFloat = 320
    private static let minPreviewHeight: CGFloat = 320
    private static let spacing: CGFloat = 18
    private static let contentPadding: CGFloat = 10

    init(anchorRect: CGRect) {
        self.anchorRect = anchorRect

        let initial = Self.previewFrame(for: anchorRect, imageSize: nil)
        let contentSize = initial.size
        let previewRect = Self.imageFrame(forPanelSize: contentSize, imageSize: nil)

        imageView = AspectFitCGImageView(frame: previewRect)
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true

        titleLabel = NSTextField(labelWithString: ScrollFlowL10n.previewTitle)
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
        containerView.addSubview(imageView)
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
        applyLayout(panelSize: contentSize, imageSize: nil)
    }

    func updateImage(_ cgImage: CGImage) {
        imageView.cgImage = cgImage

        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let newFrame = Self.previewFrame(for: anchorRect, imageSize: imageSize)
        setFrame(newFrame, display: true, animate: false)
        applyLayout(panelSize: newFrame.size, imageSize: imageSize)
    }

    private static func previewFrame(for anchor: CGRect, imageSize: CGSize?) -> CGRect {
        let screenFrame = NSScreen.screens
            .first(where: { $0.frame.intersects(anchor) })?
            .visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let maxPanelWidth = min(maxPreviewWidth, max(minPreviewWidth, screenFrame.width * 0.34))
        let maxPanelHeight = min(maxPreviewHeight, max(minPreviewHeight, screenFrame.height * 0.88))
        let panelSize = fittedPanelSize(maxWidth: maxPanelWidth,
                                        maxHeight: maxPanelHeight,
                                        imageSize: imageSize)

        var y = anchor.midY - panelSize.height / 2
        y = max(screenFrame.minY + 8, min(y, screenFrame.maxY - panelSize.height - 8))

        let rightX = anchor.maxX + spacing
        let leftX = anchor.minX - spacing - panelSize.width
        let x: CGFloat
        if rightX + panelSize.width <= screenFrame.maxX - 8 {
            x = rightX
        } else if leftX >= screenFrame.minX + 8 {
            x = leftX
        } else {
            x = screenFrame.maxX - panelSize.width - 8
        }
        return CGRect(x: x, y: y, width: panelSize.width, height: panelSize.height)
    }

    private static func fittedPanelSize(maxWidth: CGFloat,
                                        maxHeight: CGFloat,
                                        imageSize: CGSize?) -> CGSize {
        guard let imageSize, imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: maxWidth, height: maxHeight)
        }

        let availableWidth = maxWidth - contentPadding * 2
        let availableHeight = maxHeight - titleBarHeight - contentPadding * 2
        let scale = min(availableWidth / imageSize.width,
                        availableHeight / imageSize.height)
        let fittedWidth = floor(imageSize.width * scale)
        let fittedHeight = floor(imageSize.height * scale)
        return CGSize(width: fittedWidth + contentPadding * 2,
                      height: fittedHeight + titleBarHeight + contentPadding * 2)
    }

    private static func imageFrame(forPanelSize panelSize: CGSize, imageSize: CGSize?) -> CGRect {
        let bounds = CGRect(
            x: contentPadding,
            y: contentPadding,
            width: panelSize.width - contentPadding * 2,
            height: max(40, panelSize.height - titleBarHeight - contentPadding * 2)
        )
        guard let imageSize, imageSize.width > 0, imageSize.height > 0 else {
            return bounds
        }

        let scale = min(bounds.width / imageSize.width,
                        bounds.height / imageSize.height)
        let fittedSize = CGSize(width: floor(imageSize.width * scale),
                                height: floor(imageSize.height * scale))
        return CGRect(
            x: bounds.midX - fittedSize.width / 2,
            y: bounds.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        ).integral
    }

    private func applyLayout(panelSize: CGSize, imageSize: CGSize?) {
        containerView.frame = NSRect(origin: .zero, size: panelSize)
        imageView.frame = Self.imageFrame(forPanelSize: panelSize, imageSize: imageSize)
        titleLabel.frame = NSRect(
            x: 0,
            y: panelSize.height - Self.titleBarHeight,
            width: panelSize.width,
            height: Self.titleBarHeight
        )
    }
}

// MARK: - HUD: View model + panel

@MainActor
final class ScrollStitchingHUDViewModel: ObservableObject {
    @Published var acceptedFrames: Int = 0
    @Published var totalFrames: Int = 0
    @Published var canvasHeightPx: Int = 0
    var onDone:   () -> Void = {}
    var onCancel: () -> Void = {}
}

private struct ScrollStitchingHUDView: View {
    @ObservedObject var viewModel: ScrollStitchingHUDViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(ScrollFlowL10n.hudWatching)
                    .font(.system(size: 13, weight: .semibold))
            }

            Text(ScrollFlowL10n.hudHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(ScrollFlowL10n.hudFramesFormat(viewModel.acceptedFrames,
                                                viewModel.totalFrames,
                                                viewModel.canvasHeightPx))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)

            HStack(spacing: 8) {
                Button(ScrollFlowL10n.hudCancel) { viewModel.onCancel() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button(ScrollFlowL10n.hudDone) { viewModel.onDone() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(width: 280)
    }
}

/// Non-activating floating panel — does NOT steal focus, so the user can
/// keep scrolling Safari (or whatever app) while we monitor.
final class ScrollStitchingHUDPanel: NSPanel {

    init(viewModel: ScrollStitchingHUDViewModel) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 140),
            styleMask:   [.nonactivatingPanel, .titled, .fullSizeContentView, .hudWindow],
            backing:     .buffered,
            defer:       false
        )
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = true
        self.worksWhenModal = true
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.isMovableByWindowBackground = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true

        let host = NSHostingView(rootView: ScrollStitchingHUDView(viewModel: viewModel))
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        self.contentView = container
        self.setContentSize(host.fittingSize)
    }

    // Keep the HUD non-key so the underlying app stays scrollable.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Result window

@MainActor
final class ScrollStitchingResultWindow: NSWindowController, ConsoleTraceLogging {

    private static var liveControllers: [ScrollStitchingResultWindow] = []

    static func present(image: NSImage) {
        Self.debugLog("准备展示滚动截图结果窗口，尺寸=\(Int(image.size.width))x\(Int(image.size.height))。")
        let controller = ScrollStitchingResultWindow(image: image)
        liveControllers.append(controller)
        controller.window?.center()
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    static func presentEmpty() {
        Self.debugLog("准备展示滚动截图空结果窗口。")
        let controller = ScrollStitchingResultWindow(image: nil)
        liveControllers.append(controller)
        controller.window?.center()
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    private init(image: NSImage?) {
        let initialSize: NSSize = {
            if let image {
                let target = CGSize(width: 720, height: 800)
                let aspect = image.size.width / max(image.size.height, 1)
                let h = target.height
                let w = min(target.width, h * aspect)
                return NSSize(width: max(w, 480), height: h)
            }
            return NSSize(width: 480, height: 240)
        }()

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask:   [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing:     .buffered,
            defer:       false
        )
        window.title = ScrollFlowL10n.resultTitle
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let root: AnyView = {
            if let image {
                return AnyView(ScrollStitchingResultView(image: image, onClose: { [weak self] in
                    self?.close()
                }))
            }
            return AnyView(ScrollStitchingEmptyView(onClose: { [weak self] in self?.close() }))
        }()

        window.contentView = NSHostingView(rootView: root)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

extension ScrollStitchingResultWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        debugLog("滚动截图结果窗口即将关闭。")
        // Drop our retain so SwiftUI / images get freed.
        if let idx = Self.liveControllers.firstIndex(where: { $0 === self }) {
            Self.liveControllers.remove(at: idx)
        }
    }
}

private struct ScrollStitchingResultView: View, ConsoleTraceLogging {
    let image: NSImage
    let onClose: () -> Void
    @State private var copyConfirmed = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView([.vertical, .horizontal]) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(minWidth: 320)
                    .padding(12)
            }
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            HStack {
                Text("\(Int(image.size.width)) × \(Int(image.size.height)) px")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if copyConfirmed {
                    Text(ScrollFlowL10n.resultCopied)
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                Button(ScrollFlowL10n.resultCopy, action: copyToPasteboard)
                Button(ScrollFlowL10n.resultSave, action: saveToDisk)
                    .buttonStyle(.borderedProminent)
                Button(ScrollFlowL10n.resultClose, action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
    }

    private func copyToPasteboard() {
        debugLog("准备将滚动截图结果复制到剪贴板，尺寸=\(Int(image.size.width))x\(Int(image.size.height))。")
        let pb = NSPasteboard.general
        pb.clearContents()
        if let tiff = image.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
        if let png = pngData(from: image) {
            pb.setData(png, forType: .png)
        }
        withAnimation(.easeOut(duration: 0.15)) { copyConfirmed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeIn(duration: 0.2)) { copyConfirmed = false }
        }
        debugLog("滚动截图结果已写入剪贴板。")
    }

    private func saveToDisk() {
        debugLog("准备保存滚动截图结果到磁盘。")
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(ScrollFlowL10n.saveDefaultName)-\(stamp).png"
        guard panel.runModal() == .OK, let url = panel.url else {
            debugLog("用户取消了滚动截图结果保存。")
            return
        }
        guard let png = pngData(from: image) else {
            debugLog("滚动截图结果保存失败：无法生成 PNG 数据。")
            return
        }
        do {
            try png.write(to: url)
            debugLog("滚动截图结果保存完成，路径=\(url.path)。")
        } catch {
            debugLog("滚动截图结果保存失败：\(error.localizedDescription)")
            NSAlert(error: error).runModal()
        }
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

private struct ScrollStitchingEmptyView: View {
    let onClose: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text(ScrollFlowL10n.resultEmptyTitle)
                .font(.headline)
            Text(ScrollFlowL10n.resultEmptyHint)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button(ScrollFlowL10n.resultClose, action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
