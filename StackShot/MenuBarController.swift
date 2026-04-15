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

        // 参考 StackPaste：菜单栏使用模板 SF Symbol，不直接缩放应用图标位图。
        // 这样可与系统菜单栏图标尺寸和高亮行为保持一致。
        // https://developer.apple.com/documentation/appkit/nsstatusitem
        // https://developer.apple.com/design/human-interface-guidelines/the-menu-bar

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imageScaling = .scaleProportionallyDown
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

    /// 菜单栏图标尺寸：在原 14pt 基础上放大到 156%（130% 后再增加 20%）。
    private static let statusBarIconPointSize: CGFloat = 14 * 1.3 * 1.2

    private static func makeStatusBarIconImage() -> NSImage {
        if let base = NSImage(named: "MenuBarLogoTemplate"),
           let logo = base.copy() as? NSImage {
            logo.isTemplate = true
            logo.size = NSSize(width: statusBarIconPointSize, height: statusBarIconPointSize)
            return logo
        }

        let symbol = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "StackShot")
            ?? NSImage()
        symbol.isTemplate = true
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: statusBarIconPointSize, weight: .regular)
        return symbol.withSymbolConfiguration(symbolConfig) ?? symbol
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
