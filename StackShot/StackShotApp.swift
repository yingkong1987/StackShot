import AppKit
import SwiftUI
import KeyboardShortcuts

final class StackShotAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MenuBarController.shared.presentMainWindow()
        return false
    }
}

@main
struct StackShotApp: App {
    @NSApplicationDelegateAdaptor(StackShotAppDelegate.self) private var appDelegate
    @State private var didSetup = false
    @StateObject private var launchAtLoginManager = LaunchAtLoginManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(launchAtLoginManager)
                .onAppear {
                    guard !didSetup else { return }
                    didSetup = true
                    MenuBarController.shared.setup()
                    KeyboardShortcuts.onKeyDown(for: .stackShotCapture) {
                        DispatchQueue.main.async {
                            CaptureSessionController.shared.activateFromHotkey()
                        }
                    }
                }
        }
        .defaultSize(width: 460, height: 600)
        .windowResizability(.contentSize)
    }
}
