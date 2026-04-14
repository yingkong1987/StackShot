import AppKit
import CoreGraphics

struct WindowUnderMouseInfo: Equatable {
    let windowID: CGWindowID
    /// Quartz 全局坐标（左下角为原点），与 `NSScreen` / `NSWindow` 一致
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
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let idNum = entry[kCGWindowNumber as String] as? NSNumber,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = cgRect(fromPlist: boundsDict) else { continue }

            if rect.width < 8 || rect.height < 8 { continue }
            if !rect.contains(mouse) { continue }

            let title = entry[kCGWindowName as String] as? String
            return WindowUnderMouseInfo(windowID: CGWindowID(idNum.uint32Value), bounds: rect, title: title)
        }

        return nil
    }

    private static func cgRect(fromPlist dict: [String: Any]) -> CGRect? {
        guard let x = doubleValue(dict["X"]),
              let y = doubleValue(dict["Y"]),
              let w = doubleValue(dict["Width"]),
              let h = doubleValue(dict["Height"]) else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static func doubleValue(_ any: Any?) -> CGFloat? {
        switch any {
        case let n as NSNumber:
            return CGFloat(truncating: n)
        case let d as Double:
            return CGFloat(d)
        default:
            return nil
        }
    }
}
