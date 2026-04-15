import AppKit
import CoreGraphics

struct WindowUnderMouseInfo: Equatable {
    let windowID: CGWindowID
    /// AppKit 全局坐标（左下角为原点），与 `NSScreen` / `NSWindow` 一致
    let bounds: CGRect
    let title: String?
}

enum WindowUnderMouseService {
    /// 返回指针下最靠前、可交互的普通层级窗口（排除本应用窗口）。
    static func windowUnderMouse() -> WindowUnderMouseInfo? {
        let mouse = NSEvent.mouseLocation
        let myPID = ProcessInfo.processInfo.processIdentifier

        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for entry in list {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  pid != myPID,
                  (entry[kCGWindowIsOnscreen as String] as? Int) == 1,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let alpha = entry[kCGWindowAlpha as String] as? Double,
                  alpha > 0.01,
                  let idNum = entry[kCGWindowNumber as String] as? NSNumber,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let quartzRect = cgRect(fromPlist: boundsDict) else { continue }

            // CGWindow 返回的 Y 轴坐标是基于 Quartz 顶部原点，需要转换到 AppKit 全局坐标系。
            let rect = appKitRect(fromQuartzRect: quartzRect)

            if rect.width < 8 || rect.height < 8 { continue }
            if !rect.contains(mouse) { continue }

            let title = entry[kCGWindowName as String] as? String
            return WindowUnderMouseInfo(windowID: CGWindowID(idNum.uint32Value), bounds: rect, title: title)
        }

        return nil
    }

    private static func cgRect(fromPlist dict: [String: Any]) -> CGRect? {
        CGRect(dictionaryRepresentation: dict as CFDictionary)
    }

    private static func appKitRect(fromQuartzRect rect: CGRect) -> CGRect {
        let desktopBounds = NSScreen.screens.reduce(CGRect.null) { partial, screen in
            partial.union(screen.frame)
        }
        guard desktopBounds.isNull == false else { return rect }

        return CGRect(
            x: rect.origin.x,
            y: desktopBounds.maxY - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}
