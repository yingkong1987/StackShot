import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
    static let shared = MenuBarController()
    private static let statusBarColorIconName = NSImage.Name("AppLogo")
    private static let statusBarIconSize = NSSize(width: 20, height: 20)
    private static let statusBarIconCornerRadius: CGFloat = 4.5

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

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.makeStatusBarIconImage()
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = L10n.tr("menu.status.tooltip")
        }

        item.menu = makeMenu()

        statusItem = item
    }

    func refreshLocalizedUI() {
        guard let item = statusItem else { return }
        item.button?.toolTip = L10n.tr("menu.status.tooltip")
        item.menu = makeMenu()
    }

    private static func makeStatusBarIconImage() -> NSImage {
        if let logo = preparedRoundedStatusBarIcon(named: statusBarColorIconName) {
            return logo
        }

        let fallback = (NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "StackShot")
            ?? NSImage()).copy() as? NSImage ?? NSImage()
        fallback.isTemplate = true
        fallback.size = statusBarIconSize
        return fallback
    }

    private static func preparedRoundedStatusBarIcon(named name: NSImage.Name) -> NSImage? {
        guard let logo = NSImage(named: name)?.copy() as? NSImage else { return nil }
        return roundedStatusBarIcon(from: logo)
    }

    private static func roundedStatusBarIcon(from source: NSImage) -> NSImage {
        let icon = NSImage(size: statusBarIconSize)
        icon.lockFocus()
        defer { icon.unlockFocus() }

        let drawRect = NSRect(origin: .zero, size: statusBarIconSize)
        NSBezierPath(
            roundedRect: drawRect,
            xRadius: statusBarIconCornerRadius,
            yRadius: statusBarIconCornerRadius
        )
        .addClip()
        source.draw(
            in: drawRect,
            from: NSRect(origin: .zero, size: source.size),
            operation: .sourceOver,
            fraction: 1
        )
        icon.isTemplate = false
        return icon
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let showItem = NSMenuItem(
            title: L10n.tr("menu.show_main_window"),
            action: #selector(showMainWindow),
            keyEquivalent: "s"
        )
        showItem.target = self
        menu.addItem(showItem)

        let privacyItem = NSMenuItem(
            title: AppComplianceL10n.privacyMenuItem,
            action: #selector(showPrivacyPolicy),
            keyEquivalent: ""
        )
        privacyItem.target = self
        menu.addItem(privacyItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: L10n.tr("menu.quit_app"),
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
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
        presentMainWindow()
    }

    func presentMainWindow() {
        bringMainWindowToFront()
    }

    @objc
    private func showPrivacyPolicy() {
        AppPrivacyPolicyPresenter.show()
    }

    func hideMainWindow() {
        mainWindow?.orderOut(nil)
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

enum AppStoreComplianceFeatures {
    static let isOCRTranslationOverlayEnabled = true
}

enum AppComplianceL10n {
    static var privacyMenuItem: String {
        L10n.tr("compliance.privacy.menu_item")
    }

    static var privacySectionTitle: String {
        L10n.tr("compliance.privacy.section_title")
    }

    static var privacyCardSummary: String {
        L10n.tr("compliance.privacy.card_summary")
    }

    static var openPrivacyPolicy: String {
        L10n.tr("compliance.privacy.open_policy")
    }

    static var screenRecordingTitle: String {
        L10n.tr("compliance.screen_recording.title")
    }

    static var screenRecordingSummary: String {
        L10n.tr("compliance.screen_recording.summary")
    }

    static var accessibilityTitle: String {
        L10n.tr("compliance.accessibility.title")
    }

    static func accessibilitySummary(isGranted: Bool) -> String {
        L10n.tr(
            isGranted
                ? "compliance.accessibility.summary.granted"
                : "compliance.accessibility.summary.not_granted"
        )
    }

    static func accessibilityButtonTitle(isGranted: Bool) -> String {
        L10n.tr(
            isGranted
                ? "compliance.accessibility.button.open_settings"
                : "compliance.accessibility.button.request_access"
        )
    }

    static var openScreenRecordingSettings: String {
        L10n.tr("compliance.screen_recording.open_settings")
    }

    static var privacyWindowTitle: String {
        privacyMenuItem
    }

    static var privacyWindowIntro: String {
        L10n.tr("compliance.privacy.window.intro")
    }

    static var privacyPolicyParagraphs: [String] {
        (1...6).map { L10n.tr("compliance.privacy.paragraph.\($0)") }
    }

    static var privacyWindowFooter: String {
        L10n.tr("compliance.privacy.window.footer")
    }

    static var close: String {
        L10n.tr("common.close")
    }

    static var ocrTranslationUnavailableMessage: String {
        L10n.tr("editor.ocr.translate.unavailable")
    }
}

@MainActor
enum AppPermissionSupport {
    static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    static func requestAccessibilityAccess() {
        if !WindowUnderMouseService.requestAccessibilityPermission() {
            WindowUnderMouseService.openAccessibilitySettings()
        }
    }
}

@MainActor
enum AppPrivacyPolicyPresenter {
    private static var controller: AppPrivacyPolicyWindowController?

    static func show() {
        if controller == nil {
            controller = AppPrivacyPolicyWindowController()
        }
        controller?.refreshContent()
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func clear(_ controller: AppPrivacyPolicyWindowController) {
        if self.controller === controller {
            self.controller = nil
        }
    }
}

@MainActor
final class AppPrivacyPolicyWindowController: NSWindowController, NSWindowDelegate {
    private let hostingView = NSHostingView(rootView: AppPrivacyPolicyView())

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AppComplianceL10n.privacyWindowTitle
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false

        super.init(window: window)

        hostingView.rootView = AppPrivacyPolicyView()
        window.contentView = hostingView
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func refreshContent() {
        window?.title = AppComplianceL10n.privacyWindowTitle
        hostingView.rootView = AppPrivacyPolicyView()
    }

    func windowWillClose(_ notification: Notification) {
        AppPrivacyPolicyPresenter.clear(self)
    }
}

private struct AppPrivacyPolicyView: View {
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(AppComplianceL10n.privacyWindowIntro)
                        .font(.system(size: 14))
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(Array(AppComplianceL10n.privacyPolicyParagraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(AppComplianceL10n.privacyWindowFooter)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Spacer()
                Button(AppComplianceL10n.close) {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
