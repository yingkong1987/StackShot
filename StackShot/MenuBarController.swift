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

        // Dock：使用 Bundle 内 Asset Catalog 生成的 AppIcon.icns；勿用 NSApp.applicationIconImage 覆盖为自绘圆角图。
        // https://developer.apple.com/design/human-interface-guidelines/app-icons
        NSApp.applicationIconImage = nil

        SettingsStore.shared.applyDockPolicy()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.makeStatusBarIconImage()
            button.toolTip = L10n.tr("menu.status.tooltip")
        }

        let menu = NSMenu()
        let showItem = NSMenuItem(title: L10n.tr("menu.show_main_window"), action: #selector(showMainWindow), keyEquivalent: "s")
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: L10n.tr("menu.quit_app"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu

        statusItem = item
    }

    func refreshLocalizedUI() {
        guard let item = statusItem else { return }
        item.button?.toolTip = L10n.tr("menu.status.tooltip")

        let menu = NSMenu()
        let showItem = NSMenuItem(title: L10n.tr("menu.show_main_window"), action: #selector(showMainWindow), keyEquivalent: "s")
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: L10n.tr("menu.quit_app"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
    }

    private static func makeStatusBarIconImage() -> NSImage {
        let symbol = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "StackShot")
            ?? NSImage()
        symbol.isTemplate = true
        return symbol
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

}
