import AppKit
import ApplicationServices
import CoreGraphics

struct WindowUnderMouseInfo: Equatable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    /// AppKit 全局坐标（左下角为原点），与 `NSScreen` / `NSWindow` 一致
    let bounds: CGRect
    let title: String?
}

final class WindowUnderMouseSnapshot {
    let windows: [WindowUnderMouseInfo]

    init(windows: [WindowUnderMouseInfo]) {
        self.windows = windows
    }

    func window(at point: CGPoint) -> WindowUnderMouseInfo? {
        let candidates = windows.filter { $0.bounds.contains(point) }
        guard let frontmostCandidate = candidates.first else { return nil }

        let sameProcessCandidates = candidates.filter { $0.ownerPID == frontmostCandidate.ownerPID }
        return sameProcessCandidates.max(by: { lhs, rhs in
            if lhs.bounds.area == rhs.bounds.area {
                return lhs.bounds.minY > rhs.bounds.minY
            }
            return lhs.bounds.area < rhs.bounds.area
        }) ?? frontmostCandidate
    }

    func bestMatch(pid: pid_t, bounds: CGRect, title: String?, point: CGPoint) -> WindowUnderMouseInfo? {
        let sameProcessCandidates = windows.filter {
            $0.ownerPID == pid && $0.bounds.contains(point)
        }
        guard sameProcessCandidates.isEmpty == false else { return nil }

        if let exact = bestWindow(in: sameProcessCandidates.filter({
            $0.ownerPID == pid && rectsApproximatelyEqual($0.bounds, bounds)
        }), at: point) {
            return exact
        }

        if let title, title.isEmpty == false,
           let titled = bestWindow(in: sameProcessCandidates.filter({ $0.title == title }), at: point) {
            return titled
        }

        let rankedCandidates = sameProcessCandidates.sorted {
            let lhsScore = overlapScore(for: $0, targetBounds: bounds)
            let rhsScore = overlapScore(for: $1, targetBounds: bounds)
            if lhsScore == rhsScore {
                return $0.bounds.area < $1.bounds.area
            }
            return lhsScore > rhsScore
        }

        return bestWindow(in: rankedCandidates, at: point) ?? rankedCandidates.first
    }

    func directWindowMatch(pid: pid_t, bounds: CGRect, title: String?, point: CGPoint) -> WindowUnderMouseInfo? {
        if let exact = windows.first(where: {
            $0.ownerPID == pid && rectsApproximatelyEqual($0.bounds, bounds)
        }) {
            return exact
        }

        if let title, title.isEmpty == false,
           let titled = windows.first(where: {
               $0.ownerPID == pid && $0.title == title && rectsApproximatelyEqual($0.bounds, bounds, tolerance: 12)
           }) {
            return titled
        }

        return nil
    }

    private func rectsApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 3) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance
            && abs(lhs.origin.y - rhs.origin.y) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private func bestWindow(in candidates: [WindowUnderMouseInfo], at point: CGPoint) -> WindowUnderMouseInfo? {
        let sortedCandidates = candidates.sorted {
            if $0.bounds.area == $1.bounds.area {
                return $0.bounds.minY > $1.bounds.minY
            }
            return $0.bounds.area > $1.bounds.area
        }

        return sortedCandidates.first
    }

    private func overlapScore(for window: WindowUnderMouseInfo, targetBounds: CGRect) -> CGFloat {
        let intersection = window.bounds.intersection(targetBounds)
        guard intersection.isNull == false else { return 0 }
        return intersection.area
    }

}

private extension CGRect {
    var area: CGFloat { width * height }
}

enum WindowUnderMouseService {
    static func accessibilityPermissionGranted() -> Bool {
        #if DEBUG
        true
        #else
        AXIsProcessTrusted()
        #endif
    }

    @MainActor
    static func requestAccessibilityPermission() -> Bool {
        #if DEBUG
        true
        #else
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
        #endif
    }

    @MainActor
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// 返回当前屏幕上可见窗口的冻结快照，顺序与 WindowServer 返回顺序一致（前到后）。
    static func captureSnapshot(primaryScreenHeight: CGFloat? = NSScreen.screens.first?.frame.height) -> WindowUnderMouseSnapshot {
        let myPID = ProcessInfo.processInfo.processIdentifier

        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return WindowUnderMouseSnapshot(windows: [])
        }

        let windows = list.compactMap {
            windowInfo(from: $0, excludingPID: myPID, primaryScreenHeight: primaryScreenHeight)
        }
        return WindowUnderMouseSnapshot(windows: windows)
    }

    /// 返回指针下视觉上最靠前的 UI / 窗口；优先 Accessibility，回退到冻结窗口列表。
    static func windowUnderMouse(snapshot: WindowUnderMouseSnapshot? = nil) -> WindowUnderMouseInfo? {
        window(at: NSEvent.mouseLocation, snapshot: snapshot)
    }

    static func window(at point: CGPoint, snapshot: WindowUnderMouseSnapshot? = nil) -> WindowUnderMouseInfo? {
        let frozenSnapshot = snapshot ?? captureSnapshot()

        if let axInfo = accessibilityWindow(at: point, snapshot: frozenSnapshot) {
            return axInfo
        }

        return frozenSnapshot.window(at: point)
    }

    private static func cgRect(fromPlist dict: [String: Any]) -> CGRect? {
        CGRect(dictionaryRepresentation: dict as CFDictionary)
    }

    private static func windowInfo(
        from entry: [String: Any],
        excludingPID: pid_t,
        primaryScreenHeight: CGFloat?
    ) -> WindowUnderMouseInfo? {
        guard let pidNum = entry[kCGWindowOwnerPID as String] as? NSNumber else { return nil }
        let pid = pidNum.int32Value
        if pid == excludingPID { return nil }

        let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
        if alpha <= 0.01 { return nil }

        guard let wid = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
              let quartzRect = cgRect(fromPlist: boundsDict) else {
            return nil
        }

        let rect = appKitRect(fromQuartzRect: quartzRect, primaryScreenHeight: primaryScreenHeight)
        if rect.width < 8 || rect.height < 8 { return nil }

        let title = entry[kCGWindowName as String] as? String
        return WindowUnderMouseInfo(windowID: CGWindowID(wid), ownerPID: pid, bounds: rect, title: title)
    }

    private static func accessibilityWindow(at point: CGPoint, snapshot: WindowUnderMouseSnapshot) -> WindowUnderMouseInfo? {
        guard accessibilityPermissionGranted() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        let quartzPoint = quartzPoint(fromAppKitPoint: point)
        var hitElement: AXUIElement?

        guard AXUIElementCopyElementAtPosition(systemWide, Float(quartzPoint.x), Float(quartzPoint.y), &hitElement) == .success,
              let hitElement else {
            return nil
        }

        let resolvedWindowElement = resolveWindowElement(from: hitElement)
        let targetElement = resolvedWindowElement
            ?? copyElementAttribute(hitElement, attribute: kAXTopLevelUIElementAttribute as CFString)
            ?? hitElement

        var pid: pid_t = 0
        guard AXUIElementGetPid(targetElement, &pid) == .success else { return nil }
        if pid == ProcessInfo.processInfo.processIdentifier { return nil }

        guard let bounds = copyAXBounds(of: targetElement) ?? copyAXBounds(of: hitElement) else {
            return nil
        }

        let title = copyStringAttribute(from: targetElement, attribute: kAXTitleAttribute as CFString)
            ?? copyStringAttribute(from: hitElement, attribute: kAXTitleAttribute as CFString)

        if resolvedWindowElement != nil {
            return snapshot.directWindowMatch(pid: pid, bounds: bounds, title: title, point: point)
                ?? WindowUnderMouseInfo(windowID: 0, ownerPID: pid, bounds: bounds, title: title)
        }

        return snapshot.bestMatch(pid: pid, bounds: bounds, title: title, point: point)
            ?? WindowUnderMouseInfo(windowID: 0, ownerPID: pid, bounds: bounds, title: title)
    }

    private static func quartzPoint(fromAppKitPoint point: CGPoint) -> CGPoint {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return point }
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    private static func copyElementAttribute(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func copyStringAttribute(from element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func resolveWindowElement(from element: AXUIElement) -> AXUIElement? {
        if role(of: element) == kAXWindowRole as String {
            return element
        }

        if let window = copyElementAttribute(element, attribute: kAXWindowAttribute as CFString) {
            return window
        }

        var currentElement: AXUIElement? = element
        for _ in 0..<12 {
            guard let current = currentElement else { break }
            if role(of: current) == kAXWindowRole as String {
                return current
            }

            currentElement = copyElementAttribute(current, attribute: kAXParentAttribute as CFString)
        }

        if let topLevel = copyElementAttribute(element, attribute: kAXTopLevelUIElementAttribute as CFString) {
            if role(of: topLevel) == kAXWindowRole as String {
                return topLevel
            }

            var currentElement: AXUIElement? = topLevel
            for _ in 0..<8 {
                guard let current = currentElement else { break }
                if role(of: current) == kAXWindowRole as String {
                    return current
                }

                currentElement = copyElementAttribute(current, attribute: kAXParentAttribute as CFString)
            }
        }

        return nil
    }

    private static func role(of element: AXUIElement) -> String? {
        copyStringAttribute(from: element, attribute: kAXRoleAttribute as CFString)
    }

    private static func copyAXBounds(of element: AXUIElement) -> CGRect? {
        guard let position = copyCGPointAttribute(from: element, attribute: kAXPositionAttribute as CFString),
              let size = copyCGSizeAttribute(from: element, attribute: kAXSizeAttribute as CFString) else {
            return nil
        }

        return appKitRect(fromQuartzRect: CGRect(origin: position, size: size))
    }

    private static func copyCGPointAttribute(from element: AXUIElement, attribute: CFString) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { return nil }

        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func copyCGSizeAttribute(from element: AXUIElement, attribute: CFString) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else { return nil }

        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func appKitRect(fromQuartzRect rect: CGRect) -> CGRect {
        appKitRect(fromQuartzRect: rect, primaryScreenHeight: NSScreen.screens.first?.frame.height)
    }

    private static func appKitRect(fromQuartzRect rect: CGRect, primaryScreenHeight: CGFloat?) -> CGRect {
        // Quartz 坐标原点在主屏幕左上角，AppKit 在主屏幕左下角，
        // 转换只需要主屏幕高度，用整个桌面 union 高度在多屏纵向排列时会算错。
        guard let primaryHeight = primaryScreenHeight else { return rect }

        return CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}
