import SwiftUI

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
                    HotkeyManager.shared.start()
                }
        }
        .defaultSize(width: 460, height: 340)
        .windowResizability(.contentSize)
    }
}
