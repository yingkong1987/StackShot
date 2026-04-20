import AppKit

final class MenuBarController: NSObject, NSWindowDelegate {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private weak var mainWindow: NSWindow?
    private var didSetup = false

    /// UserDefaults key marking that the welcome / settings window has been
    /// shown at least once. After the first launch we keep it hidden so the
    /// menu-bar app behaves like a true menu-bar utility.
    private static let mainWindowShownBeforeKey = "StackShotMainWindowShownBefore"

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

        // 仅在「首次启动」时把主窗口呈现给用户作为欢迎/设置面板；之后启动
        // 一律保持隐藏，由菜单栏入口或快捷键唤出。这样可以避免每次开机自启
        // 时主窗口都跳出来打断用户。
        //
        // 注意：SwiftUI 的 WindowGroup 在 macOS 13 上没有 .defaultLaunchBehavior
        // 可用，窗口在 SwiftUI 创建时已经被显示出来；我们只能在 WindowAccessor
        // 拿到引用后立即 orderOut。视觉上有极短一瞬的闪烁，无法完全避免。
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.mainWindowShownBeforeKey) {
            window.orderOut(nil)
        } else {
            defaults.set(true, forKey: Self.mainWindowShownBeforeKey)
            bringMainWindowToFront()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindow else { return true }
        sender.orderOut(nil)
        NSApp.hide(nil)
        return false
    }

    @objc
    private func showMainWindow() {
        bringMainWindowToFront()
    }

    private func bringMainWindowToFront() {
        guard let mainWindow else { return }
        // Accessory 模式或其他 App 处于前台时，单独的 activate / makeKeyAndOrderFront 偶尔无效，
        // 同时调用 NSRunningApplication.activate 与 orderFrontRegardless 才能稳定把窗口置顶。
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        mainWindow.makeKeyAndOrderFront(nil)
        mainWindow.orderFrontRegardless()
    }

    @objc
    private func quitApp() {
        NSApp.terminate(nil)
    }

}
