import SwiftUI
import KeyboardShortcuts

@main
struct StackShotApp: App {
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
