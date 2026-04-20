//
//  ScrollStitchingFlow.swift
//  StackShot
//
//  End-to-end SwiftUI/AppKit interaction layer that wires together:
//
//      RegionSelection ──▶ ScrollStitchingCoordinator
//                              │
//                              ├─▶ ScreenCaptureManager (SCStream @ 12 FPS)
//                              ├─▶ OpenCVWrapper (CVPixelBuffer ➜ Mat ➜ crop)
//                              ├─▶ VerticalScrollStitcher (phaseCorrelate)
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
//      • User presses Esc anywhere on the system (global monitor)
//      • Coordinator times out after a hard cap (safety, default 5 minutes)
//
//  This file is intentionally self-contained — it does not modify the
//  existing `ScrollCaptureSession` flow, so you can A/B both pipelines.
//

import AppKit
import SwiftUI
import Combine
import CoreGraphics
import ScreenCaptureKit
import UniformTypeIdentifiers
import OSLog

// MARK: - Localization helper (zh-Hans / zh-Hant / en / ja per user-memory rule)

private enum ScrollFlowL10n {
    static func tr(zhHans: String, zhHant: String, ja: String, en: String) -> String {
        switch L10n.currentSelectionCode() {
        case let code where code.hasPrefix("zh-Hans"): return zhHans
        case let code where code.hasPrefix("zh-Hant"): return zhHant
        case let code where code.hasPrefix("ja"):      return ja
        default:                                       return en
        }
    }

    static var hudWatching: String {
        tr(zhHans: "正在监控滚动…",
           zhHant: "正在監控捲動…",
           ja:     "スクロールを監視中…",
           en:     "Monitoring scroll…")
    }
    static var hudHint: String {
        tr(zhHans: "把鼠标移到目标窗口慢慢滚动；按 Esc 或点击「完成」结束。",
           zhHant: "把滑鼠移到目標視窗慢慢捲動；按 Esc 或點擊「完成」結束。",
           ja:     "対象ウィンドウにカーソルを移動してスクロール。Esc か「完了」で停止。",
           en:     "Hover the target window and scroll slowly. Press Esc or click Done to stop.")
    }
    static var hudDone: String {
        tr(zhHans: "完成", zhHant: "完成", ja: "完了", en: "Done")
    }
    static var hudCancel: String {
        tr(zhHans: "取消", zhHant: "取消", ja: "キャンセル", en: "Cancel")
    }
    static func hudFramesFormat(_ accepted: Int, _ total: Int, _ pixels: Int) -> String {
        tr(zhHans: "已拼接 \(pixels)px · 帧 \(accepted)/\(total)",
           zhHant: "已拼接 \(pixels)px · 幀 \(accepted)/\(total)",
           ja:     "縫合 \(pixels)px · フレーム \(accepted)/\(total)",
           en:     "Stitched \(pixels)px · Frames \(accepted)/\(total)")
    }
    static var resultTitle: String {
        tr(zhHans: "滚动长截图", zhHant: "捲動長截圖", ja: "スクロール長尺スクリーンショット", en: "Scrolling Screenshot")
    }
    static var resultSave: String {
        tr(zhHans: "保存到本地…", zhHant: "儲存到本機…", ja: "ローカルに保存…", en: "Save to Disk…")
    }
    static var resultCopy: String {
        tr(zhHans: "复制到剪贴板", zhHant: "複製到剪貼簿", ja: "クリップボードにコピー", en: "Copy to Clipboard")
    }
    static var resultCopied: String {
        tr(zhHans: "已复制", zhHant: "已複製", ja: "コピーしました", en: "Copied")
    }
    static var resultClose: String {
        tr(zhHans: "关闭", zhHant: "關閉", ja: "閉じる", en: "Close")
    }
    static var resultEmptyTitle: String {
        tr(zhHans: "未捕获到滚动",
           zhHant: "未擷取到捲動",
           ja:     "スクロールを取得できませんでした",
           en:     "No scrolling was captured")
    }
    static var resultEmptyHint: String {
        tr(zhHans: "请在选区内的窗口中滚动后再次尝试。",
           zhHant: "請在選區內的視窗中捲動後再次嘗試。",
           ja:     "選択領域内のウィンドウでスクロールしてから再試行してください。",
           en:     "Try again — scroll inside the selected window region.")
    }
    static var saveDefaultName: String {
        tr(zhHans: "滚动长截图", zhHant: "捲動長截圖", ja: "スクロール長尺", en: "Scrolling Screenshot")
    }
}

// MARK: - Coordinator

@MainActor
final class ScrollStitchingCoordinator {

    static let shared = ScrollStitchingCoordinator()

    // Shared infra. Created lazily on the main actor so SwiftUI bindings work.
    private let captureManager = ScreenCaptureManager()
    /// `nonisolated(unsafe)` because the C++ stitcher is single-threaded by
    /// contract — we feed it only from the SCK frame queue, and the
    /// main-actor methods (`start`/`finish`) only touch it before frames
    /// start flowing or after `captureManager.stop()` has returned.
    nonisolated(unsafe) private let stitcher = VerticalScrollStitcher()
    private let log = Logger(subsystem: "com.stackshot.capture", category: "ScrollStitchingFlow")

    // Live UI surfaces.
    private var hudPanel: ScrollStitchingHUDPanel?
    private var hudViewModel: ScrollStitchingHUDViewModel?

    // Region & geometry recorded at start time.
    private var selectedCropRect: CGRect = .zero
    private var sourceDisplay: SCDisplay?
    private var screenForCrop: NSScreen?
    private var pixelCropRect: CGRect = .zero   // in source-Mat pixel coords

    // Global Esc monitor.
    private var globalEscMonitor: Any?
    private var localEscMonitor: Any?

    // Hard timeout safety net.
    private var timeoutTask: Task<Void, Never>?
    private var maxCaptureDuration: TimeInterval = 5 * 60

    // Re-entry guard.
    private var isActive = false
    private var completion: ((NSImage?) -> Void)?

    private init() {}

    // MARK: Public entry point

    /// Begin a scroll-stitching session over `selectedCropRect` (in AppKit
    /// screen coordinates — origin bottom-left, the same coord system the
    /// region-selection overlay returns).
    ///
    /// The coordinator handles all UI: HUD, Esc handling, result window.
    /// `completion` fires *after* the result window has been shown (or
    /// immediately with `nil` on cancel/empty), in case the caller wants to
    /// re-show its own UI.
    func start(selectedCropRect rect: CGRect,
               completion: ((NSImage?) -> Void)? = nil) {

        print("🟢 ScrollStitchingCoordinator.start 收到区域: \(rect)")

        guard !isActive else {
            print("⚠️ ScrollStitchingCoordinator.start 被忽略 — 已有活动会话。")
            log.warning("Ignoring start() — session already active.")
            return
        }
        guard rect.width >= 8, rect.height >= 8 else {
            log.error("Rejecting tiny selectedCropRect: \(String(describing: rect))")
            completion?(nil)
            return
        }

        // Resolve the screen / display that contains the selection's center.
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
                    ?? NSScreen.main else {
            log.error("No NSScreen contains the selectedCropRect.")
            completion?(nil); return
        }
        self.selectedCropRect = rect
        self.screenForCrop = screen
        self.completion = completion

        isActive = true
        stitcher.reset()

        // Spin up async setup: discover SCDisplay, then start streaming.
        Task { [weak self] in
            await self?.beginAsync()
        }
    }

    // MARK: Async setup

    private func beginAsync() async {
        do {
            let content = try await captureManager.fetchShareableContent()
            // Map NSScreen -> CGDirectDisplayID -> SCDisplay.
            guard let cgDisplayID = displayID(for: screenForCrop),
                  let scDisplay = content.displays.first(where: { $0.displayID == cgDisplayID }) else {
                log.error("Could not match NSScreen to an SCDisplay.")
                await failAndCleanup()
                return
            }
            self.sourceDisplay = scDisplay
            self.pixelCropRect = pixelRect(from: selectedCropRect,
                                           on: screenForCrop!,
                                           display: scDisplay)

            // Wire frame handler — runs off the main actor on capture queue.
            // Capture `crop` by value into the closure so the background
            // queue never has to touch main-actor state.
            captureManager.preferredFrameRate = 12
            captureManager.pixelFormat = kCVPixelFormatType_32BGRA
            let crop = self.pixelCropRect
            captureManager.onFrame = { [weak self] pixelBuffer, _ in
                self?.handleIncomingFrame(pixelBuffer, cropRect: crop)
            }

            try await captureManager.start(target: .display(scDisplay, excludingApplications: []))

            // UI: HUD + Esc.
            presentHUD()
            installEscMonitors()
            scheduleTimeout()
        } catch {
            log.error("ScrollStitching setup failed: \(error.localizedDescription, privacy: .public)")
            await failAndCleanup()
        }
    }

    // MARK: Frame handler (background thread)

    nonisolated private func handleIncomingFrame(_ pixelBuffer: CVPixelBuffer,
                                                 cropRect: CGRect) {
        // 只在前几帧打印,避免日志洪水。
        let framesSoFar = stitcher.framesProcessed
        if framesSoFar < 3 {
            print("🟢 OpenCVWrapper 收到帧 #\(framesSoFar + 1),裁切区域（px）: \(cropRect)")
        }

        guard let fullMat = OpenCVWrapper.mat(from: pixelBuffer) else { return }
        guard let cropped = OpenCVWrapper.matByCropping(fullMat, to: cropRect) else { return }

        var dy: Double = 0
        let result = stitcher.add(cropped, outDeltaY: &dy)

        // Push lightweight progress updates back to the HUD on the main actor.
        let accepted = (result == .appended || result == .accepted) ? 1 : 0
        let height = Int(stitcher.canvasHeight)
        Task { @MainActor [weak self] in
            self?.hudViewModel?.totalFrames &+= 1
            self?.hudViewModel?.acceptedFrames &+= accepted
            self?.hudViewModel?.canvasHeightPx = height
        }
    }

    // MARK: HUD

    private func presentHUD() {
        let viewModel = ScrollStitchingHUDViewModel()
        viewModel.onDone   = { [weak self] in Task { await self?.finish(cancelled: false) } }
        viewModel.onCancel = { [weak self] in Task { await self?.finish(cancelled: true) } }
        self.hudViewModel = viewModel

        let panel = ScrollStitchingHUDPanel(viewModel: viewModel)
        // Anchor to the top-right of the active screen for unobtrusive HUD.
        if let screen = screenForCrop {
            let panelSize = panel.frame.size
            let x = screen.frame.maxX - panelSize.width - 24
            let y = screen.frame.maxY - panelSize.height - 24
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFrontRegardless()
        self.hudPanel = panel
    }

    // MARK: Stop monitors

    private func installEscMonitors() {
        // Global: when our app is *not* key (which is the normal case while
        // user scrolls Safari), Esc anywhere on the system stops capture.
        globalEscMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return } // 53 = Escape
            Task { @MainActor in await self?.finish(cancelled: true) }
        }
        // Local: in case our HUD becomes key, the global monitor wouldn't
        // fire — cover that case too. We do not consume the event.
        localEscMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in await self?.finish(cancelled: true) }
            }
            return event
        }
    }

    private func uninstallEscMonitors() {
        if let m = globalEscMonitor { NSEvent.removeMonitor(m); globalEscMonitor = nil }
        if let m = localEscMonitor  { NSEvent.removeMonitor(m); localEscMonitor  = nil }
    }

    private func scheduleTimeout() {
        timeoutTask?.cancel()
        let cap = maxCaptureDuration
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(cap * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.finish(cancelled: false)
        }
    }

    // MARK: Finalization

    private func finish(cancelled: Bool) async {
        guard isActive else { return }
        isActive = false

        timeoutTask?.cancel(); timeoutTask = nil
        uninstallEscMonitors()
        await captureManager.stop()
        captureManager.onFrame = nil

        // Pull the stitched image off the C++ side and convert to NSImage.
        let nsImage: NSImage? = {
            guard !cancelled,
                  let mat = stitcher.stitchedImage(),
                  let cgRetained = OpenCVWrapper.cgImage(from: mat) else { return nil }
            // CF_RETURNS_RETAINED: take ownership without an extra retain.
            let cgImage = cgRetained.takeRetainedValue()
            return NSImage(cgImage: cgImage,
                           size: NSSize(width:  cgImage.width,
                                        height: cgImage.height))
        }()

        // Tear down HUD before showing result so focus shifts cleanly.
        hudPanel?.orderOut(nil); hudPanel = nil; hudViewModel = nil

        if let img = nsImage {
            ScrollStitchingResultWindow.present(image: img)
        } else {
            ScrollStitchingResultWindow.presentEmpty()
        }

        completion?(nsImage)
        completion = nil
    }

    private func failAndCleanup() async {
        isActive = false
        uninstallEscMonitors()
        timeoutTask?.cancel(); timeoutTask = nil
        await captureManager.stop()
        hudPanel?.orderOut(nil); hudPanel = nil; hudViewModel = nil
        completion?(nil); completion = nil
    }

    // MARK: Coordinate math

    /// Maps an AppKit-screen rect to source-Mat pixel coordinates.
    ///
    /// AppKit screen coords have origin bottom-left of the *primary screen*;
    /// SCK display frames have origin top-left of *that display*, in pixels.
    /// Conversion steps:
    ///   1. Translate into screen-local AppKit coords.
    ///   2. Flip Y so origin is top-left (still in points).
    ///   3. Multiply by backingScaleFactor (points → pixels).
    private func pixelRect(from screenRect: CGRect,
                           on screen: NSScreen,
                           display: SCDisplay) -> CGRect {
        let scale = screen.backingScaleFactor
        let localX = screenRect.minX - screen.frame.minX
        let localBottomUpY = screenRect.minY - screen.frame.minY
        let localTopDownY = screen.frame.height - (localBottomUpY + screenRect.height)

        let px = (localX * scale).rounded()
        let py = (localTopDownY * scale).rounded()
        let pw = (screenRect.width * scale).rounded()
        let ph = (screenRect.height * scale).rounded()

        // Clamp into the captured display's pixel bounds.
        let bounds = CGRect(x: 0, y: 0,
                            width: CGFloat(display.width),
                            height: CGFloat(display.height))
        return CGRect(x: px, y: py, width: pw, height: ph).intersection(bounds)
    }

    private func displayID(for screen: NSScreen?) -> CGDirectDisplayID? {
        guard let screen,
              let raw = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(raw.uint32Value)
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

    // Override key-window check so global Esc keeps working.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Result window

@MainActor
final class ScrollStitchingResultWindow: NSWindowController {

    private static var liveControllers: [ScrollStitchingResultWindow] = []

    static func present(image: NSImage) {
        let controller = ScrollStitchingResultWindow(image: image)
        liveControllers.append(controller)
        controller.window?.center()
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    static func presentEmpty() {
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
        // Drop our retain so SwiftUI / images get freed.
        if let idx = Self.liveControllers.firstIndex(where: { $0 === self }) {
            Self.liveControllers.remove(at: idx)
        }
    }
}

private struct ScrollStitchingResultView: View {
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
    }

    private func saveToDisk() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(ScrollFlowL10n.saveDefaultName)-\(stamp).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let png = pngData(from: image) else { return }
        do { try png.write(to: url) }
        catch { NSAlert(error: error).runModal() }
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
