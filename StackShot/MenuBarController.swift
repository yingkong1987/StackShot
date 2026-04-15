import AppKit

final class MenuBarController: NSObject, NSWindowDelegate {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private weak var mainWindow: NSWindow?
    private var didSetup = false

    private override init() {}

    func setup() {
        guard !didSetup else { return }
        didSetup = true

        applyRoundedAppIcon()
        SettingsStore.shared.applyDockPolicy()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let logo = NSImage(named: "AppLogo") {
                button.image = roundedImage(from: logo, size: NSSize(width: 18, height: 18), cornerRadius: 4.5)
            } else {
                button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "StackShot")
            }
            button.toolTip = "StackShot"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示主窗口", action: #selector(showMainWindow), keyEquivalent: "s"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 StackShot", action: #selector(quitApp), keyEquivalent: "q"))
        item.menu = menu

        statusItem = item
    }

    func attachMainWindow(_ window: NSWindow) {
        guard window !== mainWindow else { return }
        mainWindow = window
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindow else { return true }
        sender.orderOut(nil)
        NSApp.hide(nil)
        return false
    }

    @objc
    private func showMainWindow() {
        guard let mainWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow.makeKeyAndOrderFront(nil)
    }

    @objc
    private func quitApp() {
        NSApp.terminate(nil)
    }

    private func applyRoundedAppIcon() {
        guard let logo = NSImage(named: "AppLogo") else { return }
        if let rounded = roundedImage(from: logo, size: NSSize(width: 512, height: 512), cornerRadius: 104) {
            NSApp.applicationIconImage = rounded
        }
    }

    private func roundedImage(from source: NSImage, size: NSSize, cornerRadius: CGFloat) -> NSImage? {
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high

        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        path.addClip()
        source.draw(in: rect, from: .zero, operation: .copy, fraction: 1.0)

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
