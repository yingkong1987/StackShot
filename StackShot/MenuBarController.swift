import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
    static let shared = MenuBarController()
    private static let statusBarIconName = NSImage.Name("MenuBarLogoTemplate")
    private static let statusBarIconPointSize = NSSize(width: 18, height: 18)

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
        if let logo = NSImage(named: statusBarIconName)?.copy() as? NSImage {
            logo.isTemplate = true
            logo.size = statusBarIconPointSize
            return logo
        }

        let fallback = (NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "StackShot")
            ?? NSImage()).copy() as? NSImage ?? NSImage()
        fallback.isTemplate = true
        fallback.size = statusBarIconPointSize
        return fallback
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
    static let isOCRTranslationOverlayEnabled = false
}

enum AppComplianceL10n {
    static func tr(zhHans: String, zhHant: String, ja: String, en: String) -> String {
        switch L10n.currentSelectionCode() {
        case let code where code.hasPrefix("zh-Hans"): return zhHans
        case let code where code.hasPrefix("zh-Hant"): return zhHant
        case let code where code.hasPrefix("ja"): return ja
        default: return en
        }
    }

    static var privacyMenuItem: String {
        tr(zhHans: "隐私政策", zhHant: "隱私政策", ja: "プライバシーポリシー", en: "Privacy Policy")
    }

    static var privacySectionTitle: String {
        tr(zhHans: "隐私", zhHant: "隱私", ja: "プライバシー", en: "Privacy")
    }

    static var privacyCardSummary: String {
        tr(
            zhHans: "查看 StackShot 如何使用屏幕录制、辅助功能、剪贴板和本地文件访问权限。",
            zhHant: "查看 StackShot 如何使用螢幕錄製、輔助使用、剪貼簿和本機檔案存取權限。",
            ja: "StackShot が画面収録、アクセシビリティ、クリップボード、ローカルファイルアクセスをどう扱うか確認できます。",
            en: "Review how StackShot uses Screen Recording, Accessibility, the clipboard, and local file access."
        )
    }

    static var openPrivacyPolicy: String {
        tr(zhHans: "打开隐私政策", zhHant: "打開隱私政策", ja: "プライバシーポリシーを開く", en: "Open Privacy Policy")
    }

    static var screenRecordingTitle: String {
        tr(zhHans: "屏幕录制", zhHant: "螢幕錄製", ja: "画面収録", en: "Screen Recording")
    }

    static var screenRecordingSummary: String {
        tr(
            zhHans: "用于截图、滚动长截图，以及对已捕获画面执行 OCR/保存/导出。授权后若未立即生效，请完全退出并重新打开 StackShot。",
            zhHant: "用於截圖、捲動長截圖，以及對已擷取畫面執行 OCR／儲存／匯出。授權後若未立即生效，請完全結束並重新開啟 StackShot。",
            ja: "スクリーンショット、スクロールキャプチャ、取得済み画像の OCR / 保存 / 書き出しに使用します。許可後に反映されない場合は StackShot を完全終了して再起動してください。",
            en: "Used for screenshots, scrolling capture, and OCR/save/export on captured content. If permission doesn't apply immediately, fully quit and reopen StackShot."
        )
    }

    static var accessibilityTitle: String {
        tr(zhHans: "辅助功能（可选）", zhHant: "輔助使用（選用）", ja: "アクセシビリティ（任意）", en: "Accessibility (Optional)")
    }

    static func accessibilitySummary(isGranted: Bool) -> String {
        if isGranted {
            return tr(
                zhHans: "已授权。StackShot 可以更准确地识别鼠标下的前台窗口。",
                zhHant: "已授權。StackShot 可以更準確地辨識游標下的前景視窗。",
                ja: "許可済みです。StackShot はポインタ下の最前面ウィンドウをより正確に判定できます。",
                en: "Granted. StackShot can more accurately detect the frontmost window under the pointer."
            )
        }

        return tr(
            zhHans: "未授权时仍可手动框选截图，但悬停识别窗口会退回到屏幕快照匹配，精度可能降低。",
            zhHant: "未授權時仍可手動框選截圖，但懸停辨識視窗會退回到螢幕快照比對，精度可能較低。",
            ja: "未許可でも手動範囲選択は使えますが、ホバー時のウィンドウ判定は画面スナップショット照合にフォールバックするため精度が下がる場合があります。",
            en: "Without access, manual region capture still works, but hovered-window targeting falls back to screen-snapshot matching and may be less precise."
        )
    }

    static func accessibilityButtonTitle(isGranted: Bool) -> String {
        isGranted
            ? tr(zhHans: "打开辅助功能设置", zhHant: "打開輔助使用設定", ja: "アクセシビリティ設定を開く", en: "Open Accessibility Settings")
            : tr(zhHans: "请求辅助功能权限", zhHant: "要求輔助使用權限", ja: "アクセシビリティ権限を要求", en: "Request Accessibility Access")
    }

    static var openScreenRecordingSettings: String {
        tr(zhHans: "打开屏幕录制设置", zhHant: "打開螢幕錄製設定", ja: "画面収録設定を開く", en: "Open Screen Recording Settings")
    }

    static var privacyWindowTitle: String {
        privacyMenuItem
    }

    static var privacyWindowIntro: String {
        tr(
            zhHans: "StackShot 是一款本地截图工具。我们尽量只在用户明确触发的情况下访问系统权限，并优先在设备本地处理图像内容。",
            zhHant: "StackShot 是一款本機截圖工具。我們盡量只在使用者明確觸發時存取系統權限，並優先在裝置本機處理影像內容。",
            ja: "StackShot はローカル処理中心のスクリーンショットツールです。権限はユーザーの明示操作時にのみ使い、画像処理はできる限りデバイス上で行います。",
            en: "StackShot is a local-first screenshot utility. It accesses system permissions only when you explicitly use related features, and it processes captured content on-device whenever possible."
        )
    }

    static var privacyPolicyParagraphs: [String] {
        [
            tr(
                zhHans: "1. 屏幕录制：用于截图、滚动截图和对已捕获画面进行后续编辑。未经你的操作，StackShot 不会自动开始录屏。",
                zhHant: "1. 螢幕錄製：用於截圖、捲動截圖以及對已擷取畫面進行後續編輯。未經你的操作，StackShot 不會自動開始錄屏。",
                ja: "1. 画面収録: スクリーンショット、スクロールキャプチャ、取得済み画像の編集にのみ使用します。あなたが操作しない限り、自動で収録を開始しません。",
                en: "1. Screen Recording: Used only for screenshots, scrolling capture, and follow-up editing of captured content. StackShot doesn't start recording automatically without your action."
            ),
            tr(
                zhHans: "2. 辅助功能：仅用于更准确识别鼠标下的前台窗口。未授予时，应用仍可使用手动框选截图，但窗口悬停识别精度可能降低。",
                zhHant: "2. 輔助使用：僅用於更準確辨識游標下的前景視窗。未授權時，應用仍可使用手動框選截圖，但視窗懸停辨識精度可能降低。",
                ja: "2. アクセシビリティ: ポインタ下の最前面ウィンドウをより正確に識別するためだけに使用します。許可しなくても手動範囲選択は利用できますが、ホバー判定の精度は下がる場合があります。",
                en: "2. Accessibility: Used only to more accurately detect the frontmost window under the pointer. Without access, manual region capture still works, but hovered-window detection may be less precise."
            ),
            tr(
                zhHans: "3. 剪贴板与文件：只有在你点击复制、分享或保存时，StackShot 才会把图像或文字写入剪贴板或导出到你选择的位置。",
                zhHant: "3. 剪貼簿與檔案：只有在你點擊複製、分享或儲存時，StackShot 才會把影像或文字寫入剪貼簿或匯出到你選擇的位置。",
                ja: "3. クリップボードとファイル: 画像や文字をクリップボードへ書き込んだり、選択した場所へ保存したりするのは、コピー・共有・保存をあなたが実行したときだけです。",
                en: "3. Clipboard and files: StackShot writes images or text to the clipboard, or exports files to disk, only when you explicitly choose Copy, Share, or Save."
            ),
            tr(
                zhHans: "4. 本地处理：截图编辑、窗口识别、OCR 和大部分图像处理都在本机完成。应用不包含远程上传截图内容的网络同步逻辑。",
                zhHant: "4. 本機處理：截圖編輯、視窗辨識、OCR 和大部分影像處理都在本機完成。應用不包含遠端上傳截圖內容的網路同步邏輯。",
                ja: "4. ローカル処理: スクリーンショット編集、ウィンドウ判定、OCR、ほとんどの画像処理はデバイス上で完結します。取得した画像を自動送信する同期機能は含みません。",
                en: "4. Local processing: Screenshot editing, window detection, OCR, and most image processing run on-device. The app doesn't include automatic network sync that uploads captured content."
            ),
            tr(
                zhHans: "5. 偏好设置：语言、Dock 显示和快捷键等设置只保存在本机的应用偏好中，用于恢复你的使用习惯。",
                zhHant: "5. 偏好設定：語言、Dock 顯示和快捷鍵等設定只保存在本機的應用偏好中，用於還原你的使用習慣。",
                ja: "5. 設定情報: 言語、Dock 表示、ショートカットなどの設定は、この Mac 上のアプリ設定にのみ保存され、利用環境の復元に使われます。",
                en: "5. Preferences: Language, Dock visibility, and shortcut settings are stored only in the app's local preferences on this Mac so your workflow can be restored."
            )
        ]
    }

    static var privacyWindowFooter: String {
        tr(
            zhHans: "如需在 App Store 中提交版本，还需要在 App Store Connect 中填写外部隐私政策链接和隐私营养标签。",
            zhHant: "如需在 App Store 中提交版本，仍需在 App Store Connect 中填寫外部隱私政策連結與隱私營養標籤。",
            ja: "App Store 提出時は、App Store Connect 側でも外部プライバシーポリシー URL とプライバシー情報を設定してください。",
            en: "For App Store submission, you still need to provide the external privacy policy URL and privacy details in App Store Connect."
        )
    }

    static var close: String {
        tr(zhHans: "关闭", zhHant: "關閉", ja: "閉じる", en: "Close")
    }

    static var ocrTranslationUnavailableMessage: String {
        tr(
            zhHans: "当前 App Store 提交版本已关闭内置 OCR 翻译覆盖层，以避免额外的沙盒例外权限。",
            zhHant: "目前 App Store 提交版本已關閉內建 OCR 翻譯覆蓋層，以避免額外的沙盒例外權限。",
            ja: "App Store 提出版では、追加のサンドボックス例外を避けるためアプリ内 OCR 翻訳オーバーレイを無効にしています。",
            en: "This App Store submission build disables the in-app OCR translation overlay to avoid extra sandbox exception entitlements."
        )
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
