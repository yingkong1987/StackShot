//
//  ScreenCaptureManager.swift
//  StackShot
//
//  ScreenCaptureKit-based continuous frame source for the scroll-stitching
//  pipeline. Captures a single window (or display) at a moderate frame rate
//  and forwards each frame's `CVPixelBuffer` into the OpenCV bridge on a
//  background queue.
//
//  Why ObservableObject instead of @Observable:
//    The project's deployment target is macOS 13.0 (see project.pbxproj),
//    while the `@Observable` macro / Observation framework require macOS 14+.
//    If you bump the deployment target to 14.0, swap the class declaration
//    for `@Observable final class ScreenCaptureManager { ... }` and drop the
//    `@Published` annotations — the rest of the file stays the same.
//

import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AppKit
import Combine
import OSLog

// MARK: - Public target description

/// What the manager should capture. Exposed as an enum so SwiftUI views can
/// flip between "the Safari window I just picked" and "the whole main display"
/// without the manager leaking SC* types.
enum ScreenCaptureTarget: Equatable {
    case window(SCWindow)
    case display(SCDisplay, excludingApplications: [SCRunningApplication] = [])

    static func == (lhs: ScreenCaptureTarget, rhs: ScreenCaptureTarget) -> Bool {
        switch (lhs, rhs) {
        case let (.window(a), .window(b)):    return a.windowID == b.windowID
        case let (.display(a, _), .display(b, _)): return a.displayID == b.displayID
        default: return false
        }
    }
}

/// Errors surfaced to the UI layer.
enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case noShareableContent
    case targetNotFound
    case streamFailed(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:   return "Screen recording permission was denied."
        case .noShareableContent: return "No shareable windows or displays were found."
        case .targetNotFound:     return "The capture target is no longer available."
        case .streamFailed(let e): return "Capture stream failed: \(e.localizedDescription)"
        }
    }
}

// MARK: - Manager

@MainActor
final class ScreenCaptureManager: NSObject, ObservableObject, ConsoleTraceLogging {

    // MARK: Published state (bind these from SwiftUI)

    /// `true` while an `SCStream` is actively delivering frames.
    @Published private(set) var isCapturing: Bool = false
    /// Last error surfaced from the stream, if any. Cleared on each `start`.
    @Published private(set) var lastError: ScreenCaptureError?
    /// Total frames the output handler has accepted (useful for debug HUDs).
    @Published private(set) var deliveredFrameCount: UInt64 = 0
    /// Wall-clock timestamp of the most recent delivered frame.
    @Published private(set) var lastFrameTimestamp: Date?

    // MARK: Configuration

    /// Frames per second. ScreenCaptureKit translates this into
    /// `minimumFrameInterval`. Defaults to 12 FPS — high enough for smooth
    /// scrolling detection, low enough to keep CPU/GPU pressure modest.
    var preferredFrameRate: Int = 12

    /// Output BGRA is what OpenCV expects (`+matFromPixelBuffer:` handles it
    /// directly). Switch to `.nv12` if you need to feed Metal pipelines too.
    var pixelFormat: OSType = kCVPixelFormatType_32BGRA

    /// Closure invoked for every accepted frame. Runs on `frameQueue`,
    /// **not** the main actor — keep heavy work off the main thread.
    /// The pixel buffer is only valid for the duration of the call; if you
    /// need to keep it, copy via `OpenCVWrapper.matFromPixelBuffer`.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    // MARK: Private

    private let log = Logger(subsystem: "com.stackshot.capture", category: "ScreenCaptureManager")
    private let frameQueue = DispatchQueue(
        label: "com.stackshot.capture.frames",
        qos: .userInitiated
    )

    private var stream: SCStream?
    private var streamOutput: StreamOutputBridge?
    private var currentTarget: ScreenCaptureTarget?

    // MARK: - Discovery

    /// Lists every window/display that the user could pick as a capture
    /// target. **Always excludes our own bundle** so the SCContent picker
    /// never invites the user to capture StackShot itself.
    func fetchShareableContent() async throws -> SCShareableContent {
        do {
            // `excludingDesktopWindows: false` keeps the wallpaper visible
            // when capturing a display; `onScreenWindowsOnly: true` filters
            // out minimized/off-screen windows we can't actually capture.
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            return content
        } catch {
            throw ScreenCaptureError.streamFailed(error)
        }
    }

    /// Convenience: returns shareable windows belonging to a given bundle id
    /// (e.g. `"com.apple.Safari"`), already filtered to exclude our own app.
    func windows(forBundleIdentifier bundleID: String) async throws -> [SCWindow] {
        let content = try await fetchShareableContent()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter { window in
            guard let app = window.owningApplication else { return false }
            guard app.bundleIdentifier == bundleID else { return false }
            // Defensive: drop our own windows even if the bundle id matches.
            return app.processID != ownPID
        }
    }

    // MARK: - Lifecycle

    /// Starts streaming frames from `target`. Idempotent: calling it while
    /// already capturing tears down the previous stream first.
    func start(target: ScreenCaptureTarget, selectedCropRect: CGRect = .zero) async throws {
        debugLog("收到屏幕捕获启动请求，区域=\(selectedCropRect)，target=\(target.traceDescription)，mainThread=\(Thread.isMainThread)。")

        if isCapturing {
            debugLog("当前已有捕获会话，准备先停止旧会话。")
            await stop()
        }

        lastError = nil
        deliveredFrameCount = 0
        currentTarget = target

        let filter = await makeFilter(for: target)
        let config = makeConfiguration(for: target)
        debugLog("已生成屏幕捕获配置，minimumFrameInterval=\(config.minimumFrameInterval.seconds)，queueDepth=\(config.queueDepth)。")

        let bridge = StreamOutputBridge { [weak self] pixelBuffer, pts in
            // Hop back to the main actor only for state updates; frame
            // forwarding stays on the capture queue.
            guard let self else { return }
            self.onFrame?(pixelBuffer, pts)
            Task { @MainActor in
                self.deliveredFrameCount &+= 1
                self.lastFrameTimestamp = Date()
            }
        } onError: { [weak self] error in
            Task { @MainActor in
                self?.handleStreamError(error)
            }
        }

        let newStream = SCStream(filter: filter, configuration: config, delegate: bridge)
        do {
            try newStream.addStreamOutput(
                bridge,
                type: .screen,
                sampleHandlerQueue: frameQueue
            )
            try await newStream.startCapture()
        } catch {
            // Common failure modes: TCC denied (permission), or the target
            // window was just closed. Both bubble up as `streamFailed`.
            debugLog("启动屏幕捕获失败：\(error.localizedDescription)")
            log.error("startCapture failed: \(error.localizedDescription, privacy: .public)")
            throw ScreenCaptureError.streamFailed(error)
        }

        self.stream = newStream
        self.streamOutput = bridge
        self.isCapturing = true
        debugLog("屏幕捕获已启动，目标=\(target.traceDescription)，FPS=\(self.preferredFrameRate)。")
        log.info("Capture started @\(self.preferredFrameRate, privacy: .public) FPS")
    }

    /// Stops the active stream and releases all SC* resources. Safe to call
    /// when no stream is running.
    func stop() async {
        guard let stream = self.stream else {
            isCapturing = false
            debugLog("停止屏幕捕获时未发现活动流，直接重置状态。")
            return
        }
        debugLog("准备停止当前屏幕捕获流。")
        do {
            try await stream.stopCapture()
        } catch {
            debugLog("停止屏幕捕获失败：\(error.localizedDescription)")
            log.error("stopCapture error: \(error.localizedDescription, privacy: .public)")
        }
        self.stream = nil
        self.streamOutput = nil
        self.currentTarget = nil
        self.isCapturing = false
        debugLog("屏幕捕获已停止。")
    }

    // MARK: - Filter / configuration

    private func makeFilter(for target: ScreenCaptureTarget) async -> SCContentFilter {
        switch target {
        case .window(let window):
            // Single-window capture: SCContentFilter takes only the desired
            // window. ScreenCaptureKit naturally ignores everything else, so
            // our own UI never bleeds into the frame.
            return SCContentFilter(desktopIndependentWindow: window)

        case .display(let display, let excludingApplications):
            // Whole-display capture: explicitly exclude our own running app
            // (plus any caller-supplied extras like a notes overlay).
            var excluded = excludingApplications
            if let ownApp = await currentRunningApplication() {
                excluded.append(ownApp)
            }
            return SCContentFilter(
                display: display,
                excludingApplications: excluded,
                exceptingWindows: []
            )
        }
    }

    /// Async lookup of our own `SCRunningApplication`. Returns `nil` if SCK
    /// hasn't enumerated us yet — the resulting filter just won't self-
    /// exclude, which is harmless for single-window captures.
    private func currentRunningApplication() async -> SCRunningApplication? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        ) else { return nil }
        return content.applications.first { $0.processID == ownPID }
    }

    private func makeConfiguration(for target: ScreenCaptureTarget) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()

        // Frame rate — ScreenCaptureKit expects a *minimum interval* between
        // frames, which acts as the cap. 1/12 ≈ 83ms.
        let fps = max(1, preferredFrameRate)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))

        // Pixel format / color space tuned for OpenCV consumption.
        config.pixelFormat = pixelFormat
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 5     // small buffer; we drop on the floor if stitcher lags

        // Hide the system mouse cursor — irrelevant for scroll stitching and
        // it would otherwise leave a smear in the stitched long image.
        config.showsCursor = false

        // Match the source's pixel dimensions to avoid a costly downscale.
        switch target {
        case .window(let w):
            config.width  = Int(w.frame.width  * scaleFactor(for: w))
            config.height = Int(w.frame.height * scaleFactor(for: w))
        case .display(let d, _):
            config.width  = d.width
            config.height = d.height
        }

        return config
    }

    private func scaleFactor(for window: SCWindow) -> CGFloat {
        // Find the screen the window's center sits on; fall back to main.
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.main
        return screen?.backingScaleFactor ?? 2.0
    }

    // MARK: - Error funnel

    private func handleStreamError(_ error: Error) {
        debugLog("捕获流上报错误：\(error.localizedDescription)")
        log.error("stream error: \(error.localizedDescription, privacy: .public)")
        lastError = .streamFailed(error)
        Task { await stop() }
    }
}

private extension ScreenCaptureTarget {
    var traceDescription: String {
        switch self {
        case .window(let window):
            let title = window.title?.isEmpty == false ? window.title! : "未命名窗口"
            return "window(id=\(window.windowID), title=\(title))"
        case .display(let display, let excludingApplications):
            return "display(id=\(display.displayID), excludingApps=\(excludingApplications.count))"
        }
    }
}

// MARK: - Output / delegate bridge

/// Combines `SCStreamOutput` and `SCStreamDelegate` into a single object so
/// the manager only holds one strong reference and we don't risk retain
/// cycles between the stream and an Objective-C bridge.
private final class StreamOutputBridge: NSObject, SCStreamOutput, SCStreamDelegate {

    private let frameHandler: (CVPixelBuffer, CMTime) -> Void
    private let errorHandler: (Error) -> Void

    init(
        frameHandler: @escaping (CVPixelBuffer, CMTime) -> Void,
        onError errorHandler: @escaping (Error) -> Void
    ) {
        self.frameHandler = frameHandler
        self.errorHandler = errorHandler
        super.init()
    }

    // MARK: SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        guard sampleBuffer.isValid else { return }

        // Inspect attachments to skip frames marked as "idle" — SCK delivers
        // these to keep the pipeline alive even when nothing changed on
        // screen. We don't want to feed identical frames into the stitcher.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
           let info = attachments.first,
           let statusRaw = info[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // The sample buffer (and its pixel buffer) is only retained for the
        // duration of this callback. Downstream consumers that want to keep
        // the data must copy it — `OpenCVWrapper.matFromPixelBuffer` does
        // exactly that.
        frameHandler(pixelBuffer, pts)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        errorHandler(error)
    }
}
